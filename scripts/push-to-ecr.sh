#!/bin/bash
# =============================================================
# ConvertX — Push service images to LocalStack ECR
# Usage: bash scripts/push-to-ecr.sh
#
# PREREQUISITE (manual, one time):
#   LocalStack's ECR registry is served over plain HTTP, so Docker and
#   Kubernetes must both be told to trust it as an insecure registry.
#   Docker Desktop → Settings → Docker Engine, add:
#
#     { "insecure-registries": ["localhost:4510",
#                               "localstack.localstack.svc.cluster.local:4510"] }
#
#   then Apply & Restart. Without this, `docker push` fails with
#   "http: server gave HTTP response to HTTPS client".
#
# This script is NOT called by setup.sh. setup.sh builds images locally and
# relies on imagePullPolicy: IfNotPresent, which works without the above.
# =============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; exit 1; }
info() { echo -e "  ${YELLOW}▶${NC} $1"; }

command -v docker >/dev/null || err "docker not found"

LOCALSTACK_POD=$(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$LOCALSTACK_POD" ] && err "LocalStack pod not found. Run setup.sh first."

echo ""
echo "▶ Resolving ECR registry..."

# repositoryUri looks like <host>:<port>/convertx/auth-service
REPO_URI=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
  awslocal ecr describe-repositories \
    --repository-names convertx/auth-service \
    --query 'repositories[0].repositoryUri' --output text 2>/dev/null | tr -d '\r\n')

[ -z "$REPO_URI" ] && err "Could not resolve ECR repository. Has bootstrap run?"

REGISTRY="${REPO_URI%%/*}"          # host:port
ECR_PORT="${REGISTRY##*:}"
ok "Registry: $REGISTRY"

# The registry host resolves inside the cluster but not from here, so tunnel it.
info "Port-forwarding ECR ($ECR_PORT) to localhost..."
pkill -f "port-forward.*$ECR_PORT:$ECR_PORT" 2>/dev/null || true
kubectl port-forward -n localstack "svc/localstack" "$ECR_PORT:$ECR_PORT" \
  > /dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3
ok "Tunnel active (pid $PF_PID)"

# LocalStack ECR accepts any credentials.
echo "test" | docker login --username AWS --password-stdin "localhost:$ECR_PORT" \
  > /dev/null 2>&1 || info "docker login returned non-zero (usually harmless)"

echo ""
echo "▶ Pushing images..."

push() {
  local LOCAL_TAG=$1 REPO_NAME=$2
  local TARGET="localhost:$ECR_PORT/$REPO_NAME:latest"
  docker tag "$LOCAL_TAG" "$TARGET"
  if docker push "$TARGET" > /dev/null 2>&1; then
    ok "$REPO_NAME pushed"
  else
    err "push failed for $REPO_NAME — is the insecure-registry setting applied?
     See the prerequisite block at the top of this script."
  fi
}

push convertx/auth-service:latest       convertx/auth-service
push convertx/conversion-service:latest convertx/conversion-service

echo ""
echo "  Images are in ECR. To make Kubernetes pull them instead of using the"
echo "  local daemon cache, set the image in each deployment to:"
echo ""
echo "    localstack.localstack.svc.cluster.local:$ECR_PORT/convertx/auth-service:latest"
echo "    localstack.localstack.svc.cluster.local:$ECR_PORT/convertx/conversion-service:latest"
echo ""
echo "  and change imagePullPolicy to Always. Docker Desktop's Kubernetes node"
echo "  must also trust that host as an insecure registry (same setting)."
echo ""
