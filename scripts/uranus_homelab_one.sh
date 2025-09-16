#!/usr/bin/env bash
set -Eeuo pipefail

ASSUME_YES=false
ENV_FILE="./.env"

usage() {
  cat <<'USAGE'
Usage: uranus_homelab_one.sh [--env-file PATH] [--assume-yes]

Installs core addons (MetalLB, cert-manager, Traefik) into the Uranus homelab cluster.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%F %T')" "$*"
}

require_command() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "Required command not found: ${cmd}" >&2
      exit 1
    fi
  done
}

load_env_file() {
  local file=$1
  if [[ ! -f "${file}" ]]; then
    echo "Environment file not found: ${file}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a
  source "${file}"
  set +a
}

require_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    echo "Missing required variables: ${missing[*]}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --assume-yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

load_env_file "${ENV_FILE}"
require_vars LABZ_MINIKUBE_PROFILE LABZ_METALLB_RANGE METALLB_POOL_START METALLB_POOL_END

require_command kubectl helm minikube

log "Switching kubectl context to ${LABZ_MINIKUBE_PROFILE}"
kubectl config use-context "${LABZ_MINIKUBE_PROFILE}" >/dev/null

log "Adding/refreshing Helm repos"
helm repo add metallb https://metallb.github.io/metallb >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Installing MetalLB"
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait

if [[ -z "${METALLB_POOL_START}" || -z "${METALLB_POOL_END}" ]]; then
  if [[ "${LABZ_METALLB_RANGE}" == *-* ]]; then
    METALLB_POOL_START=${LABZ_METALLB_RANGE%%-*}
    METALLB_POOL_END=${LABZ_METALLB_RANGE##*-}
  else
    METALLB_POOL_START=${LABZ_METALLB_RANGE}
    METALLB_POOL_END=${LABZ_METALLB_RANGE}
  fi
fi

cat <<EOF_APPLY | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: labz-pool
  namespace: metallb-system
spec:
  addresses:
    - ${LABZ_METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: labz-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - labz-pool
EOF_APPLY

log "Installing cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true \
  --wait

cat <<'EOF_ISSUER' | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: labz-selfsigned
spec:
  selfSigned: {}
EOF_ISSUER

log "Installing Traefik"
helm upgrade --install traefik traefik/traefik \
  --namespace traefik \
  --create-namespace \
  --set service.type=LoadBalancer \
  --set service.spec.loadBalancerIP="${METALLB_POOL_START}" \
  --set ports.web.redirectTo=websecure \
  --set ports.websecure.tls.enabled=true \
  --set ingressRoute.dashboard.enabled=true \
  --set ingressRoute.dashboard.tls.secretName=labz-traefik-tls \
  --wait

log "Creating namespaces for data and apps"
kubectl create namespace data --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace apps --dry-run=client -o yaml | kubectl apply -f -

log "Core addons installed. Proceed with uranus_homelab_apps.sh for stateful workloads."
