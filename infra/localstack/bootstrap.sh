#!/bin/bash

set -e

LOCALSTACK_URL="${LOCALSTACK_URL:-http://localstack.localstack.svc.cluster.local:4566}"
REGION="us-east-1"

# AWS CLI v1 syntax — no inline credentials, use env vars instead
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=$REGION

AWS="aws --endpoint-url=$LOCALSTACK_URL"

echo "=== ConvertX LocalStack Bootstrap ==="

REDIS_PASS="${REDIS_PASSWORD:-yourpassword}"
POSTGRES_PASS="${POSTGRES_PASSWORD:-yourpassword}"

# ─── SecretsManager ───────────────────────────────────────────

echo "Creating secrets in SecretsManager..."

$AWS secretsmanager create-secret \
  --name "convertx/redis/password" \
  --secret-string "$REDIS_PASS" 2>/dev/null || \
$AWS secretsmanager update-secret \
  --secret-id "convertx/redis/password" \
  --secret-string "$REDIS_PASS"
echo "  ✓ convertx/redis/password"

$AWS secretsmanager create-secret \
  --name "convertx/postgres/username" \
  --secret-string "convertx" 2>/dev/null || \
$AWS secretsmanager update-secret \
  --secret-id "convertx/postgres/username" \
  --secret-string "convertx"
echo "  ✓ convertx/postgres/username"

$AWS secretsmanager create-secret \
  --name "convertx/postgres/password" \
  --secret-string "$POSTGRES_PASS" 2>/dev/null || \
$AWS secretsmanager update-secret \
  --secret-id "convertx/postgres/password" \
  --secret-string "$POSTGRES_PASS"
echo "  ✓ convertx/postgres/password"

JWT_SECRET="${JWT_SECRET:-$(openssl rand -hex 32 2>/dev/null || od -An -tx1 -N32 /dev/urandom | tr -d ' \n')}"
$AWS secretsmanager create-secret \
  --name "convertx/auth/jwt_secret" \
  --secret-string "$JWT_SECRET" 2>/dev/null || \
$AWS secretsmanager update-secret \
  --secret-id "convertx/auth/jwt_secret" \
  --secret-string "$JWT_SECRET"
echo "  ✓ convertx/auth/jwt_secret"

# ─── S3 Buckets ───────────────────────────────────────────────

echo "Creating S3 buckets..."

$AWS s3api create-bucket --bucket convertx-files 2>/dev/null || true
echo "  ✓ convertx-files bucket"

$AWS s3api put-bucket-lifecycle-configuration \
  --bucket convertx-files \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "auto-delete-1h",
      "Status": "Enabled",
      "Expiration": {"Days": 1},
      "Filter": {"Prefix": ""}
    }]
  }' 2>/dev/null || true
echo "  ✓ convertx-files lifecycle rule set"

# ─── SQS Queues ───────────────────────────────────────────────

echo "Creating SQS queues..."

$AWS sqs create-queue --queue-name convertx-document-jobs 2>/dev/null || true
echo "  ✓ convertx-document-jobs queue"

$AWS sqs create-queue --queue-name convertx-image-jobs 2>/dev/null || true
echo "  ✓ convertx-image-jobs queue"

$AWS sqs create-queue --queue-name convertx-dead-letter 2>/dev/null || true
echo "  ✓ convertx-dead-letter queue"

# ─── Verify ───────────────────────────────────────────────────

echo ""
echo "=== Verification ==="

echo "Secrets:"
$AWS secretsmanager list-secrets --query 'SecretList[].Name' --output table

echo "S3 Buckets:"
$AWS s3api list-buckets --query 'Buckets[].Name' --output table

echo "SQS Queues:"
$AWS sqs list-queues --output table

echo ""
echo "=== Bootstrap Complete ==="