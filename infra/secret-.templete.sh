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

# convertx/cognito/user_pool_id
# convertx/cognito/client_id
#   Value: ids of the convertx-users pool and convertx-api app client
#   Used by: auth-service
#   Created by: bootstrap.sh (cognito-idp create-user-pool / -client)

# convertx/cognito/jwks_url
#   Value: where RS256 signing keys are fetched from. Stored rather than
#          derived because LocalStack serves these on a different path
#          than real AWS.
#   Used by: auth-service

# convertx/cognito/issuer
#   Value: expected "iss" claim. Empty disables the check.
#   Used by: auth-service

# NOTE: convertx/auth/jwt_secret is obsolete. Cognito signs with its own
# RSA keys, so there is no shared signing secret any more.

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