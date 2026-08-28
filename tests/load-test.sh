#!/bin/bash
# =============================================================
# ConvertX — Autoscaling Load Test
#
# Drives sustained load at the conversion service and reports how the
# HorizontalPodAutoscaler responded.
#
# Usage:  bash tests/load-test.sh [DURATION_SECONDS] [CONCURRENCY]
# Default: 180s at 12 concurrent workers.
# Requires: curl, kubectl, an active port-forward on localhost:8080
#
# Two things about this stack will silently invalidate a naive load test,
# and this script handles both:
#
#   1. Kong's rate-limiting-anonymous plugin allows 20 requests PER DAY per
#      IP. At load that budget is gone in well under a second and everything
#      after is a 429 rejected AT THE GATEWAY — pod CPU stays flat and the
#      HPA never triggers. The plugin's limit is raised for the duration of
#      the run and restored on exit (including on Ctrl-C).
#
#   2. The conversion cache would absorb the load. Repeating one payload
#      means every request after the first is a Redis lookup costing almost
#      no CPU. Each request here carries a UNIQUE id, so every one is a cache
#      miss that actually runs the converter. That is the point: we are
#      trying to generate CPU, not to measure the cache.
# =============================================================

DURATION=${1:-180}
CONCURRENCY=${2:-12}
BASE_URL="http://localhost:8080"
NS="convertx"
PLUGIN="rate-limiting-anonymous"
NORMAL_DAY_LIMIT=20

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
WORKDIR=$(mktemp -d)

restore() {
  echo ""
  echo -e "${BLUE}Restoring rate limit to ${NORMAL_DAY_LIMIT}/day...${NC}"
  kubectl patch kongplugin "$PLUGIN" -n "$NS" --type=merge \
    -p "{\"config\":{\"day\":${NORMAL_DAY_LIMIT}}}" >/dev/null 2>&1 \
    && echo -e "  ${GREEN}✓${NC} rate limit restored" \
    || echo -e "  ${RED}✗${NC} FAILED to restore — run: kubectl patch kongplugin $PLUGIN -n $NS --type=merge -p '{\"config\":{\"day\":${NORMAL_DAY_LIMIT}}}'"
  rm -rf "$WORKDIR"
}
trap restore EXIT INT TERM

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     ConvertX — Autoscaling Load Test     ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  duration:    ${DURATION}s"
echo "  concurrency: ${CONCURRENCY}"
echo ""

# ── Preflight ──────────────────────────────────────────────────
if ! curl -sf "$BASE_URL/api/v1/convert/health" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} $BASE_URL unreachable — is the port-forward running?"
  exit 1
fi
if ! kubectl get hpa conversion-service -n "$NS" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} no conversion-service HPA found. Run setup.sh first."
  exit 1
fi

# An HPA whose metrics read <unknown> will never scale, and the run would
# look like a broken autoscaler rather than a missing metrics-server.
TARGETS=$(kubectl get hpa conversion-service -n "$NS" --no-headers | awk '{print $4}')
if [[ "$TARGETS" == *"unknown"* ]]; then
  echo -e "  ${YELLOW}!${NC} HPA metrics read <unknown> — metrics-server is not serving CPU yet."
  echo "     Give it ~30s after setup.sh, or check:"
  echo "       kubectl logs -n kube-system -l k8s-app=metrics-server --tail=30"
  exit 1
fi

echo -e "${BLUE}Raising rate limit for the duration of the run...${NC}"
kubectl patch kongplugin "$PLUGIN" -n "$NS" --type=merge \
  -p '{"config":{"day":100000000}}' >/dev/null
echo -e "  ${GREEN}✓${NC} raised (restored automatically on exit)"
sleep 5   # let Kong pick up the new plugin config

# ── Build a payload big enough to cost real CPU ────────────────
# json-to-xml parses and re-serialises, so work scales with document size.
ITEMS=""
for i in $(seq 1 150); do
  ITEMS="${ITEMS}{\\\"key\\\":\\\"field_${i}\\\",\\\"value\\\":\\\"payload data segment ${i} for conversion workload\\\"},"
