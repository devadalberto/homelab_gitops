#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || source "$ROOT/.env.example"

if ! minikube status --profile uranus >/dev/null 2>&1; then
  minikube start --profile=uranus --driver=docker --container-runtime=containerd --cpus=4 --memory=8192 --kubernetes-version=stable
fi
kubectl config use-context uranus >/dev/null 2>&1 || true

minikube -p uranus addons enable metrics-server >/dev/null 2>&1 || true
minikube -p uranus addons enable storage-provisioner >/dev/null 2>&1 || true

kubectl create ns metallb-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n metallb-system -f - <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: pool1}
spec:
  addresses: ["${METALLB_POOL_START}-${METALLB_POOL_END}"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: l2adv1}
spec: {}
YAML

kubectl create ns traefik --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install traefik traefik/traefik -n traefik -f "$ROOT/k8s/traefik/values.yaml" --wait

kubectl create ns cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --set installCRDs=true --wait
kubectl apply -f "$ROOT/k8s/cert-manager/cm-internal-ca.yaml"
