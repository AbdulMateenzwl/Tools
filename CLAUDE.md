# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ConvertX is a microservices platform for file conversion and developer utilities, running on Kubernetes (Docker Desktop) with Kong Gateway for L7 routing.

Backing services are AWS-emulated through **LocalStack Pro**: PostgreSQL is an RDS instance, Redis is an ElastiCache cluster, user identity is a Cognito user pool, logs ship to CloudWatch, a CloudFront distribution fronts the gateway, and secrets live in SecretsManager. There is no postgres StatefulSet and no redis Deployment — `infra/postgres/` and `infra/redis/` are retained for reference but are no longer applied by `setup.sh`. All application secrets and service endpoints are fetched at runtime from SecretsManager; there are none in environment variables or config maps.

## Setup, Test, Teardown

`setup.sh` performs the entire 12-step bring-up (namespaces → MetalLB → Kong → LocalStack Pro → bootstrap job → resolve endpoints → docker builds → services → plugins → port-forward → health checks). Prefer it over the manual steps in `Readme.md`, which predate the AWS migration and are now substantially wrong.

```bash
bash setup.sh          # full bring-up, idempotent for Kong/helm
bash tests/test.sh     # API test suite (~80 assertions)
bash teardown.sh       # deletes everything incl. PVs (prompts for confirmation)
```

**`setup.sh` requires a `.env` at the repo root** (gitignored). Copy the template:

```bash
cp .env.example .env   # then fill in all three values
```

`LOCALSTACK_AUTH_TOKEN` is mandatory — the Pro image will not boot without it, and every backing service (RDS, ElastiCache, ECR) is Pro-only. Get it from https://app.localstack.cloud → Auth Token.

There is no JWT signing secret any more: Cognito signs tokens with its own rotating RSA keys, which the auth service fetches via JWKS.

### Tests

There are two independent test layers.

**Go unit tests** (`services/golang-conversion-service/**/*_test.go`) need no infrastructure at all — no cluster, no LocalStack, no Redis:

```bash
cd services/golang-conversion-service
go test ./...                 # all tests
go test ./... -cover          # coverage
go test ./... -race           # race detector
go test ./internal/converter/ -run TestYAMLToJSON -v   # a single test
```

### Running the conversion service alone

`cmd/main.go` picks its cache backend from the environment (`newCacheStore`), which is what makes the service runnable without the rest of the platform:

| Backend | Dependencies | Command |
|---|---|---|
| in-memory | none | `go run ./cmd/main.go` |
| plain Redis | `docker compose up -d --wait` | `REDIS_HOST=localhost:6379 REDIS_PASSWORD=localdev go run ./cmd/main.go` |
| SecretsManager | `LOCALSTACK_PORT=4567 docker compose --profile aws up -d --wait` | `AWS_ENDPOINT_URL=http://localhost:4567 AWS_REGION=us-east-1 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test go run ./cmd/main.go` |

Stop dependencies with `docker compose --profile aws down -v`.

`services/golang-conversion-service/docker-compose.yml` starts only this service's dependencies — Redis by default, plus a LocalStack under the `aws` profile seeded with `convertx/redis/{endpoint,password}` by `dev/seed-secrets.sh`. It is scoped to the service on purpose: it carries its own compose project name, `.dockerignore` keeps it out of the image, and **the root `setup.sh` never invokes docker compose** (it builds images and applies Kubernetes manifests, where Redis is an ElastiCache cluster). Running the whole project does not touch it.

Two gotchas baked into that file: LocalStack is pinned to **3.4** because `localstack/localstack:latest` is now a Pro build that exits 55 without an auth token (and `ACTIVATE_PRO=0` does not override it), and `LOCALSTACK_PORT` defaults to **4567** because 4566 usually already has a LocalStack on it.

**`tests/test.sh`** is a bash/curl integration suite covering the whole deployed stack. It requires an active port-forward on `localhost:8080` **and** `kubectl` access, because it flushes Redis and asserts on RDS/ElastiCache/CloudFront state. There is no way to run a single case; comment out `section` blocks to narrow it.

Anonymous rate limiting is 20 requests/day per IP, which is less than the suite consumes. The suite handles this by flushing Redis DB 1 up front — so a manual `curl` loop can exhaust the daily budget and return 429 for every later request. Reset it with:

```bash
POD=$(kubectl get pod -n localstack -l app=localstack -o jsonpath='{.items[0].metadata.name}')
EP=$(kubectl exec -n localstack $POD -- awslocal secretsmanager get-secret-value \
      --secret-id convertx/redis/endpoint --query SecretString --output text)
PW=$(kubectl exec -n localstack $POD -- awslocal secretsmanager get-secret-value \
      --secret-id convertx/redis/password --query SecretString --output text)
kubectl exec -n localstack $POD -- redis-cli -h 127.0.0.1 -p "${EP##*:}" -a "$PW" -n 1 FLUSHDB  # rate limits
kubectl exec -n localstack $POD -- redis-cli -h 127.0.0.1 -p "${EP##*:}" -a "$PW" -n 0 FLUSHDB  # cache
```

`tests/test.sh` wraps this as `reset_rate_limit` / `reset_cache`.

## Environment Gotchas (learned the hard way)

**LocalStack Pro image version.** Licences enforce a minimum: `localstack-pro:3.4` is rejected at startup with `Your LocalStack license requires you to use localstack-pro version 4.4.0 or higher`, and the pod CrashLoopBackOffs with a misleading "did not become ready" from `setup.sh`. Releases are CalVer now — `infra/localstack/deployment.yaml` pins `2026.7.5`. Bump the pin rather than switching to `:latest`.

**Helm 4 works.** `Readme.md` says Helm 3.x, but the Kong Gateway Operator chart installs fine under Helm 4.2.4. Helm is a hard prerequisite and is not bundled with Docker Desktop — `brew install helm`.

**Never use `kubectl wait --for=condition=ready pod --selector=...` here.** It snapshots matching pods at start and blocks indefinitely if one is later deleted. The LocalStack Deployment uses `strategy: Recreate`, and the services get a `kubectl rollout restart`, so on every re-run a watched pod disappears and the wait hangs for its full timeout — then fails the run while the workload is perfectly healthy. `setup.sh` uses `kubectl rollout status deployment/<name>` instead. The bootstrap Job wait is fine: it targets a named object, not a selector.

## Building

Each service builds independently from its own directory. There are no linting configs; use `go vet ./...` inside a service directory.

```bash
cd services/auth-service && go mod download
CGO_ENABLED=0 GOOS=linux go build -o auth-service ./cmd/main.go

docker build -t convertx/auth-service:latest services/auth-service/
docker build -t convertx/conversion-service:latest services/golang-conversion-service/
```

Deployments use `imagePullPolicy: IfNotPresent` with the `:latest` tag, so rebuilding an image does **not** cause a rolling update on its own. `setup.sh` issues a `kubectl rollout restart` after applying; outside of it, use a versioned tag with `kubectl set image`.

**ECR** repositories (`convertx/auth-service`, `convertx/conversion-service`) are created by the bootstrap, but `setup.sh` still deploys from the local Docker daemon. Pushing to ECR is `scripts/push-to-ecr.sh`, which requires a manual Docker Desktop setting — LocalStack's registry is plain HTTP, so both Docker and the Kubernetes node must trust it via `insecure-registries`. That setting cannot be scripted, which is why the ECR pull path is opt-in.

## Architecture

### Services

**Auth Service** (`services/auth-service/`) — a thin layer over Cognito plus API key management. It no longer stores users or hashes passwords, and **no longer uses Redis at all**. RDS backs only the `api_keys` table, auto-migrated on startup (`runMigrations` in `cmd/main.go`) — there is no migration tool, so schema changes mean editing that inline SQL slice.

**Conversion Service** (`services/golang-conversion-service/`) — stateless conversions and dev tools. Redis-cached, no database.

Both follow the same layout: `cmd/main.go` (wiring) → `internal/handler/` (Gin) → `internal/service/` or `internal/converter/` → `internal/repository/` (auth only) / `internal/cache/` (conversion only), plus `internal/secrets/` and `internal/model/`. Auth additionally has `internal/cognito/` (user pool operations) and `internal/jwks/` (RS256 key fetching).

### Provisioned but Unused (intentional)

`bootstrap.sh` creates an S3 bucket (`convertx-files`, with a 1-day lifecycle rule) and three SQS queues (`convertx-document-jobs`, `convertx-image-jobs`, `convertx-dead-letter`). **No code touches any of them** — neither service imports the S3 or SQS SDK, and there is no file-upload path anywhere; every handler is synchronous JSON in/JSON out.

