#!/bin/bash
# =============================================================
# ConvertX — Stop (without deleting)
# Usage: bash stop.sh
#
# Scales workloads to zero and stops the port-forward. Namespaces,
# PersistentVolumes, secrets, Kong and MetalLB all stay in place.
#
# Resume with setup.sh — it is idempotent and re-applies the deployment
# manifests, which restores the replica counts. There is no separate start
# script: it would duplicate most of setup.sh for about a minute's saving.
#
# To delete everything instead, use teardown.sh.
#
# NOTE: RDS data does not survive a stop. LocalStack reassigns the external
# port on restore and leaves a dead proxy, so bootstrap.sh rebuilds the
# instance and the api_keys table starts empty. Cognito users, secrets, S3,
# SQS and ECR do survive, since they have no such proxy.
# =============================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}▶${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ConvertX — Stop                    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if ! kubectl get namespace convertx >/dev/null 2>&1; then
  echo -e "  ${RED}✗${NC} convertx namespace not found — nothing to stop."
  echo "    Run setup.sh first, or teardown.sh if you want a clean slate."
  exit 1
fi

# ── Port forward ───────────────────────────────────────────────
info "Stopping port forwards..."
pkill -f "port-forward" 2>/dev/null || true
ok "Port forwards stopped"

# Record the current replica count as an annotation. setup.sh restores from
# the manifests rather than reading it, but it makes the stopped state
# self-describing and survives if the manifest replica count ever changes.
scale_down() {
  local NS=$1 DEPLOY=$2
  if ! kubectl get deployment "$DEPLOY" -n "$NS" >/dev/null 2>&1; then
    warn "$DEPLOY not found in $NS, skipping"
    return
  fi
  local CURRENT
  CURRENT=$(kubectl get deployment "$DEPLOY" -n "$NS" -o jsonpath='{.spec.replicas}')
  if [ "$CURRENT" != "0" ]; then
    kubectl annotate deployment "$DEPLOY" -n "$NS" \
      convertx.io/replicas-before-stop="$CURRENT" --overwrite >/dev/null
  fi
  kubectl scale deployment "$DEPLOY" -n "$NS" --replicas=0 >/dev/null
  ok "$DEPLOY scaled to 0 (was $CURRENT)"
}

echo ""
info "Scaling down services..."
scale_down convertx auth-service
scale_down convertx conversion-service

# A DaemonSet has no replica count. Parking one with an unsatisfiable
# nodeSelector looks tidier, but `kubectl apply` cannot undo it — a three-way
# merge treats a patched-in field as externally managed and leaves it, so
# setup.sh would bring everything else back and silently leave log shipping
# dead. Deleting is the only stop that setup.sh can reverse, and fluent-bit
# holds no state worth preserving.
echo ""
info "Removing log shipping..."
if kubectl get daemonset fluent-bit -n convertx >/dev/null 2>&1; then
  kubectl delete daemonset fluent-bit -n convertx >/dev/null
  ok "fluent-bit removed (setup.sh recreates it)"
else
  warn "fluent-bit not found, skipping"
fi

# LocalStack last: the services depend on it, so it should outlive them.
echo ""
info "Scaling down LocalStack..."
scale_down localstack localstack

echo ""
info "Waiting for pods to terminate..."
kubectl wait --for=delete pod -n convertx --selector=app=auth-service --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=delete pod -n convertx --selector=app=conversion-service --timeout=120s >/dev/null 2>&1 || true
kubectl wait --for=delete pod -n localstack --selector=app=localstack --timeout=120s >/dev/null 2>&1 || true
ok "Workloads stopped"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         Stopped                          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Kept: namespaces, PersistentVolumes, secrets, Kong, MetalLB"
echo "  Still running:"
kubectl get pods -n kong --no-headers 2>/dev/null | grep -v "operator\|konnect" | awk '{print "    "$1"  "$3}' || true
echo ""
echo "  To start again:  bash setup.sh"
echo "  To delete all:   bash teardown.sh"
echo ""
