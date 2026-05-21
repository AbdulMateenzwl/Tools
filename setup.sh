#!/bin/bash
# =============================================================
# ConvertX — Full Setup Script
# Usage: bash setup.sh
# Run from project root
# =============================================================

set -e

PROJECT_ROOT=$(pwd)

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }
info() { echo -e "  ${YELLOW}▶${NC} $1"; }

# ── Load .env ──────────────────────────────────────────────────
if [ ! -f .env ]; then
  err ".env file not found. Copy .env.example to .env and fill in your passwords."
fi

source .env

if [ -z "$REDIS_PASSWORD" ] || [ -z "$POSTGRES_PASSWORD" ]; then
  err "REDIS_PASSWORD and POSTGRES_PASSWORD must be set in .env"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ConvertX — Full Setup              ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Step 1: Namespaces ─────────────────────────────────────────
echo "▶ Step 1: Creating namespaces..."
kubectl apply -f infra/namespace.yaml
ok "Namespaces ready"

# ── Step 2: MetalLB ────────────────────────────────────────────
echo ""
echo "▶ Step 2: Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml > /dev/null
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s > /dev/null
kubectl apply -f infra/metallb/ip-address-pool.yaml > /dev/null
ok "MetalLB ready"

# ── Step 3: Kong Gateway Operator ─────────────────────────────
echo ""
echo "▶ Step 3: Installing Kong Gateway Operator..."
helm repo add kong https://charts.konghq.com 2>/dev/null || true
helm repo update > /dev/null

if helm status kong-operator -n kong > /dev/null 2>&1; then
  ok "Kong already installed, skipping helm install"
else
  helm install kong-operator kong/gateway-operator \
    -n kong \
    --create-namespace \
    --wait > /dev/null
  ok "Kong Gateway Operator installed"
fi

kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml > /dev/null
kubectl apply -f infra/kong/gateway/gateway.yaml > /dev/null

