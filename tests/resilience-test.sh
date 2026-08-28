#!/bin/bash
# =============================================================
# ConvertX — Resilience Test (self-healing + zero-downtime rollout)
#
# Usage:  bash tests/resilience-test.sh [PHASE]
#           PHASE = kill | rollout | all   (default: all)
#
# Companion to load-test.sh. That script answers "does the HPA add pods
# under load"; this one answers "does traffic survive losing a pod, and
# does a deploy drop requests".
#
# Both phases hold a steady stream of requests while something disruptive
# happens, then count what failed. The number that matters is curl code
# 000 — a connection refused / reset / timeout, i.e. a request that never
# got an answer. A 5xx is also a failure but a different one: the pod
# answered, badly.
#
# Deliberate choices:
#
#   * Concurrency is 3, NOT the 12 that load-test.sh uses. This test must
#     stay BELOW the HPA's 70% threshold. If the autoscaler starts adding
#     and removing pods mid-rollout, replica counts move for two reasons
#     at once and "did the rollout drop traffic" becomes unanswerable.
#
#   * A baseline phase runs first and must be clean. Without it, a failure
#     during the kill phase cannot be attributed to the kill — it might
#     just be the port-forward, Kong, or the harness itself misbehaving.
#
#   * Kong's rate limit is raised for the run and restored on exit, same
#     as load-test.sh. Restore by hand if this is SIGKILLed:
#       kubectl patch kongplugin rate-limiting-anonymous -n convertx \
#         --type=merge -p '{"config":{"day":20}}'
# =============================================================

PHASE=${1:-all}
BASE_URL="http://localhost:8080"
NS="convertx"
DEPLOY="conversion-service"
PLUGIN="rate-limiting-anonymous"
NORMAL_DAY_LIMIT=20
CONCURRENCY=3

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
WORKDIR=$(mktemp -d)
LOADPIDS=""

cleanup() {
  [ -n "$LOADPIDS" ] && kill $LOADPIDS 2>/dev/null
  echo ""
  echo -e "${BLUE}Restoring rate limit to ${NORMAL_DAY_LIMIT}/day...${NC}"
  reset_rate_limit
  kubectl patch kongplugin "$PLUGIN" -n "$NS" --type=merge \
    -p "{\"config\":{\"day\":${NORMAL_DAY_LIMIT}}}" >/dev/null 2>&1 \
    && echo -e "  ${GREEN}✓${NC} rate limit restored" \
    || echo -e "  ${RED}✗${NC} FAILED to restore — run: kubectl patch kongplugin $PLUGIN -n $NS --type=merge -p '{\"config\":{\"day\":${NORMAL_DAY_LIMIT}}}'"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# ── Rate limit counter ─────────────────────────────────────────
# Raising the plugin's limit is not enough on its own. The counter in Redis
# DB 1 persists, so after load-test.sh has spent ~59k requests against this
# IP the budget is already blown and every request 429s the moment the limit
# is restored. Flush the counter, don't just raise the ceiling.
LOCALSTACK_POD=$(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
REDIS_ENDPOINT=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
  awslocal secretsmanager get-secret-value --secret-id convertx/redis/endpoint \
  --query SecretString --output text 2>/dev/null)
REDIS_EP_PORT="${REDIS_ENDPOINT##*:}"

reset_rate_limit() {
  # ElastiCache here has no AUTH, so no -a flag. See CLAUDE.md.
  kubectl exec -n localstack "$LOCALSTACK_POD" -- \
    redis-cli -h 127.0.0.1 -p "$REDIS_EP_PORT" -n 1 FLUSHDB >/dev/null 2>&1
}

# ── Load generation ────────────────────────────────────────────
# Each worker appends "epoch code" to its OWN file; a shared file would
# interleave partial writes and corrupt the count.
start_load() {
  local tag=$1
  rm -f "$WORKDIR/$tag".* 2>/dev/null
  LOADPIDS=""
  for w in $(seq 1 "$CONCURRENCY"); do
    (
      n=0
      while true; do
        n=$((n + 1))
        # --max-time bounds a hung connection so a stalled request shows up
        # as a failure instead of wedging the worker for the whole phase.
        CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
          "$BASE_URL/api/v1/convert/json-to-xml" \
          -H 'Content-Type: application/json' \
          --data-binary "{\"input\":\"{\\\"id\\\":\\\"$tag-w${w}-r${n}\\\",\\\"v\\\":\\\"resilience probe\\\"}\"}" \
          2>/dev/null)
        echo "$(date +%s) ${CODE:-000}" >> "$WORKDIR/$tag.$w"
      done
    ) &
    LOADPIDS="$LOADPIDS $!"
  done
}

