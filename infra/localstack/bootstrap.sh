#!/bin/bash

set -e

LOCALSTACK_URL="${LOCALSTACK_URL:-http://localstack.localstack.svc.cluster.local:4566}"
REGION="us-east-1"

# In-cluster hostname other pods use to reach LocalStack. RDS/ElastiCache
# endpoints are rewritten to this host because the address LocalStack returns
# is only meaningful from inside its own container.
CLUSTER_HOST="${CLUSTER_HOST:-localstack.localstack.svc.cluster.local}"

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=$REGION

AWS="aws --endpoint-url=$LOCALSTACK_URL"

echo "=== ConvertX LocalStack Pro Bootstrap ==="

REDIS_PASS="${REDIS_PASSWORD:-yourpassword}"
POSTGRES_PASS="${POSTGRES_PASSWORD:-yourpassword}"

put_secret() {
  local NAME=$1 VALUE=$2
  $AWS secretsmanager create-secret \
    --name "$NAME" --secret-string "$VALUE" >/dev/null 2>&1 || \
  $AWS secretsmanager update-secret \
    --secret-id "$NAME" --secret-string "$VALUE" >/dev/null
  echo "  ✓ $NAME"
}

# ─── SecretsManager — credentials ─────────────────────────────

echo "Creating secrets in SecretsManager..."

# ElastiCache here is created without --auth-token, so the cluster has no
# password and Redis rejects any AUTH command sent to it. The secret is
# therefore left ABSENT rather than empty — SecretsManager requires a
# SecretString of at least one character, so "" is not a storable value.
# Consumers treat an absent secret as "send no AUTH". Any stale value from an
# earlier run is removed so it cannot linger and break connections.
# On real AWS you would create the cluster with --auth-token plus
# --transit-encryption-enabled and store that token here instead.
$AWS secretsmanager delete-secret --secret-id "convertx/redis/password" \
  --force-delete-without-recovery >/dev/null 2>&1 || true
echo "  ✓ convertx/redis/password (absent — ElastiCache has no AUTH)"
put_secret "convertx/postgres/username" "convertx"
put_secret "convertx/postgres/password" "$POSTGRES_PASS"

# ─── RDS — replaces the postgres StatefulSet ──────────────────

echo "Creating RDS instance..."

$AWS rds create-db-instance \
  --db-instance-identifier convertx-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 16.2 \
  --master-username convertx \
  --master-user-password "$POSTGRES_PASS" \
  --allocated-storage 20 \
  --db-name convertx_db >/dev/null 2>&1 || echo "  (instance already exists)"

echo -n "  waiting for convertx-db to become available"
for i in $(seq 1 60); do
  STATUS=$($AWS rds describe-db-instances \
    --db-instance-identifier convertx-db \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "creating")
  if [ "$STATUS" = "available" ]; then break; fi
  echo -n "."
  sleep 2
done
echo ""

DB_PORT=$($AWS rds describe-db-instances \
  --db-instance-identifier convertx-db \
  --query 'DBInstances[0].Endpoint.Port' --output text)

if [ -z "$DB_PORT" ] || [ "$DB_PORT" = "None" ]; then
  echo "  ✗ could not resolve RDS port — aborting"; exit 1
fi

# Rewrite the host: LocalStack reports its own view, pods need the Service DNS.
put_secret "convertx/postgres/endpoint" "$CLUSTER_HOST:$DB_PORT"
echo "  ✓ RDS available at $CLUSTER_HOST:$DB_PORT"

# ─── ElastiCache — replaces the redis Deployment ──────────────

echo "Creating ElastiCache cluster..."

$AWS elasticache create-cache-cluster \
  --cache-cluster-id convertx-cache \
  --engine redis \
  --cache-node-type cache.t3.micro \
  --num-cache-nodes 1 >/dev/null 2>&1 || echo "  (cluster already exists)"

echo -n "  waiting for convertx-cache to become available"
for i in $(seq 1 60); do
  STATUS=$($AWS elasticache describe-cache-clusters \
    --cache-cluster-id convertx-cache \
    --query 'CacheClusters[0].CacheClusterStatus' --output text 2>/dev/null || echo "creating")
  if [ "$STATUS" = "available" ]; then break; fi
  echo -n "."
  sleep 2
done
echo ""