They are staged for the planned Document and Image services. This is deliberate, not an oversight — don't go looking for the code path. Adding S3 or SQS usage means building new capability, not wiring up something half-finished.

The CloudFront distribution is a related but separate case: it is correctly configured and not merely stubbed, but no traffic is routed through it yet. See CDN (CloudFront) below.

Related: `r.MaxMultipartMemory = 1 << 20` in the auth service's `main.go` is a gin default that is never exercised, since no handler reads a file.

### Secret Fetching Pattern

Both services call `secrets.Load(ctx)` as the first act of `main()` and `log.Fatalf` if it fails — a service cannot start without LocalStack reachable.

| Secret | Consumer |
|---|---|
| `convertx/redis/password`, `convertx/redis/endpoint` | Conversion service (auth no longer uses Redis) |
| `convertx/postgres/{username,password,endpoint}` | Auth service |
| `convertx/cognito/{user_pool_id,client_id,jwks_url,issuer}` | Auth service |

`convertx/auth/jwt_secret` is **gone** — Cognito signs with its own RSA keys.

`internal/secrets/` overrides the AWS SDK's `BaseEndpoint` only when `AWS_ENDPOINT_URL` is set, so pointing at real AWS is a matter of clearing that variable and supplying real credentials.

**Endpoint discovery.** RDS and ElastiCache are assigned ports dynamically from LocalStack's `EXTERNAL_SERVICE_PORTS_*` range, so they cannot be hardcoded in a ConfigMap. `bootstrap.sh` resolves them after creation and publishes `convertx/postgres/endpoint` and `convertx/redis/endpoint` (both `host:port`) into SecretsManager. `getSecretOrEnv` in each service prefers the secret and falls back to `DB_HOST`/`REDIS_HOST` env vars, so a cluster still running self-hosted postgres/redis keeps working.

The host portion is rewritten by the bootstrap to `localstack.localstack.svc.cluster.local`, because the address LocalStack reports is only meaningful inside its own container.

**ElastiCache has no AUTH — verified.** The cluster is created without `--auth-token`, so Redis rejects any AUTH command sent to it (`ERR AUTH <password> called without any password configured`). `convertx/redis/password` is therefore left **absent**, not empty: SecretsManager requires a `SecretString` of at least one character, so `""` is not storable and attempting it aborts the bootstrap under `set -e`.

Absent is the expected state. `getSecretOrEnv` returns `""`, go-redis then sends no AUTH, and `setup.sh` deletes the `password:` line from the Kong rate-limiting plugins entirely. `REDIS_PASSWORD` in `.env` is optional and only meaningful against real AWS, where you would create the cluster with `--auth-token` plus `--transit-encryption-enabled` and store that token in the secret.

The old `os.Setenv("JWT_SECRET", ...)` hand-off in `main()` is gone; `middleware.RequireAuth` now takes the JWKS cache and issuer as explicit dependencies.

### Identity (Cognito)

The user pool `convertx-users` and app client `convertx-api` are created by `bootstrap.sh`. Email is the username; the client has **no secret**, which avoids computing `SECRET_HASH` on every call.

Things that will bite you if you assume the old behaviour:

- **Access tokens carry no `email` claim.** Only ID tokens do. `/me` therefore makes a `GetUser` round trip rather than reading the token. The middleware rejects anything whose `token_use` is not `access`.
- **Refresh tokens no longer rotate.** The old code deleted the Redis key and issued a new token on every refresh. Cognito's `REFRESH_TOKEN_AUTH` flow reissues only the access token, so the same refresh token stays valid until it expires. `RefreshToken` in the service calls `RevokeToken` **only** when a genuinely different refresh token comes back — revoking unconditionally would lock the user out, since the caller keeps using the token it already has. This is a real reduction in security posture versus the previous rotation; revisit if it matters.
- **Verification is RS256 via JWKS**, not a shared HS256 secret. `internal/jwks` fetches and caches the keys, refetching on an unknown `kid` (rate-limited to once a minute) and falling back to a stale key if the IdP is briefly unreachable. `main()` warms the cache at startup so a bad JWKS URL fails loudly there instead of on the first authenticated request.
- **Role comes from `cognito:groups`**, not a database column. Every new user is added to the `free` group at registration.
- **Registration is `SignUp` + `AdminConfirmSignUp`.** There is no email delivery here, so users are confirmed admin-side immediately.