done
ITEMS="${ITEMS%,}"

BEFORE=$(kubectl get deploy conversion-service -n "$NS" -o jsonpath='{.status.readyReplicas}')
echo ""
echo "  replicas before: ${BEFORE:-0}"
echo ""

# ── Sampler: records HPA + replica state on a timeline ─────────
(
  START=$(date +%s)
  while true; do
    NOW=$(( $(date +%s) - START ))
    # jsonpath, not awk on `kubectl get`: the TARGETS column renders as
    # "cpu: 165%/70%" with a space in it, so positional fields shift and $6
    # silently yields MAXPODS instead of the desired count.
    read -r CPU DESIRED <<<"$(kubectl get hpa conversion-service -n "$NS" \
      -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization} {.status.desiredReplicas}' 2>/dev/null)"
    READY=$(kubectl get deploy conversion-service -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    echo "${NOW}s cpu=${CPU:-?}% ready=${READY:-0} desired=${DESIRED:-?}" >> "$WORKDIR/timeline"
    sleep 10
  done
) & SAMPLER=$!

# ── Workers ────────────────────────────────────────────────────
echo -e "${BLUE}Generating load...${NC}"
END=$(( $(date +%s) + DURATION ))
for w in $(seq 1 "$CONCURRENCY"); do
  (
    n=0
    while [ "$(date +%s)" -lt "$END" ]; do
      n=$((n + 1))
      # Unique id per request => guaranteed cache miss => real converter work.
      BODY="{\"input\":\"{\\\"id\\\":\\\"w${w}-r${n}\\\",\\\"items\\\":[${ITEMS}]}\"}"
      CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
        "$BASE_URL/api/v1/convert/json-to-xml" \
        -H 'Content-Type: application/json' \
        --data-binary "$BODY" 2>/dev/null)
      echo "$CODE" >> "$WORKDIR/codes.$w"
    done
  ) &
done

# Progress ticker while the workers run.
while [ "$(date +%s)" -lt "$END" ]; do
  LEFT=$(( END - $(date +%s) ))
  REPS=$(kubectl get deploy conversion-service -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  printf "\r  %3ds left — ready replicas: %s   " "$LEFT" "${REPS:-0}"
  sleep 5
done
wait $(jobs -p | grep -v "$SAMPLER") 2>/dev/null
kill "$SAMPLER" 2>/dev/null
printf "\r%*s\r" 50 ""

# ── Results ────────────────────────────────────────────────────
TOTAL=$(cat "$WORKDIR"/codes.* 2>/dev/null | wc -l | tr -d ' ')
AFTER=$(kubectl get deploy conversion-service -n "$NS" -o jsonpath='{.status.readyReplicas}')

echo ""
echo "── Results ────────────────────────────────────"
echo "  requests sent:   $TOTAL"
echo "  throughput:      $(( TOTAL / DURATION )) req/s"
echo ""
echo "  status codes:"
cat "$WORKDIR"/codes.* 2>/dev/null | sort | uniq -c | sort -rn | sed 's/^/    /'
echo ""
echo "  replicas: ${BEFORE:-0} -> ${AFTER:-0}"
echo ""
echo "  scale timeline:"
sed 's/^/    /' "$WORKDIR/timeline" 2>/dev/null
echo ""

if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
  echo -e "  ${GREEN}✓${NC} HPA scaled out under load"
else
  echo -e "  ${YELLOW}!${NC} No scale-out. Load may be too low to cross 70% of the 100m CPU"
  echo "     request — try a longer run or higher concurrency:"
  echo "       bash tests/load-test.sh 300 32"
fi
echo ""
echo "  Scale-down takes ~60s of stabilisation after load stops. Watch it with:"
echo "    kubectl get hpa -n $NS -w"
echo ""
