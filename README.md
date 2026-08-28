# ConvertX

A small microservices platform for file format conversion and developer utilities,
built to learn how enterprise systems actually fit together.

The API surface is deliberately modest: convert between JSON, XML, CSV and YAML,
plus a handful of developer tools like base64 and JWT decoding. That is the point.
The interesting part is not the conversions, it is everything around them - the
gateway, the autoscaling, the secret management, the observability, and the
failure modes you only find by breaking things on purpose.

---

## Why this exists

I wanted to understand how production systems are actually run, not just how to
write a service. Most tutorials stop at "here is a REST API in a container". The
questions that kept nagging me were the ones after that:

- How does traffic get from the internet to a pod, and what sits in between?
- What happens to an in-flight request when you deploy?
- How does a service find its database when the address is not known until runtime?
- How do you know the autoscaler is working, rather than assuming it is?
- Where do logs go when the container that wrote them no longer exists?

So I built something small enough to finish and wired it up the way a real system
would be. Every piece of infrastructure here exists because I hit a problem that
needed it, and most of them taught me something that was not in the docs.

The `CLAUDE.md` file in this repo is the long version: a running log of every trap
I fell into and why the code looks the way it does. If you only read one file for
the war stories, read that one.

---

## What it does

Two Go services behind a Kong gateway.

**Conversion service** - stateless format conversion, Redis-cached.

| Endpoint                              | Description                       |
| ------------------------------------- | --------------------------------- |
| `POST /api/v1/convert/json-to-xml`  | JSON to XML                       |
| `POST /api/v1/convert/xml-to-json`  | XML to JSON                       |
| `POST /api/v1/convert/json-to-csv`  | JSON to CSV                       |
| `POST /api/v1/convert/csv-to-json`  | CSV to JSON                       |
| `POST /api/v1/convert/yaml-to-json` | YAML to JSON                      |
| `POST /api/v1/convert/json-to-yaml` | JSON to YAML                      |
| `POST /api/v1/tools/base64/encode`  | Base64 encode                     |
| `POST /api/v1/tools/base64/decode`  | Base64 decode                     |
| `POST /api/v1/tools/url/encode`     | URL encode                        |
| `POST /api/v1/tools/url/decode`     | URL decode                        |
| `POST /api/v1/tools/jwt/decode`     | Decode a JWT without verifying it |
| `GET  /api/v1/tools/uuid`           | Generate a UUID                   |
| `GET  /api/v1/convert/health`       | Health check                      |

Every POST takes `{"input": "..."}`. Conversions return `{"output": "...", "cached": bool}`,
errors return `{"error": "..."}`.

**Auth service** - a thin layer over AWS Cognito, plus API key management.

| Endpoint                       | Description                                   |
| ------------------------------ | --------------------------------------------- |
| `POST /api/v1/auth/register` | Sign up (auto-confirmed, no email step)       |
| `POST /api/v1/auth/login`    | Returns access + refresh tokens               |
| `POST /api/v1/auth/refresh`  | Exchange refresh token for a new access token |
| `GET  /api/v1/auth/me`       | Current user (requires JWT)                   |
| `POST /api/v1/auth/api-key`  | Issue an API key (requires JWT)               |
| `GET  /api/v1/auth/health`   | Health check                                  |

Access tokens last 15 minutes. API keys look like `cx_<64 hex>` and are stored
SHA-256 hashed, so they are shown in plaintext exactly once.

Quick taste:

```bash
curl -X POST http://localhost:8080/api/v1/convert/json-to-xml \
  -H 'Content-Type: application/json' \
  -d '{"input":"{\"name\":\"test\",\"value\":42}"}'
```

---

## Architecture