**API keys are not part of Cognito.** The `cx_` scheme still lives in the `api_keys` table in RDS, with `user_id` now holding the Cognito `sub`. The foreign key to `users` is dropped by a migration statement; the orphaned `users` table is deliberately *not* dropped automatically — remove it by hand once you are satisfied nothing needs it.

**The `iss` claim does not match a constructed issuer — verified.** LocalStack mints tokens with `iss: http://localhost.localstack.cloud:4566/<pool-id>` regardless of how it is addressed, so an issuer URL built from the cluster hostname will never match and `jwt.WithIssuer` would reject every request with a 401.

The middleware therefore checks that `iss` **ends with `/<userPoolID>`** rather than matching a full URL. That enforces the property worth enforcing — the token came from this pool — and is host-independent, so it holds on real AWS (`cognito-idp.<region>.amazonaws.com/<pool-id>`) too. There is no `convertx/cognito/issuer` secret.

`convertx/cognito/jwks_url` **is** still stored rather than derived, since the path is LocalStack-specific. Verified working at `http://<host>:4566/<pool-id>/.well-known/jwks.json`, returning one RS256 key.

### Redis Layout

One ElastiCache cluster (`convertx-cache`, inside LocalStack) serves two purposes across two databases:

| DB | Keys | Owner |
|---|---|---|
| 0 | `conv:<sha256>` — conversion result cache, TTL from `CACHE_TTL_MINUTES` (default 60) | Conversion service |
| 1 | Rate limit counters | Kong `rate-limiting` plugin |

The auth service's `refresh:` and `user_tokens:` keys are gone — Cognito manages refresh tokens now. Flushing DB 0 therefore only clears the conversion cache; it no longer logs anyone out.

### Placeholder Substitution

Several manifests contain literal placeholders that `setup.sh` rewrites with `sed` at apply time. **Never `kubectl apply -f` these directly** — you would deploy the literal placeholder string:

| File | Placeholder |
|---|---|
| `infra/localstack/auth-token-secret.yaml` | `LOCALSTACK_AUTH_TOKEN_PLACEHOLDER` |
| `infra/kong/plugins/rate-limiting-plugin.yaml`, `rate-limiting-registered-plugin.yaml`, `rate-limiting-secret.yaml` | `REDIS_HOST_PLACEHOLDER`, `REDIS_PORT_PLACEHOLDER`, `yourpassword` |
| `infra/localstack/bootstrap-job.yaml` | `REDIS_PWD_PLACEHOLDER`, `POSTGRES_PWD_PLACEHOLDER`, `KONG_ORIGIN_PLACEHOLDER` |

The Kong rate-limiting plugins are invalid YAML until substituted — `port:` holds a bare placeholder where an integer belongs.

`bootstrap.sh` is **not** stored as a checked-in ConfigMap; `setup.sh` generates the ConfigMap from the script with `--from-file`, so there is a single source of truth.

With `PERSISTENCE=1` and the `localstack-pv` volume, secrets and RDS data now survive pod restarts — the old "re-run bootstrap after every restart" cycle is gone. Deleting `localstack-pv` (as `teardown.sh` does) still wipes everything.

### Kong Plugin Wiring

Plugins are attached **twice**, by two independent mechanisms, and both must stay in sync when adding a route:

1. A `konghq.com/plugins` annotation listing plugin names on the HTTPRoute (`services/*/k8s/httproute.yaml`)
2. `KongPluginBinding` CRDs in `infra/kong/plugins/bindings/` referencing the HTTPRoute by name

Active plugins: `cors` (allowlist: localhost:4200, localhost:3000, convertx.io), `rate-limiting-anonymous` (20/day by IP), `request-size-limiting` (1MB), `response-headers` (security headers), `request-id` (correlation-id → `X-Request-ID`), `request-logging` (file-log to stdout, collected from there into CloudWatch — see Log Shipping). `rate-limiting-registered` (100/day by consumer) is defined and applied but not bound to any route.

The 1MB request cap is enforced in two places: the Kong plugin, and a `http.MaxBytesReader` middleware in the auth service's `main.go`.

### Log Shipping

`fluent-bit` runs as a **DaemonSet** in `convertx` (`infra/logging/`), not as a sidecar. Kong's dataplane pod is created by the Gateway Operator, so an extra container cannot be added to it; a node-level collector also covers Kong and both Go services with one component.

It tails `/var/log/containers/*.log` (containerd CRI format) via three explicit `tail` inputs matched by filename glob, and ships each to its own group:

