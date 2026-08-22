#!/bin/bash
# Seeds the two secrets the conversion service reads when AWS_ENDPOINT_URL is
# set. Runs automatically inside the compose LocalStack once it is ready.
set -e

REDIS_ENDPOINT="${SEED_REDIS_ENDPOINT:-localhost:6379}"
REDIS_PASSWORD="${SEED_REDIS_PASSWORD:-localdev}"

put() {
  awslocal secretsmanager create-secret --name "$1" --secret-string "$2" >/dev/null 2>&1 ||
  awslocal secretsmanager update-secret --secret-id "$1" --secret-string "$2" >/dev/null
  echo "  seeded $1"
}

# The endpoint is the address as seen by the service, which runs on the host.
put "convertx/redis/endpoint" "$REDIS_ENDPOINT"
put "convertx/redis/password" "$REDIS_PASSWORD"

echo "conversion service secrets ready"