```
                        Client
                          |
                          v
              +-----------------------+
              |   MetalLB (L4)        |   assigns a LoadBalancer IP
              +-----------------------+   on a bare-metal style cluster
                          |
                          v
              +-----------------------+
              |   Kong Gateway (L7)   |   routing, CORS, rate limiting,
              +-----------------------+   request IDs, size limits
                    |            |
        +-----------+            +-----------+
        v                                    v
  +-------------+                    +----------------+
  | Auth        |                    | Conversion     |
  | Service     |                    | Service        |
  | (Go/Gin)    |                    | (Go/Gin)       |
  | HPA 2..6    |                    | HPA 2..10      |
  +-------------+                    +----------------+
        |                                    |
        |  secrets, identity, data           |  cache
        v                                    v
  +---------------------------------------------------------+
  |            LocalStack Pro (AWS emulation)                |
  |                                                          |
  |  RDS (PostgreSQL)     api_keys table                     |
  |  ElastiCache (Redis)  db0 conversion cache               |
  |                       db1 Kong rate limit counters       |
  |  Cognito              user pool, RS256 JWTs via JWKS     |
  |  SecretsManager       every credential and endpoint      |
  |  CloudWatch Logs      shipped by fluent-bit DaemonSet    |
  |  CloudFront           provisioned, caching disabled      |
  |  ECR                  image registry (opt-in)            |
  +---------------------------------------------------------+

  Observability runs alongside:
    fluent-bit (DaemonSet)  ->  CloudWatch Logs     "what happened"
    Prometheus + Grafana    ->  metrics dashboards  "how much, how fast"
```

Everything AWS-shaped runs inside LocalStack Pro, so the whole platform comes up
on a laptop with no cloud account and no bill. The AWS SDK code is real though:
pointing it at actual AWS is a matter of clearing one environment variable and
supplying real credentials.

---

## Tech stack

| Layer         | Choice                                            |
| ------------- | ------------------------------------------------- |
| Language      | Go 1.25 (Gin, pgx, go-redis, AWS SDK v2)          |
| Gateway       | Kong Gateway Operator, Gateway API`HTTPRoute`   |
| Load balancer | MetalLB                                           |
| Orchestration | Kubernetes (Docker Desktop, Kubeadm mode)         |
| Autoscaling   | HorizontalPodAutoscaler + metrics-server          |
| Database      | RDS PostgreSQL (via LocalStack Pro)               |
| Cache         | ElastiCache Redis (via LocalStack Pro)            |
| Identity      | Cognito user pool, RS256 verified through JWKS    |
| Secrets       | AWS SecretsManager, fetched at runtime            |
| Logs          | fluent-bit DaemonSet to CloudWatch Logs           |
| Metrics       | Prometheus + Grafana                              |
| CDN           | CloudFront (provisioned, not in the request path) |
| AWS emulation | LocalStack Pro`2026.7.5`                        |

---

## Things I learned the hard way

This is the section I would actually want to read on someone else's project, so
here are the problems that cost me the most time.

**A deploy was quietly dropping requests.** Both services started their HTTP
server with gin's `r.Run()`, which blocks forever with no signal handling. That
means `SIGTERM` reaches Go's default handler and kills the process instantly,
severing whatever was in flight. Every rolling restart was dropping a few
requests and nothing anywhere reported it. The fix needs two halves, and I only
understood the second after the first did not work: trap `SIGTERM` and call
`http.Server.Shutdown` to drain, *and* add a `preStop` sleep, because endpoint
removal is asynchronous with `SIGTERM`. Draining perfectly does not help if Kong
is still routing to you. Measured before and after, same load:

|        | pod kill          | rolling restart   |
| ------ | ----------------- | ----------------- |
| Before | 3 dropped / 3,693 | 3 dropped / 4,862 |
| After  | 0 dropped / 5,451 | 0 dropped / 7,270 |

**A load test that proves nothing is worse than no load test.** My first attempt
showed flat CPU and an autoscaler that never moved. The gateway rate limit is 20
requests per *day* per IP, so the budget was gone in under a second and every
subsequent request was a 429 rejected before it ever reached a pod. Then, once
that was fixed, the conversion cache absorbed everything because I was sending
the same payload repeatedly. A test has to defeat both to generate real work.