stop_load() {
  [ -n "$LOADPIDS" ] && kill $LOADPIDS 2>/dev/null
  wait $LOADPIDS 2>/dev/null
  LOADPIDS=""
}

# Prints the verdict for a phase. Returns 1 if any request failed.
report() {
  local tag=$1 label=$2
  local total ok bad
  total=$(cat "$WORKDIR/$tag".* 2>/dev/null | wc -l | tr -d ' ')
  ok=$(cat "$WORKDIR/$tag".* 2>/dev/null | awk '$2==200' | wc -l | tr -d ' ')
  bad=$((total - ok))

  echo ""
  echo "  ── $label ─────────────────────────"
  echo "    requests:  $total"
  echo "    succeeded: $ok"
  if [ "$bad" -eq 0 ]; then
    echo -e "    failed:    ${GREEN}0${NC}"
    return 0
  fi
  # -v rather than string interpolation: inlining the values into the awk
  # program makes the "%.2f" format collide with shell quoting.
  local pct
  pct=$(awk -v b="$bad" -v t="$total" 'BEGIN{printf "%.2f", b*100/t}')
  echo -e "    failed:    ${RED}${bad}${NC}  (${pct}%)"
  echo "    breakdown:"
  cat "$WORKDIR/$tag".* 2>/dev/null | awk '$2!=200 {print $2}' | sort | uniq -c \
    | sed 's/^/      /'
  echo "      (000 = no response: connection refused, reset, or timeout)"
  # Failure window, to confirm drops line up with the disruption.
  local first last
  first=$(cat "$WORKDIR/$tag".* 2>/dev/null | awk '$2!=200 {print $1}' | sort -n | head -1)
  last=$(cat "$WORKDIR/$tag".* 2>/dev/null | awk '$2!=200 {print $1}' | sort -n | tail -1)
  echo "    failures spanned $((last - first))s"
  return 1
}

ready_count() {
  kubectl get deploy "$DEPLOY" -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      ConvertX — Resilience Test          ║"
echo "╚══════════════════════════════════════════╝"

# ── Preflight ──────────────────────────────────────────────────
if ! kubectl get deploy "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} no $DEPLOY deployment. Run setup.sh first."
  exit 1
fi

# Raise the ceiling and clear the counter BEFORE health-checking, or a
# previous run's spent budget makes a perfectly healthy gateway look dead.
echo ""
echo -e "${BLUE}Raising rate limit for the duration of the run...${NC}"
kubectl patch kongplugin "$PLUGIN" -n "$NS" --type=merge \
  -p '{"config":{"day":100000000}}' >/dev/null
reset_rate_limit
echo -e "  ${GREEN}✓${NC} raised and counter flushed (restored automatically on exit)"
sleep 5   # let Kong pick up the new plugin config

# Check reachability by status code, NOT curl -f. `-f` treats 429 as a
# failure, which reports a rate-limited gateway as an unreachable one and
# sends you looking for a dead port-forward that is fine.
HEALTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  "$BASE_URL/api/v1/convert/health" 2>/dev/null)
case "$HEALTH" in
  200) ;;
  000) echo -e "  ${RED}✗${NC} $BASE_URL unreachable — is the port-forward running?"
       echo "     kubectl port-forward svc/\$(kubectl get svc -n kong --no-headers \\"
       echo "       | grep dataplane-ingress | awk '{print \$1}') 8080:80 -n kong &"
       exit 1 ;;
  429) echo -e "  ${RED}✗${NC} still rate limited after flush — is DB 1 the right counter db?"
       exit 1 ;;
  *)   echo -e "  ${RED}✗${NC} health check returned $HEALTH, expected 200"
       exit 1 ;;