| Source pod | Log group |
|---|---|
| `auth-service-*` in `convertx` | `/convertx/auth-service` |
| `conversion-service-*` in `convertx` | `/convertx/conversion-service` |
| `dataplane-*` in `kong` | `/convertx/kong` |

Deliberate choices worth knowing before editing the config:

- **No `kubernetes` metadata filter.** Routing is by path glob instead, which avoids needing a ServiceAccount, ClusterRole and API access. Adding the filter for pod labels/annotations means adding RBAC.
- **`auto_create_group false`.** `bootstrap.sh` creates the groups with 7-day retention; letting fluent-bit create them would silently drop that policy.
- **`tls Off` with `endpoint` + `port` split.** LocalStack serves CloudWatch Logs over plain HTTP, and the `cloudwatch_logs` plugin takes a bare hostname in `endpoint` with the port as a separate key.
- **Parsers are self-contained.** `parsers.conf` ships in the ConfigMap and defines `cri` itself rather than relying on the image's `/fluent-bit/etc/parsers.conf`, because mounting config at `/fluent-bit/etc` would shadow the image's own files.

A DaemonSet does not restart when its ConfigMap changes, so `setup.sh` issues an explicit `kubectl rollout restart daemonset/fluent-bit`. Do the same after editing the config by hand.

Read logs back with `bash scripts/tail-logs.sh <group> [minutes]`. An empty group with fluent-bit running usually means delivery is failing — check `kubectl logs -n convertx -l app=fluent-bit`.

### CDN (CloudFront)

`bootstrap.sh` creates a distribution commented `convertx-api` with the Kong dataplane as its single origin. **It caches nothing, deliberately.**

That is not laziness — it is the entire point of the configuration. Every conversion and auth endpoint is a POST, which CloudFront never caches, and the only GETs are health checks, `/me`, and `/tools/uuid`. CloudFront's default `DefaultTTL` is 86400, so a distribution created with defaults would cache `GET /tools/uuid` and hand every caller the same UUID. `MinTTL`, `DefaultTTL` and `MaxTTL` are all pinned to 0, with all headers, cookies and query strings forwarded.

`tests/test.sh` asserts those TTLs are still 0. If someone "optimises" caching on later, that test is what catches it.

The config uses the legacy `ForwardedValues` form rather than a managed `CachePolicyId`, because it does not depend on AWS's managed policy IDs existing in the emulator.

**The origin is resolved at setup time.** Kong's dataplane Service name is generated by the Gateway Operator and changes on every reinstall, so `setup.sh` resolves it once in step 3 and substitutes `KONG_ORIGIN_PLACEHOLDER` into the bootstrap Job. The same value is reused for the port-forward in step 12. If the dataplane is not up yet, the bootstrap skips CloudFront with a warning rather than failing the run.

Distribution id and domain land in `convertx/cloudfront/distribution_id` and `convertx/cloudfront/domain`.

**Traffic is not routed through it.** The port-forward still goes straight to Kong, and the distribution domain does not resolve locally, so the CDN is provisioned and correctly configured but not in the request path. It becomes load-bearing when there is something worth caching — static frontend assets, or converted files served from the `convertx-files` bucket.

### Access

Kong has no NodePort on Docker Desktop; everything goes through a port-forward that `setup.sh` starts. The dataplane service name is auto-generated and changes on each Kong reinstall:

```bash
kubectl port-forward svc/$(kubectl get svc -n kong --no-headers | grep dataplane-ingress | awk '{print $1}') 8080:80 -n kong &
```

### API Routes

Auth (`/api/v1/auth`): `GET /health`, `POST /register`, `POST /login`, `POST /refresh`, `GET /me` (JWT), `POST /api-key` (JWT). Access tokens last 15 min; API keys are `cx_<64 hex>` and stored SHA-256 hashed, returned in plaintext once.

Conversion (`/api/v1`): `GET /convert/health`, `POST /convert/{json-to-xml,xml-to-json,json-to-csv,csv-to-json,yaml-to-json,json-to-yaml}`, `POST /tools/{base64/encode,base64/decode,url/encode,url/decode,jwt/decode}`, `GET /tools/uuid`.

All POST endpoints take `{"input": "..."}`. Conversion endpoints return `{"output": "...", "cached": bool}`; errors return `{"error": "..."}`. Note the health endpoint is `/api/v1/convert/health` — there is no `/api/v1/health`.
