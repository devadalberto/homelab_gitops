#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

ENV_FILE_OVERRIDE=""
TRAEFIK_WAIT_ATTEMPTS=60
TRAEFIK_WAIT_INTERVAL=5

usage() {
  cat <<'USAGE'
Usage: k8s-bootstrap.sh [OPTIONS]

Bootstrap the local Minikube cluster with MetalLB, cert-manager, and Traefik.

Options:
  -e, --env-file PATH   Load environment variables from PATH.
      --env-file=PATH   Alternate form of --env-file PATH.
      --verbose         Enable debug logging.
  -h, --help            Show this help message and exit.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--env-file)
        if [[ $# -lt 2 ]]; then
          usage >&2
          die "${EX_USAGE:-64}" "--env-file requires a path argument"
        fi
        ENV_FILE_OVERRIDE="$2"
        shift 2
        ;;
      --env-file=*)
        ENV_FILE_OVERRIDE="${1#*=}"
        shift
        ;;
      --verbose)
        log_set_level debug
        shift
        ;;
      -h|--help)
        usage
        exit "${EX_OK:-0}"
        ;;
      *)
        usage >&2
        die "${EX_USAGE:-64}" "Unknown argument: $1"
        ;;
    esac
  done
}

load_environment() {
  local -a args=()
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die "${EX_CONFIG:-78}" "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    args+=(--env-file "${ENV_FILE_OVERRIDE}")
  fi

  if ! load_env "${args[@]}"; then
    if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
      die "${EX_CONFIG:-78}" "Failed to load environment file: ${ENV_FILE_OVERRIDE}"
    fi
    warn "No environment file located; continuing with current shell values."
    return 1
  fi

  return 0
}

run_cmd() {
  log_debug "Executing: $(format_command "$@")"
  "$@"
}

kubectl_apply_manifest() {
  local manifest=$1
  local description=${2:-}
  need kubectl || return $?
  if [[ -n ${description} ]]; then
    log_info "${description}"
  fi
  printf '%s\n' "${manifest}" | kubectl apply -f -
}

require_env_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z ${!var:-} ]]; then
      missing+=("${var}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "${EX_CONFIG:-78}" "Missing required variables: ${missing[*]}"
  fi
}

