# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ConvertX is a microservices platform for file conversion and developer utilities, running on Kubernetes (Docker Desktop) with Kong Gateway for L7 routing. All application secrets are fetched at runtime from LocalStack (AWS SecretsManager emulation) — there are no secrets in environment variables or config maps.

## Build Commands

Each service builds independently from its own directory:

```bash
# Auth service
cd services/auth-service
go mod download
CGO_ENABLED=0 GOOS=linux go build -o auth-service ./cmd/main.go

# Conversion service
cd services/golang-conversion-service
go mod download
CGO_ENABLED=0 GOOS=linux go build -o conversion-service ./cmd/main.go
```

Docker builds use multi-stage (golang:1.25-alpine → alpine:3.19):
```bash
docker build -t convertx/auth-service:latest services/auth-service/
docker build -t convertx/conversion-service:latest services/golang-conversion-service/
```

There are no test files or linting configs currently. Run `go vet ./...` inside a service directory for static analysis.

## Local Kubernetes Deployment

Prerequisites: Docker Desktop with Kubernetes enabled, kubectl 1.31+, Helm 3.x, Go 1.25+, jq.

Full setup order (first time):
1. Install MetalLB: `kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml`
2. `kubectl apply -f infra/namespace.yaml` — creates `convertx`, `kong`, `localstack` namespaces
3. Install Kong Gateway Operator via Helm (see `Readme.md` for exact commands)
4. Deploy infrastructure: Redis → PostgreSQL → LocalStack
5. Run `infra/localstack/bootstrap.sh` to seed secrets, S3 bucket, and SQS queues into LocalStack
6. Deploy services: `kubectl apply -f services/auth-service/k8s/` then `kubectl apply -f services/golang-conversion-service/k8s/`

Access via port-forward (Kong ingress pod name varies):
```bash
kubectl port-forward svc/<dataplane-ingress-pod> 8080:80 -n kong
```

## Architecture

### Services

**Auth Service** (`services/auth-service/`) — handles user registration, JWT auth, and API key management. Connects to PostgreSQL (pgxpool) and Redis. Auto-migrates schema (`users`, `api_keys` tables) on startup.

**Conversion Service** (`services/golang-conversion-service/`) — stateless format conversion and developer tools. Caches conversion results in Redis with a configurable TTL (`CACHE_TTL_MINUTES`, default 60). No database.

Both services follow the same internal package layout:
```
cmd/main.go          → entry point, wires dependencies
internal/handler/    → Gin route handlers
internal/service/    → business logic
internal/repository/ → DB layer (auth only)
internal/converter/  → format conversion logic (conversion only)
internal/cache/      → Redis cache wrapper (conversion only)
internal/model/      → request/response structs
internal/middleware/ → JWT validation
internal/secrets/    → AWS SecretsManager client (fetches at startup)
```

### Secret Fetching Pattern

Both services fetch secrets from LocalStack SecretsManager at startup via `internal/secrets/`. The secrets fetched are:
- `convertx/redis/password`
- `convertx/postgres/password` (auth only)
- `convertx/postgres/username` (auth only)
- `convertx/auth/jwt_secret` (auth only)

AWS credentials are `test/test` pointed at `http://localstack.localstack.svc.cluster.local:4566` (set in K8s ConfigMaps). This same pattern will work with real AWS by swapping the endpoint and credentials.

### Infrastructure Layout

```
infra/
  namespace.yaml          → creates all namespaces
  metallb/                → L4 load balancer config
  kong/                   → Kong Gateway Operator + plugins + gateway/httproute
  postgres/               → StatefulSet + PVC in `convertx` namespace
  redis/                  → Deployment in `kong` namespace
  localstack/             → Deployment + bootstrap.sh seed script
```

Kong plugins configured cluster-wide: CORS, rate limiting (anonymous), request size limiting, response headers, request ID, request logging. Bindings live in `infra/kong/plugins/`.

### API Routes

Auth service (via Kong at `/api/v1/auth`): `POST /register`, `POST /login`, `POST /refresh`, `GET /me`, `POST /api-key`

Conversion service (via Kong at `/api/v1`): `POST /convert/{json-to-xml,xml-to-json,json-to-csv,csv-to-json,yaml-to-json,json-to-yaml}`, `POST /tools/{base64/encode,base64/decode,url/encode,url/decode,jwt/decode}`, `GET /tools/uuid`