CACHE_PORT=$($AWS elasticache describe-cache-clusters \
  --cache-cluster-id convertx-cache \
  --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Port' --output text)

if [ -z "$CACHE_PORT" ] || [ "$CACHE_PORT" = "None" ]; then
  echo "  ✗ could not resolve ElastiCache port — aborting"; exit 1
fi

put_secret "convertx/redis/endpoint" "$CLUSTER_HOST:$CACHE_PORT"
echo "  ✓ ElastiCache available at $CLUSTER_HOST:$CACHE_PORT"

# NOTE: LocalStack's ElastiCache emulation may not enforce an AUTH token.
# If services log "ERR Client sent AUTH, but no password is set", clear it:
#   aws --endpoint-url=$LOCALSTACK_URL secretsmanager update-secret \
#     --secret-id convertx/redis/password --secret-string ""
# go-redis treats an empty password as "send no AUTH", so no redeploy is needed.

# ─── Cognito ──────────────────────────────────────────────────
# Replaces the users table, bcrypt hashing, and the hand-rolled JWT/refresh
# token machinery. The api_keys table stays in RDS — Cognito has no equivalent.

echo "Creating Cognito user pool..."

POOL_ID=$($AWS cognito-idp list-user-pools --max-results 60 \
  --query "UserPools[?Name=='convertx-users'].Id | [0]" --output text 2>/dev/null || echo "")

if [ -z "$POOL_ID" ] || [ "$POOL_ID" = "None" ]; then
  POOL_ID=$($AWS cognito-idp create-user-pool \
    --pool-name convertx-users \
    --username-attributes email \
    --auto-verified-attributes email \
    --policies '{"PasswordPolicy":{"MinimumLength":8,"RequireUppercase":true,"RequireLowercase":true,"RequireNumbers":true,"RequireSymbols":false}}' \
    --query 'UserPool.Id' --output text)
fi
echo "  ✓ user pool $POOL_ID"

CLIENT_ID=$($AWS cognito-idp list-user-pool-clients --user-pool-id "$POOL_ID" --max-results 60 \
  --query "UserPoolClients[?ClientName=='convertx-api'].ClientId | [0]" --output text 2>/dev/null || echo "")

if [ -z "$CLIENT_ID" ] || [ "$CLIENT_ID" = "None" ]; then
  # No client secret: avoids having to compute SECRET_HASH on every call.
  # Access token validity is 15 minutes to match the previous behaviour.
  CLIENT_ID=$($AWS cognito-idp create-user-pool-client \
    --user-pool-id "$POOL_ID" \
    --client-name convertx-api \
    --no-generate-secret \
    --explicit-auth-flows ALLOW_ADMIN_USER_PASSWORD_AUTH ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --access-token-validity 15 \
    --id-token-validity 15 \
    --refresh-token-validity 7 \
    --token-validity-units '{"AccessToken":"minutes","IdToken":"minutes","RefreshToken":"days"}' \
    --query 'UserPoolClient.ClientId' --output text)
fi
echo "  ✓ app client $CLIENT_ID"

# Role now comes from group membership, surfaced as the cognito:groups claim.
$AWS cognito-idp create-group \
  --group-name free --user-pool-id "$POOL_ID" \
  --description "Default tier" >/dev/null 2>&1 || true
echo "  ✓ group free"

put_secret "convertx/cognito/user_pool_id" "$POOL_ID"
put_secret "convertx/cognito/client_id"    "$CLIENT_ID"

# LocalStack serves Cognito JWKS on the edge port under the pool id, which is
# NOT the real-AWS path. Both are stored as secrets so a mismatch can be fixed
# with update-secret instead of a code change and rebuild.
put_secret "convertx/cognito/jwks_url" "http://$CLUSTER_HOST:4566/$POOL_ID/.well-known/jwks.json"

# No issuer secret is stored. LocalStack mints tokens with an "iss" of
# localhost.localstack.cloud regardless of how it is addressed, so any value
# constructed here would not match. The service instead checks that "iss" ends
# with the pool id, which is host-independent and holds on real AWS too.

# ─── ECR ──────────────────────────────────────────────────────

echo "Creating ECR repositories..."

for REPO in convertx/auth-service convertx/conversion-service; do
  $AWS ecr create-repository --repository-name "$REPO" >/dev/null 2>&1 || true
  echo "  ✓ $REPO"
done

# ─── CloudWatch Logs ──────────────────────────────────────────

echo "Creating CloudWatch log groups..."

for GROUP in /convertx/auth-service /convertx/conversion-service /convertx/kong; do
  $AWS logs create-log-group --log-group-name "$GROUP" >/dev/null 2>&1 || true
  $AWS logs put-retention-policy \
    --log-group-name "$GROUP" --retention-in-days 7 >/dev/null 2>&1 || true
  echo "  ✓ $GROUP (7d retention)"
done

# ─── CloudFront ───────────────────────────────────────────────
# Fronts the Kong gateway. Note what this distribution deliberately does NOT
# do: cache anything. Every conversion and auth endpoint is a POST (which
# CloudFront never caches), and the only GETs are health checks, /me, and
# /tools/uuid — all of which MUST stay uncached. CloudFront's default
# DefaultTTL is 86400, so leaving it unset would cache /tools/uuid and hand
# every caller the same UUID. The TTLs below are 0 for exactly that reason.
#
# The legacy ForwardedValues form is used rather than a managed CachePolicyId
# because it does not depend on AWS's managed policy IDs existing here.

if [ -z "$KONG_ORIGIN" ] || [ "$KONG_ORIGIN" = "KONG_ORIGIN_PLACEHOLDER" ]; then
  echo "Skipping CloudFront: KONG_ORIGIN not set (is the Kong dataplane up?)"
else
  echo "Creating CloudFront distribution..."

  DIST_ID=$($AWS cloudfront list-distributions \
    --query "DistributionList.Items[?Comment=='convertx-api'].Id | [0]" \
    --output text 2>/dev/null || echo "")

  if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then
    cat > /tmp/cf-config.json <<CFJSON
{
  "CallerReference": "convertx-api-distribution",
  "Comment": "convertx-api",
  "Enabled": true,
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "kong-api",
        "DomainName": "$KONG_ORIGIN",
        "CustomOriginConfig": {
          "HTTPPort": 80,
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "http-only",
          "OriginSslProtocols": { "Quantity": 1, "Items": ["TLSv1.2"] }
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "kong-api",
    "ViewerProtocolPolicy": "allow-all",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    },
    "ForwardedValues": {
      "QueryString": true,
      "Cookies": { "Forward": "all" },
      "Headers": { "Quantity": 1, "Items": ["*"] }
    },
    "MinTTL": 0,
    "DefaultTTL": 0,
    "MaxTTL": 0,
    "Compress": true
  }
}
CFJSON

    DIST_ID=$($AWS cloudfront create-distribution \
      --distribution-config file:///tmp/cf-config.json \
      --query 'Distribution.Id' --output text 2>/dev/null || echo "")
  fi

  if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then
    echo "  ! CloudFront distribution could not be created — continuing without it"
  else
    DIST_DOMAIN=$($AWS cloudfront get-distribution --id "$DIST_ID" \
      --query 'Distribution.DomainName' --output text 2>/dev/null | tr -d '\r\n')
    echo "  ✓ distribution $DIST_ID ($DIST_DOMAIN)"
    echo "  ✓ origin $KONG_ORIGIN, caching disabled on all paths"

    put_secret "convertx/cloudfront/distribution_id" "$DIST_ID"
    put_secret "convertx/cloudfront/domain"          "$DIST_DOMAIN"
  fi