**"Available" does not mean reachable.** LocalStack's RDS reports
`DBInstanceStatus: available` while the port it advertises refuses connections,
because after a restore from persisted state the internal proxy is never
re-bound. The service crashlooped with `connection refused` while the AWS API
cheerfully insisted everything was fine. The bootstrap now TCP-checks the port
and rebuilds the instance if it lies.

**Code changes that never take effect.** Docker Desktop's Kubernetes has two
provisioning modes, and in `kind` mode the node keeps its own image store,
isolated from the Docker daemon. `docker build` writes to one, the cluster reads
the other, and with `imagePullPolicy: IfNotPresent` on a `:latest` tag the pods
happily keep running a stale image forever. Every step printed success. Nothing
errored. Switching to Kubeadm mode fixed it.

**Metric labels are an attack surface.** The Prometheus middleware labels
requests with `c.FullPath()`, the Gin route template, not the raw URL. Labelling
by real path would let anyone mint unbounded label values by hitting random URLs
and exhaust the Prometheus server's memory. Unmatched routes collapse into a
single `unmatched` series. There is a test pinning this so nobody "improves" it
later.

**Log shipping that reports success while shipping nothing.** fluent-bit tails
`/var/log/containers/*.log`, so mounting `/var/log` into the DaemonSet looks
sufficient. It is not: those are symlinks, and on Docker Desktop's Docker
runtime they resolve two hops down into `/var/lib/docker/containers`, which was
not mounted. The tail inputs matched zero files, and fluent-bit reported no
error whatsoever. It started, initialised every input and output, passed its
readiness probe, and `setup.sh` printed a green tick, because the only thing
being checked was that the pod was running. The one visible symptom was empty
log groups. The integration suite is what caught it. Checking for
`inotify_fs_add` in the fluent-bit log is how you tell attachment from silence.

**An idle cache and a broken cache look identical if you are careless.** The
Grafana hit-rate panels divide without clamping the denominator. Clamping turns
"no traffic at all" into a confident `0%`, which reads as "every lookup missed".
A bare `0/0` gives NaN and the panel says so. That distinction cost me a real
debugging session once.

---

## Getting started

### Prerequisites

- **Docker Desktop** with Kubernetes enabled, in **Kubeadm** mode, not `kind`.
  Check with `docker desktop kubernetes status | grep Mode`. This matters more
  than it sounds like it should; see the note above.
