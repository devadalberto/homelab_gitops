#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
else
  ENV_FILE="$ROOT/.env.example"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

KUBERNETES_VERSION="${KUBERNETES_VERSION:-${LABZ_KUBERNETES_VERSION:-v1.31.3}}"
LABZ_MINIKUBE_PROFILE="${LABZ_MINIKUBE_PROFILE:-uranus}"
METALLB_CHART_VERSION="${METALLB_CHART_VERSION:-${METALLB_HELM_VERSION:-0.14.7}}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-${TRAEFIK_HELM_VERSION:-27.0.2}}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-${CERT_MANAGER_HELM_VERSION:-1.16.3}}"

if ! minikube status --profile "${LABZ_MINIKUBE_PROFILE}" >/dev/null 2>&1; then
  minikube start --profile="${LABZ_MINIKUBE_PROFILE}" --driver=docker --container-runtime=containerd --cpus=4 --memory=8192 --kubernetes-version="${KUBERNETES_VERSION}"
fi
kubectl config use-context "${LABZ_MINIKUBE_PROFILE}" >/dev/null 2>&1 || true

minikube -p "${LABZ_MINIKUBE_PROFILE}" addons enable metrics-server >/dev/null 2>&1 || true
minikube -p "${LABZ_MINIKUBE_PROFILE}" addons enable storage-provisioner >/dev/null 2>&1 || true

kubectl create ns metallb-system --dry-run=client -o yaml | kubectl apply -f -
pool_manifest=$("$ROOT/scripts/render_metallb_pool_manifest.sh" --env-file "$ENV_FILE" --output - --stdout)
advertisement=$(cat <<'YAML'
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
YAML
)
printf '%s\n---\n%s\n' "$pool_manifest" "$advertisement" | kubectl apply -f -

kubectl create ns traefik --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install traefik traefik/traefik --version "${TRAEFIK_CHART_VERSION}" -n traefik -f "$ROOT/k8s/traefik/values.yaml" --wait

kubectl create ns cert-manager --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install cert-manager jetstack/cert-manager --version "${CERT_MANAGER_CHART_VERSION}" -n cert-manager --set crds.enabled=true --wait
kubectl apply -f "$ROOT/k8s/cert-manager/cm-internal-ca.yaml"
