# ConvertX — Bruno API collection

Two folders that target the **same URL** but very different things. Pick the
one matching what you have running; they are not interchangeable.

| Folder | Talks to | Requires | Auth |
|---|---|---|---|
| `direct-service/` | the conversion service directly | `go run ./cmd/main.go` | none |
| `full-stack/` | Kong gateway → services | the whole cluster (`bash setup.sh`) | Cognito |

Both default to `http://localhost:8080`, so **only one can be running at a
time**. Pick the matching environment (`direct-service` or `full-stack`) or
requests will fail in confusing ways — auth endpoints 404 against the
standalone service, and the gateway header assertions fail without Kong.

## direct-service

For working on conversion logic. No gateway, no auth, no rate limits.

```bash
cd services/golang-conversion-service
cp .env.example .env          # once
docker compose up -d --wait   # redis; omit for the in-memory cache
go run ./cmd/main.go
```

Then run the folder in the Bruno app, or:

```bash
cd bruno
npx @usebruno/cli run direct-service -r --env direct-service
```

Covers all six conversions, the six tools endpoints, a 400 path, and a
cache miss/hit pair. `cache-1-miss` generates a unique payload in a
pre-request script so it is a miss even on repeat runs; `cache-2-hit`
reuses that payload and must be served from cache, so **run them in order**.

## full-stack

For verifying the deployed platform: Kong routing, its plugins, and the
Cognito-backed auth flow.

```bash
bash setup.sh                 # from the repo root
cd bruno
npx @usebruno/cli run full-stack -r --env full-stack
```

`auth/login` stores `accessToken` and `refreshToken` as runtime variables,
which `me`, `refresh` and `api-key` then use — so **run `login` before
them**. `register` accepts either 201 or 409, since the test email is fixed
in the environment and will already exist on a second run.

The `gateway/` folder asserts on things that are invisible from the
service itself: security headers, the correlation id, the rate-limit
budget, and CORS allow/block. Those fail if the Kong plugins are applied
but not bound to a route — a real failure mode, since plugin bindings live
in two places that must agree (see CLAUDE.md, "Kong Plugin Wiring").

## Relationship to the other test layers

- `services/golang-conversion-service/**/*_test.go` — Go unit tests, no
  infrastructure, fastest feedback.
- **This collection** — hand-driven exploration and per-request assertions.
- `tests/test.sh` — the scripted integration suite that also inspects the
  cluster with `kubectl` (pod health, RDS/ElastiCache status, CloudFront TTLs).
  It covers more than Bruno can and is what to run for a full check.
