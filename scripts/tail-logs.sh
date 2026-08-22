#!/bin/bash
# =============================================================
# ConvertX — read shipped logs back out of CloudWatch Logs
# Usage: bash scripts/tail-logs.sh [log-group] [minutes]
#   bash scripts/tail-logs.sh                        # kong, last 15 min
#   bash scripts/tail-logs.sh /convertx/auth-service 60
# =============================================================

set -e

GROUP="${1:-/convertx/kong}"
MINUTES="${2:-15}"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

LOCALSTACK_POD=$(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$LOCALSTACK_POD" ]; then
  echo -e "  ${RED}✗${NC} LocalStack pod not found. Run setup.sh first."; exit 1
fi

# CloudWatch wants milliseconds since epoch.
START=$(( ($(date +%s) - MINUTES * 60) * 1000 ))

echo ""
echo -e "  ${GREEN}▶${NC} $GROUP — last ${MINUTES}m"
echo ""

STREAMS=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
  awslocal logs describe-log-streams --log-group-name "$GROUP" \
    --query 'logStreams[].logStreamName' --output text 2>/dev/null | tr -d '\r')

if [ -z "$STREAMS" ]; then
  echo "  No log streams yet in $GROUP."
  echo "  fluent-bit creates a stream on first delivery — check it is running:"
  echo "    kubectl logs -n convertx -l app=fluent-bit --tail=30"
  echo ""
  exit 0
fi

echo "  Streams: $STREAMS"
echo ""

kubectl exec -n localstack "$LOCALSTACK_POD" -- \
  awslocal logs filter-log-events \
    --log-group-name "$GROUP" \
    --start-time "$START" \
    --query 'events[].message' \
    --output text 2>/dev/null | tr '\t' '\n'

echo ""