derive_metallb_range() {
  if [[ ( -z ${METALLB_POOL_START:-} || -z ${METALLB_POOL_END:-} ) && -n ${LABZ_METALLB_RANGE:-} ]]; then
    local range=${LABZ_METALLB_RANGE//[[:space:]]/}
    local start_part=${range%%-*}
    local end_part=${range##*-}
    if [[ -z ${METALLB_POOL_START:-} && -n ${start_part} ]]; then
      METALLB_POOL_START=${start_part}
    fi
    if [[ -z ${METALLB_POOL_END:-} && -n ${end_part} ]]; then
      METALLB_POOL_END=${end_part}
    fi
  fi

  if [[ -z ${LABZ_METALLB_RANGE:-} && -n ${METALLB_POOL_START:-} && -n ${METALLB_POOL_END:-} ]]; then
    LABZ_METALLB_RANGE="${METALLB_POOL_START}-${METALLB_POOL_END}"
  fi
}

ensure_minikube() {
  local profile=${LABZ_MINIKUBE_PROFILE}
  local driver=${LABZ_MINIKUBE_DRIVER}
  local cpus=${LABZ_MINIKUBE_CPUS:-}
  local memory=${LABZ_MINIKUBE_MEMORY:-}
  local disk=${LABZ_MINIKUBE_DISK:-}
  local kube_version=${LABZ_KUBERNETES_VERSION:-${KUBERNETES_VERSION:-}}

  log_info "Ensuring Minikube profile ${profile} is running"
  local -a start_cmd=(
    minikube start
    --profile "${profile}"
    --driver "${driver}"
    --addons metrics-server
  )

  [[ -n ${cpus} ]] && start_cmd+=(--cpus "${cpus}")
  [[ -n ${memory} ]] && start_cmd+=(--memory "${memory}")
  [[ -n ${disk} ]] && start_cmd+=(--disk-size "${disk}")
  [[ -n ${kube_version} ]] && start_cmd+=(--kubernetes-version "${kube_version}")

  run_cmd "${start_cmd[@]}"
  run_cmd kubectl config use-context "${profile}"
  log_info "Minikube profile ${profile} is ready"
}

configure_metallb() {
  ensure_helm_repo metallb https://metallb.github.io/metallb
  ensure_namespace metallb-system

  if ! kubectl -n metallb-system get secret metallb-memberlist >/dev/null 2>&1; then
    log_info "Creating MetalLB memberlist secret"
    local secret_value
    secret_value=$(openssl rand -base64 128)
    run_cmd kubectl create secret generic -n metallb-system metallb-memberlist \
      --from-literal=secretkey="${secret_value}"
  else
    log_debug "MetalLB memberlist secret already exists"
  fi

  log_info "Deploying MetalLB ${METALLB_HELM_VERSION}"
  run_cmd helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --create-namespace \
    --version "${METALLB_HELM_VERSION}" \
    --wait \
    --timeout 10m0s

  local pool_manifest advertisement
  if ! pool_manifest=$(metallb_render_ip_pool_manifest "homelab-pool" "metallb-system"); then
    die "${EX_CONFIG:-78}" "Failed to render MetalLB IPAddressPool manifest"
  fi

  read -r -d '' advertisement <<'YAML' || true
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
YAML

  log_info "Applying MetalLB pool ${METALLB_POOL_START}-${METALLB_POOL_END}"
  kubectl_apply_manifest "${pool_manifest}"
  kubectl_apply_manifest "${advertisement}"
}

deploy_cert_manager() {
  ensure_helm_repo jetstack https://charts.jetstack.io
  log_info "Deploying cert-manager ${CERT_MANAGER_HELM_VERSION}"
  run_cmd helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${CERT_MANAGER_HELM_VERSION}" \
    --set crds.enabled=true \
    --wait \
    --timeout 10m0s

  local issuer_manifest
  issuer_manifest=$(<"${REPO_ROOT}/k8s/cert-manager/cm-internal-ca.yaml")
  kubectl_apply_manifest "${issuer_manifest}" "Applying cert-manager internal CA"
}

install_traefik() {
  ensure_helm_repo traefik https://traefik.github.io/charts
  log_info "Deploying Traefik ${TRAEFIK_HELM_VERSION}"
  run_cmd helm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --create-namespace \
    --version "${TRAEFIK_HELM_VERSION}" \
    --values "${REPO_ROOT}/k8s/traefik/values.yaml" \
    --set service.type=LoadBalancer \
    --set service.spec.loadBalancerIP="${TRAEFIK_LOCAL_IP}" \
    --set ingressRoute.dashboard.enabled=true \
    --set ingressRoute.dashboard.tls.secretName=labz-traefik-tls \
    --wait \
    --timeout 10m0s
}

wait_for_traefik_ip() {
  local attempt=1
  local service_namespace=traefik
  local service_name=traefik
  log_info "Waiting for Traefik LoadBalancer IP assignment"
  while (( attempt <= TRAEFIK_WAIT_ATTEMPTS )); do
    local ip
    ip=$(kubectl -n "${service_namespace}" get svc "${service_name}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    local hostname
    hostname=$(kubectl -n "${service_namespace}" get svc "${service_name}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    if [[ -n ${ip} ]]; then
      log_info "Traefik LoadBalancer IP: ${ip}"
      return 0
    fi
    if [[ -n ${hostname} ]]; then
      log_info "Traefik LoadBalancer hostname: ${hostname}"
      return 0
    fi
    log_debug "Traefik service not yet provisioned (attempt ${attempt}/${TRAEFIK_WAIT_ATTEMPTS})"
    sleep "${TRAEFIK_WAIT_INTERVAL}"
    ((attempt++))
  done
  die "${EX_SOFTWARE:-70}" "Timed out waiting for Traefik LoadBalancer IP"
}

main() {
  parse_args "$@"
  load_environment || true
  derive_metallb_range

  : "${LABZ_MINIKUBE_PROFILE:=uranus}"
  : "${LABZ_MINIKUBE_DRIVER:=docker}"
  : "${LABZ_MINIKUBE_CPUS:=4}"
  : "${LABZ_MINIKUBE_MEMORY:=8192}"
  : "${LABZ_MINIKUBE_DISK:=60g}"
  : "${LABZ_KUBERNETES_VERSION:=${KUBERNETES_VERSION:-v1.31.3}}"
  : "${METALLB_HELM_VERSION:=0.14.7}"
  : "${CERT_MANAGER_HELM_VERSION:=1.16.3}"
  : "${TRAEFIK_HELM_VERSION:=27.0.2}"

  require_env_vars METALLB_POOL_START METALLB_POOL_END
  : "${TRAEFIK_LOCAL_IP:=${METALLB_POOL_START}}"

  need minikube kubectl helm openssl || die "${EX_UNAVAILABLE:-69}" "minikube, kubectl, helm, and openssl are required"

  log_info "Starting Kubernetes bootstrap workflow"
  ensure_minikube
  configure_metallb
  deploy_cert_manager
  install_traefik
  wait_for_traefik_ip
  log_info "Kubernetes bootstrap complete"
}

main "$@"