fi

# ─── S3 Buckets ───────────────────────────────────────────────

echo "Creating S3 buckets..."

$AWS s3api create-bucket --bucket convertx-files >/dev/null 2>&1 || true
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
  }' >/dev/null 2>&1 || true
echo "  ✓ convertx-files lifecycle rule set"

# ─── SQS Queues ───────────────────────────────────────────────

echo "Creating SQS queues..."

for QUEUE in convertx-document-jobs convertx-image-jobs convertx-dead-letter; do
  $AWS sqs create-queue --queue-name "$QUEUE" >/dev/null 2>&1 || true
  echo "  ✓ $QUEUE queue"
done

# ─── Verify ───────────────────────────────────────────────────

echo ""
echo "=== Verification ==="

echo "Secrets:"
$AWS secretsmanager list-secrets --query 'SecretList[].Name' --output table

echo "RDS:"
$AWS rds describe-db-instances \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Port]' --output table

echo "ElastiCache:"
$AWS elasticache describe-cache-clusters \
  --query 'CacheClusters[].[CacheClusterId,CacheClusterStatus]' --output table

echo "Cognito:"
$AWS cognito-idp list-user-pools --max-results 60 \
  --query 'UserPools[].[Name,Id]' --output table

echo "ECR:"
$AWS ecr describe-repositories --query 'repositories[].repositoryName' --output table

echo "CloudFront:"
$AWS cloudfront list-distributions   --query 'DistributionList.Items[].[Id,Comment,Status]' --output table 2>/dev/null || echo "  (none)"

echo "S3 Buckets:"
$AWS s3api list-buckets --query 'Buckets[].Name' --output table

echo "SQS Queues:"
$AWS sqs list-queues --output table

echo ""
echo "=== Bootstrap Complete ==="
echo "  postgres endpoint → $CLUSTER_HOST:$DB_PORT"
echo "  redis endpoint    → $CLUSTER_HOST:$CACHE_PORT"