- **kubectl**
- **Helm** (`brew install helm`). Not bundled with Docker Desktop.
- **Go 1.25+** only if you want to run a service outside the cluster.
- **A LocalStack Pro auth token**, free for personal use from
  [app.localstack.cloud](https://app.localstack.cloud). RDS, ElastiCache and ECR
  are all Pro-only features, and the Pro image will not boot without a token.

### Configure

```bash
cp .env.example .env
```

Then fill in `LOCALSTACK_AUTH_TOKEN` and `POSTGRES_PASSWORD`. `REDIS_PASSWORD` is
optional and only meaningful against real AWS. `.env` is gitignored.

### Run the whole platform

```bash
bash setup.sh
```

That is the entire bring-up, and it is idempotent so you can re-run it safely. It
works through fourteen steps: namespaces, MetalLB, Kong, LocalStack Pro, the
bootstrap job that provisions the AWS resources, endpoint resolution, Docker
builds, both services, gateway plugins, log shipping, monitoring, metrics-server,
port-forwards, and finally health checks.

Takes about ten minutes on a cold start. When it finishes:

| What        | Where                                                                |
| ----------- | -------------------------------------------------------------------- |
| API gateway | http://localhost:8080                                                |
| Grafana     | http://localhost:3000 (anonymous viewer,`admin`/`admin` to edit) |
| Prometheus  | http://localhost:9090 (`/targets` shows what is scraped)           |

Then verify it works:

```bash
curl http://localhost:8080/api/v1/convert/health
```

### Stop and tear down

```bash
bash stop.sh       # scale down, keep state
bash teardown.sh   # delete everything including volumes, prompts first
```

Note that RDS data does not survive a stop, because LocalStack reassigns the
port on restore and the bootstrap rebuilds the instance. Cognito users, secrets
and ECR images do survive.

---

## Running a single service

The conversion service is deliberately runnable on its own, with no cluster and
no LocalStack, because needing a fourteen-step bring-up to test a parser is
miserable. It picks its cache backend from the environment at startup.

```bash
cd services/golang-conversion-service
```

**No dependencies at all** (in-memory cache):

```bash
go run ./cmd/main.go
```

**With a real Redis:**

```bash
docker compose up -d --wait
REDIS_HOST=localhost:6379 REDIS_PASSWORD=localdev go run ./cmd/main.go
```

**With secrets pulled from a local LocalStack**, which exercises the same code
path the cluster uses:

```bash
LOCALSTACK_PORT=4567 docker compose --profile aws up -d --wait
AWS_ENDPOINT_URL=http://localhost:4567 AWS_REGION=us-east-1 \
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test go run ./cmd/main.go
```

**With the Grafana dashboard**, no cluster needed. It runs the same Prometheus
and Grafana images the cluster runs, scraping your host, and mounts the dashboard
JSON straight from the repo so there is only ever one definition:

```bash
docker compose --profile monitoring up -d --wait
go run ./cmd/main.go
# http://localhost:3001, dashboard preloaded, no login
```

Ports are 3001 and 9091 rather than 3000 and 9090 on purpose, so they do not
collide with the port-forwards `setup.sh` leaves running against the cluster.

Clean up:

```bash
docker compose --profile aws --profile monitoring down -v
```

The auth service cannot run standalone in the same way. It needs Cognito, RDS and
SecretsManager, so it needs LocalStack regardless.

### Building

Each service builds independently from its own directory:

```bash
cd services/auth-service && go mod download
CGO_ENABLED=0 GOOS=linux go build -o auth-service ./cmd/main.go

docker build -t convertx/auth-service:latest services/auth-service/
docker build -t convertx/conversion-service:latest services/golang-conversion-service/
```

Deployments use `:latest` with `imagePullPolicy: IfNotPresent`, so rebuilding an
image does not trigger a rolling update by itself. `setup.sh` issues a
`kubectl rollout restart` after applying. Outside of it, use a versioned tag with
`kubectl set image`.

---

## Testing

There are four layers, and none of them replaces another.

**Unit tests.** No infrastructure required, no cluster, no LocalStack, no Redis:

```bash
cd services/golang-conversion-service
go test ./...
go test ./... -cover
go test ./... -race
go test ./internal/converter/ -run TestYAMLToJSON -v
```

**Integration suite.** Exercises the whole deployed stack end to end. Needs the
port-forward on 8080 and `kubectl` access, because it flushes Redis and asserts
on RDS, ElastiCache and CloudFront state:

```bash
bash tests/test.sh
```

**Load and autoscaling.** Drives the conversion service and reports how the HPA
responded, with a scale timeline:

```bash
bash tests/load-test.sh [DURATION_SECONDS] [CONCURRENCY]   # default 180s / 12
```

Last run: 59,081 requests over 180 seconds, all `200`, scaling from 2 to 6 pods
with CPU falling from 231% to 77% as replicas came up.

**Resilience.** Holds steady load while something disruptive happens, then counts
what failed:

```bash
bash tests/resilience-test.sh [kill|rollout|all]   # default all
```

It kills a pod, then does a rolling restart, and reports dropped requests for
each. A baseline phase runs first and aborts the run if it is not clean, because
otherwise a failure cannot be attributed to the disruption rather than to the
test harness itself.

Last run: 0 dropped requests through both, with the replacement pod ready 12
seconds after the kill and the rollout completing in 23 seconds.

There is also a Bruno collection in `bruno/` covering both the gateway path and
direct service access.

> **Heads up on rate limits.** Anonymous traffic is capped at 20 requests per day
> per IP, which is less than any of these suites consume. The scripts raise the
> limit and flush the counter themselves, but a manual `curl` loop can exhaust
> your daily budget and make every later request return 429. If that happens,
> `tests/test.sh` exposes `reset_rate_limit`, or flush Redis db 1 by hand.

---

## Observability

Two separate paths, deliberately. **Metrics alert, logs explain.**

**Prometheus and Grafana** live in a `monitoring` namespace. Only the conversion
service is instrumented so far. Discovery is annotation-driven, so instrumenting
the auth service later needs no Prometheus config change, just three pod
annotations.

Tracked: request count by route and status, request duration, in-flight requests,
cache hit and miss counts, conversion count and duration, and input size. Go
runtime and process collectors come free.

Worth knowing: `/metrics` is served at the root, not under `/api/v1`, so it is
not reachable through Kong at all. Prometheus scrapes the pod IP directly.
Prometheus RBAC is a namespaced `Role`, not a `ClusterRole`, because it only ever
needs to list pods in one namespace and the usual `ClusterRole` would let it read
env vars and secret names across the whole cluster.

**fluent-bit** runs as a DaemonSet and ships container logs to CloudWatch Logs,
split into three groups by source: auth service, conversion service, and Kong.
It runs node-level rather than as a sidecar because Kong's dataplane pod is
created by the Gateway Operator and you cannot add a container to it.

```bash
bash scripts/tail-logs.sh /convertx/conversion-service [minutes]
```

---

## Project structure

```
.
├── setup.sh                    # full 14-step bring-up
├── stop.sh                     # scale down, keep state
├── teardown.sh                 # delete everything
├── CLAUDE.md                   # the long-form engineering notes
│
├── services/
│   ├── auth-service/           # Cognito wrapper + API keys
│   │   ├── cmd/main.go         # wiring, migrations, graceful shutdown
│   │   ├── internal/
│   │   │   ├── handler/        # Gin handlers
│   │   │   ├── service/        # business logic
│   │   │   ├── repository/     # RDS access
│   │   │   ├── cognito/        # user pool operations
│   │   │   ├── jwks/           # RS256 key fetching and caching
│   │   │   ├── middleware/     # auth middleware
│   │   │   └── secrets/        # SecretsManager client
│   │   └── k8s/                # deployment, service, httproute, hpa, pdb
│   │
│   └── golang-conversion-service/
│       ├── cmd/main.go
│       ├── internal/
│       │   ├── handler/        # convert + tools handlers
│       │   ├── converter/      # the actual format conversions
│       │   ├── cache/          # Redis and in-memory backends
│       │   ├── metrics/        # Prometheus collectors + middleware
│       │   └── secrets/
│       ├── k8s/
│       └── docker-compose.yml  # standalone dev dependencies
│
├── infra/
│   ├── kong/                   # gateway, plugins, plugin bindings
│   ├── localstack/             # deployment + bootstrap script
│   ├── logging/                # fluent-bit DaemonSet
│   ├── monitoring/             # Prometheus, Grafana, dashboards
│   ├── metallb/
│   └── postgres/, redis/       # kept for reference, no longer applied
│
├── tests/                      # test.sh, load-test.sh, resilience-test.sh
├── bruno/                      # API collection
└── scripts/                    # tail-logs.sh, push-to-ecr.sh
```

---

## Design notes

A few decisions that are easy to misread as bugs.

**Only `/convert/*` is cached.** The `/tools/*` endpoints are cheap pure
functions where a Redis round trip would cost more than just recomputing the
answer. This surprises people twice: load-testing `/tools/base64/decode` produces
zero cache activity, and the Grafana cache panels stay empty no matter how much
tools traffic you send.

**The auth service does not use Redis at all,** and does not store users or hash
passwords. Cognito owns identity. RDS backs only the `api_keys` table.

**Both services fetch every credential from SecretsManager at startup** and
refuse to boot if it is unreachable. Nothing sensitive lives in an environment
variable or a ConfigMap. RDS and ElastiCache ports are assigned dynamically by
LocalStack, so they cannot be hardcoded anywhere; the bootstrap resolves them
after creation and publishes them as secrets.

**The Deployments have no `replicas:` field.** The HPA owns the replica count.
Leaving `replicas:` in the manifest means every `kubectl apply` resets it and
fights the autoscaler.

**The auth service usually will not scale, and that is correct.** It spends its
time waiting on Cognito and RDS rather than burning CPU, so CPU is a weak signal
for it. Scaling it meaningfully needs a concurrency or request-rate metric.

**CloudFront is provisioned but caches nothing, on purpose.** Every real endpoint
is a POST, which CloudFront never caches, and the only GETs are health checks and
`/tools/uuid`. With default TTLs it would cache `GET /tools/uuid` and hand every
caller the same UUID. All three TTLs are pinned to 0, and there is a test that
fails if someone "optimises" caching back on.

---

## Scope

This is a learning project and it is deliberately bounded. Everything here is
synchronous JSON in, JSON out. There is no file upload path and no async work.

Earlier drafts planned PDF, document and image conversion services in Java, plus
an Angular frontend. I dropped all of it. Adding a fourth format converter would
have taught me nothing new, whereas getting autoscaling, graceful shutdown and
observability genuinely working taught me a great deal. S3 and SQS were removed
for the same reason once the services that would have used them were cut.

Known gaps, honestly:

- The auth service has no `/metrics` endpoint yet, so half the platform is
  invisible in Grafana.
- `resilience-test.sh` only targets the conversion service.
- Refresh tokens do not rotate in local development. The app client is created
  with rotation enabled, which is correct against real AWS, but LocalStack
  accepts the setting without implementing it and returns the same token. The
  service code already handles rotation properly for when it runs on real AWS.
- Kong exposes no Prometheus metrics, since the `prometheus` plugin is not
  enabled.
- There is no registered-user rate limit tier. Kong's `limit_by: consumer`
  needs Kong consumers, but identity is verified by the services' own JWT
  middleware, so Kong has no consumer to key on. That is a feature to build,
  not a setting to flip.

---

## Troubleshooting

**Pods crashloop with `connection refused` after a restart.** LocalStack restored
from persisted state and the RDS proxy is stale, even though the AWS API reports
the instance as `available`. Re-run `bash setup.sh`; the bootstrap detects and
rebuilds it. Waiting will not fix it.

**Code changes have no effect.** Check that Docker Desktop's Kubernetes is in
Kubeadm mode, not `kind`:

```bash
docker desktop kubernetes status | grep Mode
docker desktop kubernetes images | grep convertx   # empty means kind mode
```

**Everything returns 429.** You have spent the 20 requests per day for your IP.
The counter lives in Redis db 1 and persists. Flush it, or use the helper in
`tests/test.sh`.

**HPAs show `<unknown>` and never scale.** metrics-server is not serving CPU.
On Docker Desktop it needs `--kubelet-insecure-tls`, which `setup.sh` patches in.
Check `kubectl logs -n kube-system -l k8s-app=metrics-server`.

**The gateway is unreachable.** Kong has no NodePort here, so everything goes
through a port-forward that `setup.sh` starts and that does not survive a reboot.
The dataplane service name is generated and changes on every Kong reinstall:

```bash
kubectl port-forward -n kong \
  svc/$(kubectl get svc -n kong --no-headers | grep dataplane-ingress | awk '{print $1}') \
  8080:80 &
```

**LocalStack will not start.** Check that `LOCALSTACK_AUTH_TOKEN` is set in
`.env`. The Pro image exits without one. Licences also enforce a minimum version,
so pin a recent release rather than switching the image to `:latest`.
