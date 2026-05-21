#!/bin/bash
# =============================================================
# ConvertX Secrets Template
# DO NOT commit real values — this is documentation only
# Run bootstrap.sh to create real secrets in LocalStack
# =============================================================

# All secrets live in LocalStack SecretsManager (dev)
# or AWS SecretsManager (production)
# Endpoint: http://localstack.localstack.svc.cluster.local:4566

# ── Secret Names & Their Consumers ───────────────────────────

# convertx/redis/password
#   Value: Redis password
#   Used by: auth-service, golang-conversion-service
#   Namespace: both services in convertx namespace

# convertx/postgres/password
#   Value: PostgreSQL password
#   Used by: auth-service
#   K8s secret still needed: postgres-secret (for PostgreSQL pod itself)

# convertx/postgres/username
#   Value: PostgreSQL username (convertx)
#   Used by: auth-service

# convertx/auth/jwt_secret
#   Value: 32-byte hex random string
#   Used by: auth-service
#   Generate: openssl rand -hex 32

# ── K8s Secrets Still Required (not in SecretsManager) ───────

# postgres-secret (convertx namespace)
#   Used by: PostgreSQL StatefulSet pod itself
#   kubectl create secret generic postgres-secret \
#     --from-literal=username=convertx \
#     --from-literal=password=YOURPASSWORD \
#     --from-literal=database=convertx_db \
#     --namespace=convertx

# redis-secret (kong namespace)
#   Used by: Redis pod itself
#   kubectl create secret generic redis-secret \
#     --from-literal=password=YOURPASSWORD \
#     --namespace=kong

# ── To Recreate All Secrets ───────────────────────────────────
# 1. Deploy LocalStack: kubectl apply -f infra/localstack/
# 2. Run bootstrap: kubectl cp infra/localstack/bootstrap.sh ...
#    then: kubectl exec ... -- bash /tmp/bootstrap.sh