esac

FAILED=0

# ── Baseline ───────────────────────────────────────────────────
# If this is not clean, nothing below can be attributed to a disruption.
echo ""
echo -e "${BLUE}Baseline: 15s of undisturbed load...${NC}"
start_load baseline
sleep 15
stop_load
if ! report baseline "Baseline (no disruption)"; then
  echo ""
  echo -e "  ${RED}✗${NC} baseline is not clean — failures here are NOT the cluster's"
  echo "     doing. Check the port-forward and Kong before trusting any"
  echo "     result below."
  exit 1
fi

# ── Phase 1: self-healing ──────────────────────────────────────
if [ "$PHASE" = "kill" ] || [ "$PHASE" = "all" ]; then
  echo ""
  echo -e "${BLUE}Phase 1 — self-healing: killing a pod under load${NC}"
  BEFORE=$(ready_count)
  echo "    ready before: $BEFORE"

  start_load kill
  sleep 10
  VICTIM=$(kubectl get pods -n "$NS" -l app="$DEPLOY" \
    -o jsonpath='{.items[0].metadata.name}')
  echo "    deleting $VICTIM ..."
  kubectl delete pod "$VICTIM" -n "$NS" --wait=false >/dev/null 2>&1
  KILL_AT=$(date +%s)

  # Wait for the deployment to return to its pre-kill ready count.
  RECOVERED=""
  for i in $(seq 1 60); do
    if [ "$(ready_count)" -ge "$BEFORE" ] 2>/dev/null; then
      RECOVERED=$(( $(date +%s) - KILL_AT )); break
    fi
    sleep 2
  done
  sleep 5
  stop_load

  report kill "Phase 1 — pod killed" || FAILED=1
  if [ -n "$RECOVERED" ]; then
    echo -e "    ${GREEN}✓${NC} replacement pod ready ${RECOVERED}s after the kill"
  else
    echo -e "    ${RED}✗${NC} never returned to $BEFORE ready replicas within 120s"
    FAILED=1
  fi
fi

# ── Phase 2: zero-downtime rollout ─────────────────────────────
if [ "$PHASE" = "rollout" ] || [ "$PHASE" = "all" ]; then
  echo ""
  echo -e "${BLUE}Phase 2 — zero-downtime: rolling restart under load${NC}"
  start_load rollout
  sleep 10
  echo "    kubectl rollout restart deployment/$DEPLOY ..."
  kubectl rollout restart deployment/"$DEPLOY" -n "$NS" >/dev/null
  ROLL_AT=$(date +%s)
  if kubectl rollout status deployment/"$DEPLOY" -n "$NS" --timeout=180s >/dev/null 2>&1; then
    echo -e "    ${GREEN}✓${NC} rollout completed in $(( $(date +%s) - ROLL_AT ))s"
  else
    echo -e "    ${RED}✗${NC} rollout did not complete within 180s"
    FAILED=1
  fi
  sleep 5
  stop_load

  report rollout "Phase 2 — rolling restart" || FAILED=1
fi

# ── Verdict ────────────────────────────────────────────────────
echo ""
echo "── Verdict ────────────────────────────────────"
if [ "$FAILED" -eq 0 ]; then
  echo -e "  ${GREEN}✓${NC} no requests dropped — self-healing and rollout are clean"
else
  echo -e "  ${YELLOW}!${NC} requests were dropped."
  echo ""
  echo "     Both services call gin's r.Run(), which has no signal handling,"
  echo "     so SIGTERM kills the process instantly and every in-flight"
  echo "     request dies with it. Two fixes, both needed:"
  echo "       1. http.Server.Shutdown() on SIGTERM, to drain in flight work"
  echo "       2. a preStop sleep, because endpoint removal is asynchronous —"
  echo "          without it Kong still routes to a pod that is already dying"
fi
echo ""
