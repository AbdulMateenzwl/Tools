# ConvertX — Universal File Conversion & Developer Tools Platform

A high-performance, scalable platform for file format conversion and developer
utilities. Built with Go, Java, Angular, and deployed on Kubernetes.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Local Development Setup](#local-development-setup)
- [Services](#services)
- [API Reference](#api-reference)
- [Infrastructure](#infrastructure)
- [Secrets Management](#secrets-management)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Internet
    │
    ▼
Cloudflare (CDN + WAF)          ← production only
    │
    ▼
MetalLB (L4 LoadBalancer)       ← bare metal IP assignment
    │
    ▼
Kong Gateway Operator (L7)      ← routing, auth, rate limiting
    │
    ├──► Auth Service            (Golang)   — JWT + API key management
    ├──► Conversion Service      (Golang)   — JSON/XML/CSV/YAML/Base64/URL/JWT/UUID
    ├──► Document Service        (Java)     — PDF/Word conversion (coming soon)
    └──► Image Service           (Java)     — Image conversion (coming soon)
              │
    ┌─────────┼──────────────────┐
    ▼         ▼                  ▼
PostgreSQL  Redis           LocalStack
(users,     (cache,         (S3, SQS,
 api keys)   rate limits,    SecretsManager)
             sessions)
```

---

## Tech Stack

| Layer | Technology |
|---|---|
| API Gateway | Kong Gateway Operator 3.x |
| Load Balancer | MetalLB (bare metal) |
| Auth Service | Golang 1.25, Gin, pgx, go-redis, AWS SDK v2 |
| Conversion Service | Golang 1.25, Gin, mxj, go-yaml, go-redis, AWS SDK v2 |
| Document Service | Java 21, Spring Boot 3 (planned) |
| Image Service | Java 21, Spring Boot 3 (planned) |
| Frontend | Angular 18 with SSR (planned) |
| Database | PostgreSQL 16 |
| Cache | Redis 7.2 |
| File Storage | AWS S3 / LocalStack S3 |
| Job Queue | AWS SQS / LocalStack SQS |
| Secrets | AWS SecretsManager / LocalStack SecretsManager |
| Container Orchestration | Kubernetes 1.31 |
| Local AWS Emulation | LocalStack 3.4 (community) |

---

## Project Structure

```
ConvertX/
├── infra/                              # All Kubernetes manifests
│   ├── namespace.yaml                  # convertx namespace
│   ├── kong/
│   │   ├── gateway/
│   │   │   └── gateway.yaml           # GatewayClass + Gateway
│   │   └── INSTALL.md                 # Kong installation instructions
│   ├── localstack/
│   │   ├── namespace.yaml
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── bootstrap.sh               # Creates secrets, buckets, queues
│   ├── metallb/
│   │   ├── ip-address-pool.yaml       # MetalLB IP range config
│   │   └── metallb-install.yaml       # Install reference
│   ├── postgres/
│   │   ├── postgres-configmap.yaml
│   │   ├── postgres-pv.yaml
│   │   ├── postgres-pvc.yaml
│   │   ├── postgres-statefulset.yaml
│   │   └── postgres-service.yaml
│   ├── redis/
│   │   ├── redis-deployment.yaml      # includes PV + PVC
│   │   └── redis-service.yaml
│   └── secrets-template.sh            # Documents all secrets needed
│
└── services/
    ├── auth-service/                   # Golang auth service
    │   ├── cmd/main.go
    │   ├── internal/
    │   │   ├── handler/               # HTTP handlers
    │   │   ├── service/               # Business logic
    │   │   ├── repository/            # Database queries
    │   │   ├── model/                 # Structs + request/response types
    │   │   ├── middleware/            # JWT auth middleware
    │   │   └── secrets/               # AWS SecretsManager client
    │   ├── k8s/
    │   │   ├── configmap.yaml
    │   │   ├── deployment.yaml
    │   │   ├── service.yaml
    │   │   └── httproute.yaml
    │   ├── Dockerfile
    │   └── go.mod
    │
    └── golang-conversion-service/      # Golang conversion service
        ├── cmd/main.go
        ├── internal/
        │   ├── handler/               # HTTP handlers
        │   ├── converter/             # Conversion logic
        │   ├── cache/                 # Redis caching layer
        │   ├── model/                 # Request/response types
        │   └── secrets/               # AWS SecretsManager client
        ├── k8s/
        │   ├── configmap.yaml
        │   ├── deployment.yaml
        │   ├── service.yaml
        │   └── httproute.yaml
        ├── Dockerfile
        └── go.mod
```

---

## Prerequisites

Before setting up, make sure you have these installed:

| Tool | Version | Purpose |
|---|---|---|
| Docker Desktop | Latest | Kubernetes cluster + image builds |
| kubectl | 1.31+ | K8s cluster management |
| Helm | 3.x | Kong installation |
| Go | 1.25+ | Building Go services |
| jq | Any | Pretty printing API responses |
| AWS CLI | Any | LocalStack interaction |

---

## Local Development Setup

Follow these steps in exact order. Each step depends on the previous.

### Step 1 — Enable Kubernetes in Docker Desktop

Open Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply

### Step 2 — Install MetalLB

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

kubectl apply -f infra/metallb/ip-address-pool.yaml
```

> **Note:** Update the IP range in `infra/metallb/ip-address-pool.yaml`
> to match your local network before applying.

### Step 3 — Create Namespaces

```bash
kubectl apply -f infra/namespace.yaml
```

### Step 4 — Install Kong Gateway Operator

See `infra/kong/INSTALL.md` for full details.

```bash
helm repo add kong https://charts.konghq.com
helm repo update

helm install kong-operator kong/gateway-operator \
  -n kong \
  --create-namespace

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

kubectl apply -f infra/kong/gateway/gateway.yaml
```

### Step 5 — Deploy Redis

```bash
# Create Redis secret first
kubectl create secret generic redis-secret \
  --from-literal=password=YOURPASSWORD \
  --namespace=kong

kubectl apply -f infra/redis/redis-deployment.yaml
kubectl apply -f infra/redis/redis-service.yaml
```

### Step 6 — Deploy PostgreSQL

```bash
# Create PostgreSQL secret
kubectl create secret generic postgres-secret \
  --from-literal=username=convertx \
  --from-literal=password=YOURPASSWORD \
  --from-literal=database=convertx_db \
  --namespace=convertx

kubectl apply -f infra/postgres/postgres-configmap.yaml
kubectl apply -f infra/postgres/postgres-pv.yaml
kubectl apply -f infra/postgres/postgres-pvc.yaml
kubectl apply -f infra/postgres/postgres-statefulset.yaml
kubectl apply -f infra/postgres/postgres-service.yaml
```

### Step 7 — Deploy LocalStack

```bash
kubectl apply -f infra/localstack/namespace.yaml
kubectl apply -f infra/localstack/configmap.yaml
kubectl apply -f infra/localstack/deployment.yaml
kubectl apply -f infra/localstack/service.yaml

kubectl wait --namespace localstack \
  --for=condition=ready pod \
  --selector=app=localstack \
  --timeout=120s
```

### Step 8 — Run LocalStack Bootstrap

This creates all secrets in SecretsManager, S3 buckets, and SQS queues.

```bash
kubectl cp infra/localstack/bootstrap.sh \
  localstack/$(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}'):/tmp/bootstrap.sh

kubectl exec -n localstack \
  $(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}') \
  -- bash /tmp/bootstrap.sh
```

> **Important:** Open `infra/localstack/bootstrap.sh` before running and
> replace `yourpassword` with the same password used in Steps 5 and 6.

### Step 9 — Deploy Auth Service

```bash
cd services/auth-service
docker build -t convertx/auth-service:latest .

kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/httproute.yaml

kubectl wait --namespace convertx \
  --for=condition=ready pod \
  --selector=app=auth-service \
  --timeout=120s
```

### Step 10 — Deploy Conversion Service

```bash
cd services/golang-conversion-service
docker build -t convertx/conversion-service:latest .

kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/httproute.yaml

kubectl wait --namespace convertx \
  --for=condition=ready pod \
  --selector=app=conversion-service \
  --timeout=120s
```

### Step 11 — Access the API

Kong does not expose NodePort on Docker Desktop.
Use port-forward to access all services through the gateway:

```bash
kubectl port-forward \
  svc/dataplane-ingress-convertx-gateway-wvksz-phgxj \
  8080:80 -n kong
```

All APIs are now available at `http://localhost:8080`.

> **Note:** The service name `dataplane-ingress-convertx-gateway-wvksz-phgxj`
> is auto-generated by Kong. Get the exact name with:
> `kubectl get svc -n kong`

---

## Services

### Auth Service

Handles user registration, login, JWT issuance, refresh tokens, and API key generation.

**Base URL:** `http://localhost:8080/api/v1/auth`

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/health` | GET | None | Health check |
| `/register` | POST | None | Register new user |
| `/login` | POST | None | Login, returns JWT + refresh token |
| `/refresh` | POST | None | Exchange refresh token for new JWT |
| `/me` | GET | JWT | Get current user profile |
| `/api-key` | POST | JWT | Generate API key |

### Conversion Service

Handles all format conversions and developer tools. All endpoints return
`{"output":"...","cached":true/false}`.

**Base URL:** `http://localhost:8080/api/v1`

| Endpoint | Method | Auth | Description |
|---|---|---|---|
| `/convert/health` | GET | None | Health check |
| `/convert/json-to-xml` | POST | None | Convert JSON to XML |
| `/convert/xml-to-json` | POST | None | Convert XML to JSON |
| `/convert/json-to-csv` | POST | None | Convert JSON array to CSV |
| `/convert/csv-to-json` | POST | None | Convert CSV to JSON array |
| `/convert/yaml-to-json` | POST | None | Convert YAML to JSON |
| `/convert/json-to-yaml` | POST | None | Convert JSON to YAML |
| `/tools/base64/encode` | POST | None | Base64 encode |
| `/tools/base64/decode` | POST | None | Base64 decode |
| `/tools/url/encode` | POST | None | URL encode |
| `/tools/url/decode` | POST | None | URL decode |
| `/tools/jwt/decode` | POST | None | Decode JWT without verification |
| `/tools/uuid` | GET | None | Generate UUID v4 |

---

## API Reference

### Request Format

All POST endpoints accept JSON with a single `input` field:

```json
{
  "input": "your content here"
}
```

### Response Format

Conversion endpoints:
```json
{
  "output": "converted content",
  "cached": false
}
```

Error responses:
```json
{
  "error": "description of what went wrong"
}
```

### Auth Examples

**Register:**
```bash
curl -X POST http://localhost:8080/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"you@example.com","password":"yourpassword"}'
```

**Login:**
```bash
curl -X POST http://localhost:8080/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"you@example.com","password":"yourpassword"}'
```

**Use JWT:**
```bash
curl http://localhost:8080/api/v1/auth/me \
  -H "Authorization: Bearer YOUR_ACCESS_TOKEN"
```

### Conversion Examples

**JSON to XML:**
```bash
curl -X POST http://localhost:8080/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d '{"input":"{\"name\":\"John\",\"age\":30}"}'
```

**JSON array to XML:**
```bash
curl -X POST http://localhost:8080/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d '{"input":"[{\"name\":\"John\"},{\"name\":\"Jane\"}]"}'
```

**YAML to JSON:**
```bash
curl -X POST http://localhost:8080/api/v1/convert/yaml-to-json \
  -H "Content-Type: application/json" \
  -d '{"input":"name: John\nage: 30"}'
```

---

## Infrastructure

### Namespaces

| Namespace | Contents |
|---|---|
| `convertx` | Application services + PostgreSQL |
| `kong` | Kong Gateway + Redis |
| `localstack` | LocalStack (AWS emulation) |
| `metallb-system` | MetalLB load balancer |

### Kubernetes Resources

```bash
# View all pods across all namespaces
kubectl get pods -A

# View all services
kubectl get svc -A

# View HTTPRoutes (Kong routing rules)
kubectl get httproute -A

# View gateway status
kubectl get gateway -n kong
```

### Verifying Health

```bash
# Check all pods are running
kubectl get pods -n convertx
kubectl get pods -n kong
kubectl get pods -n localstack

# Check LocalStack services
kubectl exec -n localstack \
  $(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}') \
  -- curl -s http://localhost:4566/_localstack/health | jq

# Verify secrets exist in SecretsManager
kubectl exec -n localstack \
  $(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{items[0].metadata.name}') \
  -- aws --endpoint-url=http://localhost:4566 \
  secretsmanager list-secrets \
  --query 'SecretList[].Name' \
  --output table
```

---

## Secrets Management

All application secrets are stored in **LocalStack SecretsManager** (dev)
or **AWS SecretsManager** (production). No secrets are stored in files or
committed to git.

### Secret Names

| Secret | Description | Used By |
|---|---|---|
| `convertx/redis/password` | Redis password | Auth Service, Conversion Service |
| `convertx/postgres/password` | PostgreSQL password | Auth Service |
| `convertx/postgres/username` | PostgreSQL username | Auth Service |
| `convertx/auth/jwt_secret` | JWT signing secret | Auth Service |

### K8s Secrets (Pod-level only)

These K8s secrets are needed by the infrastructure pods themselves
(not by application code — application code uses SecretsManager):

| Secret | Namespace | Used By |
|---|---|---|
| `redis-secret` | `kong` | Redis pod |
| `postgres-secret` | `convertx` | PostgreSQL pod |

See `infra/secrets-template.sh` for full documentation and recreation commands.

### Re-creating Secrets After a Fresh Cluster

```bash
# 1. Create K8s secrets for infrastructure pods
kubectl create secret generic redis-secret \
  --from-literal=password=YOURPASSWORD \
  --namespace=kong

kubectl create secret generic postgres-secret \
  --from-literal=username=convertx \
  --from-literal=password=YOURPASSWORD \
  --from-literal=database=convertx_db \
  --namespace=convertx

# 2. Deploy LocalStack and run bootstrap script (Step 7-8 above)
# This re-creates all SecretsManager secrets automatically
```

---

## Troubleshooting

### Port-forward dies after inactivity

This is a Docker Desktop limitation. Restart it:

```bash
kubectl port-forward \
  svc/$(kubectl get svc -n kong | grep dataplane-ingress | awk '{print $1}') \
  8080:80 -n kong &
```

### LocalStack secrets lost after pod restart

LocalStack community edition does not persist data. Re-run the bootstrap:

```bash
kubectl cp infra/localstack/bootstrap.sh \
  localstack/$(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}'):/tmp/bootstrap.sh

kubectl exec -n localstack \
  $(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}') \
  -- bash /tmp/bootstrap.sh
```

### Service fails to start — "load secrets" error

The auth or conversion service cannot reach LocalStack SecretsManager.

```bash
# Check LocalStack is running
kubectl get pods -n localstack

# Check the service logs
kubectl logs -n convertx -l app=auth-service --tail=20

# Verify LocalStack endpoint is reachable from convertx namespace
kubectl run -it --rm debug \
  --image=curlimages/curl \
  --namespace=convertx \
  -- curl http://localstack.localstack.svc.cluster.local:4566/_localstack/health
```

### Pod stuck in CrashLoopBackOff

```bash
# Get the exact pod name
kubectl get pods -n convertx

# Check logs of the crashing pod
kubectl logs -n convertx POD_NAME --previous
```

### PVC not binding

```bash
# Check PV and PVC status
kubectl get pv
kubectl get pvc -A

# Ensure storageClassName is "" in both PV and PVC
kubectl describe pvc PVCNAME -n NAMESPACE
```

### Image not updating after rebuild

Docker Desktop caches images aggressively. Always use versioned tags:

```bash
docker build -t convertx/auth-service:v4 .
kubectl set image deployment/auth-service \
  auth-service=convertx/auth-service:v4 \
  -n convertx
```

---

## Current Limitations (Dev Environment)

| Limitation | Reason | Production Fix |
|---|---|---|
| Must use port-forward | Docker Desktop networking | MetalLB IP works on real bare metal |
| LocalStack data lost on restart | Community edition | AWS SecretsManager persists |
| Single node cluster | Docker Desktop | Multi-node K8s on bare metal or EKS |
| No Kong plugins active | Not yet configured | Add CORS + rate limiting HTTPRoute plugins |
| Images stored locally | No registry | Push to ECR on real AWS |

---

## Roadmap

- [ ] Kong plugins — CORS, rate limiting, request logging
- [ ] Document Service — PDF↔Word conversion (Java/Spring Boot)
- [ ] Image Service — image format conversion (Java/Spring Boot)
- [ ] Angular Frontend — SSR tool pages
- [ ] B2B API dashboard — API key management UI
- [ ] CI/CD pipeline — GitHub Actions + ECR
- [ ] Production deployment — EKS or bare metal