# Wait for Kong gateway to be programmed
echo "  Waiting for Kong gateway to be ready..."
for i in {1..30}; do
  STATUS=$(kubectl get gateway convertx-gateway -n kong \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
  if [ "$STATUS" = "True" ]; then
    break
  fi
  sleep 3
done
ok "Kong Gateway ready"

# ── Step 4: Redis ──────────────────────────────────────────────
echo ""
echo "▶ Step 4: Deploying Redis..."
sed "s/yourpassword/$REDIS_PASSWORD/g" \
  infra/redis/redis-secret.yaml | kubectl apply -f - > /dev/null

# Redis secret also needed in convertx namespace
kubectl create secret generic redis-secret \
  --from-literal=password=$REDIS_PASSWORD \
  --namespace=convertx \
  --dry-run=client -o yaml | kubectl apply -f - > /dev/null

kubectl apply -f infra/redis/redis-deployment.yaml > /dev/null
kubectl apply -f infra/redis/redis-service.yaml > /dev/null

kubectl wait --namespace kong \
  --for=condition=ready pod \
  --selector=app=redis \
  --timeout=60s > /dev/null
ok "Redis ready"

# ── Step 5: PostgreSQL ─────────────────────────────────────────
echo ""
echo "▶ Step 5: Deploying PostgreSQL..."
sed "s/yourpassword/$POSTGRES_PASSWORD/g" \
  infra/postgres/postgres-secret.yaml | kubectl apply -f - > /dev/null
kubectl apply -f infra/aws-credentials-secret.yaml > /dev/null

kubectl apply -f infra/postgres/postgres-configmap.yaml > /dev/null
kubectl apply -f infra/postgres/postgres-pv.yaml > /dev/null
kubectl apply -f infra/postgres/postgres-pvc.yaml > /dev/null
kubectl apply -f infra/postgres/postgres-statefulset.yaml > /dev/null
kubectl apply -f infra/postgres/postgres-service.yaml > /dev/null

kubectl wait --namespace convertx \
  --for=condition=ready pod \
  --selector=app=postgres \
  --timeout=120s > /dev/null
ok "PostgreSQL ready"

# ── Step 6: LocalStack ─────────────────────────────────────────
echo ""
echo "▶ Step 6: Deploying LocalStack..."
kubectl apply -f infra/localstack/namespace.yaml > /dev/null
kubectl apply -f infra/localstack/configmap.yaml > /dev/null
kubectl apply -f infra/localstack/deployment.yaml > /dev/null
kubectl apply -f infra/localstack/service.yaml > /dev/null

kubectl wait --namespace localstack \
  --for=condition=ready pod \
  --selector=app=localstack \
  --timeout=120s > /dev/null
ok "LocalStack ready"

# ── Step 7: LocalStack Bootstrap ──────────────────────────────
echo ""
echo "▶ Step 7: Running LocalStack bootstrap..."

# Apply configmap (script source) then run bootstrap job with real passwords
JWT_SECRET=$(openssl rand -hex 32 2>/dev/null || od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
kubectl apply -f infra/localstack/bootstrap-configmap.yaml > /dev/null
kubectl delete job localstack-bootstrap -n localstack --ignore-not-found > /dev/null

sed -e "s/REDIS_PWD_PLACEHOLDER/$REDIS_PASSWORD/g" \
    -e "s/POSTGRES_PWD_PLACEHOLDER/$POSTGRES_PASSWORD/g" \
    -e "s/JWT_SECRET_PLACEHOLDER/$JWT_SECRET/g" \
    infra/localstack/bootstrap-job.yaml | kubectl apply -f - > /dev/null

kubectl wait --namespace localstack \
  --for=condition=complete job/localstack-bootstrap \
  --timeout=120s > /dev/null
ok "Secrets, buckets and queues created"

# ── Step 8: Build Docker Images ───────────────────────────────
echo ""
echo "▶ Step 8: Building Docker images..."

cd $PROJECT_ROOT/services/auth-service
docker build -t convertx/auth-service:latest . -q > /dev/null
ok "auth-service built"

cd $PROJECT_ROOT/services/golang-conversion-service
docker build -t convertx/conversion-service:latest . -q > /dev/null
ok "conversion-service built"

cd $PROJECT_ROOT

# ── Step 9: Deploy Auth Service ───────────────────────────────
echo ""
echo "▶ Step 9: Deploying Auth Service..."
kubectl apply -f services/auth-service/k8s/configmap.yaml > /dev/null
kubectl apply -f services/auth-service/k8s/deployment.yaml > /dev/null
kubectl apply -f services/auth-service/k8s/service.yaml > /dev/null
kubectl apply -f services/auth-service/k8s/httproute.yaml > /dev/null

kubectl wait --namespace convertx \
  --for=condition=ready pod \
  --selector=app=auth-service \
  --timeout=120s > /dev/null
ok "Auth Service ready"

# ── Step 10: Deploy Conversion Service ────────────────────────
echo ""
echo "▶ Step 10: Deploying Conversion Service..."
kubectl apply -f services/golang-conversion-service/k8s/configmap.yaml > /dev/null
kubectl apply -f services/golang-conversion-service/k8s/deployment.yaml > /dev/null
kubectl apply -f services/golang-conversion-service/k8s/service.yaml > /dev/null
kubectl apply -f services/golang-conversion-service/k8s/httproute.yaml > /dev/null

kubectl wait --namespace convertx \
  --for=condition=ready pod \
  --selector=app=conversion-service \
  --timeout=120s > /dev/null
ok "Conversion Service ready"

# ── Step 11: Kong Plugins ──────────────────────────────────────
echo ""
echo "▶ Step 11: Applying Kong plugins..."

# Substitute Redis password into rate limiting plugins
sed "s/yourpassword/$REDIS_PASSWORD/g" \
  infra/kong/plugins/rate-limiting-plugin.yaml | kubectl apply -f - > /dev/null
sed "s/yourpassword/$REDIS_PASSWORD/g" \
  infra/kong/plugins/rate-limiting-registered-plugin.yaml | kubectl apply -f - > /dev/null

# Apply remaining plugins
kubectl apply -f infra/kong/plugins/cors-plugin.yaml > /dev/null
kubectl apply -f infra/kong/plugins/request-size-plugin.yaml > /dev/null
kubectl apply -f infra/kong/plugins/response-headers-plugin.yaml > /dev/null
kubectl apply -f infra/kong/plugins/request-logging-plugin.yaml > /dev/null
kubectl apply -f infra/kong/plugins/request-id-plugin.yaml > /dev/null

# Apply plugin bindings
kubectl apply -f infra/kong/plugins/bindings/auth-route-bindings.yaml > /dev/null
kubectl apply -f infra/kong/plugins/bindings/conversion-route-bindings.yaml > /dev/null
ok "Kong plugins applied"

# ── Step 12: Port Forward ──────────────────────────────────────
echo ""
echo "▶ Step 12: Starting port forward..."
pkill -f "port-forward" 2>/dev/null || true
sleep 2

KONG_SVC=$(kubectl get svc -n kong \
  --no-headers \
  | grep "dataplane-ingress" \
  | awk '{print $1}')

if [ -z "$KONG_SVC" ]; then
  err "Could not find Kong dataplane service. Run: kubectl get svc -n kong"
fi

kubectl port-forward svc/$KONG_SVC 8080:80 -n kong > /dev/null 2>&1 &
sleep 3
ok "Port forward active on localhost:8080"

# ── Step 13: Health Checks ─────────────────────────────────────
echo ""
echo "▶ Step 13: Running health checks..."

AUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  http://localhost:8080/api/v1/auth/health)
CONV_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  http://localhost:8080/api/v1/convert/health)

if [ "$AUTH_STATUS" = "200" ]; then
  ok "Auth Service:       $AUTH_STATUS"
else
  echo -e "  ${RED}✗${NC} Auth Service:       $AUTH_STATUS"
fi

if [ "$CONV_STATUS" = "200" ]; then
  ok "Conversion Service: $CONV_STATUS"
else
  echo -e "  ${RED}✗${NC} Conversion Service: $CONV_STATUS"
fi

# ── Done ───────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         Setup Complete                   ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Gateway:     http://localhost:8080"
echo "  Auth API:    http://localhost:8080/api/v1/auth"
echo "  Convert API: http://localhost:8080/api/v1/convert"
echo "  Tools API:   http://localhost:8080/api/v1/tools"
echo ""
echo "  Pods:"
kubectl get pods -n convertx
echo ""
kubectl get pods -n kong | grep -v "operator\|konnect"
echo ""
kubectl get pods -n localstack
echo ""
echo "  To stop port forward:  pkill -f port-forward"
echo "  To view auth logs:     kubectl logs -n convertx -l app=auth-service -f"
echo "  To view convert logs:  kubectl logs -n convertx -l app=conversion-service -f"
echo "  To teardown:           bash teardown.sh"
echo ""