# Kong Gateway Operator — Install Instructions

## Prerequisites
- Helm 3.x installed
- kubectl configured and cluster running
- MetalLB installed (see infra/metallb/)

## Install Steps

### 1. Add Kong Helm repo
helm repo add kong https://charts.konghq.com
helm repo update

### 2. Install Kong Gateway Operator
helm install kong-operator kong/gateway-operator \
  -n kong \
  --create-namespace

### 3. Install Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

### 4. Deploy Gateway
kubectl apply -f infra/kong/gateway/gateway.yaml

### 5. Verify
kubectl get pods -n kong
kubectl get gateway -n kong

## Expected Output
NAME               CLASS   ADDRESS         PROGRAMMED
convertx-gateway   kong    192.168.1.200   True