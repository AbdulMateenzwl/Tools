#!/bin/bash
# =============================================================
# ConvertX — Full Teardown Script
# Usage: bash teardown.sh
# WARNING: This deletes everything including persistent data
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
info() { echo -e "  ${YELLOW}▶${NC} $1"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ConvertX — Teardown                ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Confirm
read -p "  This will delete ALL ConvertX resources. Continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "  Aborted."
  exit 0
fi

echo ""

# ── Stop port forward ──────────────────────────────────────────
info "Stopping port forwards..."
pkill -f "port-forward" 2>/dev/null || true
ok "Port forwards stopped"

# ── Delete application namespace ──────────────────────────────
info "Deleting convertx namespace..."
kubectl delete namespace convertx --ignore-not-found > /dev/null
ok "convertx namespace deleted"

# ── Delete monitoring ──────────────────────────────────────────
# The Role and RoleBinding live in `convertx` and went with the namespace above;
# this removes Prometheus, Grafana and the ServiceAccount.
info "Deleting monitoring namespace..."
kubectl delete namespace monitoring --ignore-not-found > /dev/null
ok "monitoring namespace deleted"

# ── Delete LocalStack ──────────────────────────────────────────
info "Deleting LocalStack..."
kubectl delete namespace localstack --ignore-not-found > /dev/null
ok "LocalStack deleted"

# ── Delete Kong ────────────────────────────────────────────────
info "Uninstalling Kong..."
helm uninstall kong-operator -n kong 2>/dev/null || true

# Force delete all pods in kong namespace immediately
# Do NOT use kubectl wait here — it causes the hang
kubectl delete pods --all -n kong --force --grace-period=0 2>/dev/null || true

# Delete the namespace directly — K8s will clean up remaining resources
kubectl delete namespace kong --ignore-not-found > /dev/null &

# Wait max 30 seconds; if still stuck, force-clear finalizers on remaining resources
echo "  Waiting for kong namespace to terminate..."
for i in {1..30}; do
  EXISTS=$(kubectl get namespace kong 2>/dev/null | grep -c kong || true)
  if [ "$EXISTS" = "0" ]; then
    break
  fi
  if [ "$i" = "15" ]; then
    # Gateway Operator leaves finalizers — force-clear them
    for resource in $(kubectl api-resources --verbs=list --namespaced -o name 2>/dev/null); do
      for item in $(kubectl get "$resource" -n kong --no-headers -o name 2>/dev/null); do
        kubectl patch "$item" -n kong --type=merge \
          -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      done
    done
    # Force the namespace finalizer itself
    kubectl get namespace kong -o json 2>/dev/null | \
      python3 -c "import sys,json; ns=json.load(sys.stdin); ns['spec']['finalizers']=[]; print(json.dumps(ns))" | \
      kubectl replace --raw /api/v1/namespaces/kong/finalize -f - > /dev/null 2>&1 || true
  fi
  sleep 1
done
ok "Kong deleted"

# ── Delete MetalLB ─────────────────────────────────────────────
info "Deleting MetalLB..."
kubectl delete -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml \
  > /dev/null 2>&1 || true
kubectl delete namespace metallb-system --ignore-not-found > /dev/null
ok "MetalLB deleted"

# ── Delete PersistentVolumes ───────────────────────────────────
info "Deleting PersistentVolumes..."
kubectl delete pv postgres-pv --ignore-not-found > /dev/null
kubectl delete pv redis-pv --ignore-not-found > /dev/null
# LocalStack Pro persists RDS/ElastiCache data and secrets here.
kubectl delete pv localstack-pv --ignore-not-found > /dev/null
ok "PersistentVolumes deleted"

# ── Delete Gateway API CRDs ────────────────────────────────────
info "Deleting Gateway API CRDs..."
kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml \
  > /dev/null 2>&1 || true
ok "Gateway API CRDs deleted"

# ── Clean local data ───────────────────────────────────────────
info "Cleaning local persistent data..."
sudo rm -rf /var/lib/convertx 2>/dev/null || \
  echo "  Note: run 'sudo rm -rf /var/lib/convertx' manually if needed"
ok "Local data cleaned"

# ── Final verification ─────────────────────────────────────────
echo ""
info "Verifying teardown..."
REMAINING=$(kubectl get namespaces 2>/dev/null | \
  grep -E "convertx|kong|localstack|metallb" | \
  awk '{print $1}' | tr '\n' ' ')

if [ -z "$REMAINING" ]; then
  ok "All namespaces removed"
else
  echo -e "  ${YELLOW}Note:${NC} These namespaces are still terminating: $REMAINING"
  echo "  They will be removed automatically in a few seconds."
fi

# ── Done ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         Teardown Complete                ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  To set up again: bash setup.sh"
echo ""