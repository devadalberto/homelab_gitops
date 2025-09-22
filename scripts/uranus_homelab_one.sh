#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
else
  FALLBACK_LIB="${SCRIPT_DIR}/lib/common_fallback.sh"
  if [[ -f "${FALLBACK_LIB}" ]]; then
    # shellcheck source=scripts/lib/common_fallback.sh
    source "${FALLBACK_LIB}"
  else
    echo "Unable to locate scripts/lib/common.sh or fallback helpers" >&2
    exit 70
  fi
fi

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78

ASSUME_YES=false
ENV_FILE_OVERRIDE=""
ENV_FILE_PATH=""
DRY_RUN=false
CONTEXT_ONLY=false

usage() {
  cat <<'USAGE'
Usage: uranus_homelab_one.sh [OPTIONS]

Install core Uranus homelab addons (MetalLB, cert-manager, Traefik) into the
Minikube cluster defined in the environment file.

Options:
  --env-file PATH         Load configuration overrides from PATH.
  --assume-yes            Automatically confirm prompts when possible.
  --dry-run               Log mutating actions without executing them.
  --context-preflight     Validate cluster context and exit without changes.
  --verbose               Increase logging verbosity to debug.
  -h, --help              Show this help message.

Exit codes:
  0   Success.
  64  Usage error (invalid CLI arguments).
  69  Missing required dependencies.
  70  Runtime failure while configuring addons.
  78  Configuration error (missing environment variables).
USAGE
}

format_command() {
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -z ${formatted} ]]; then
      formatted=$(printf '%q' "$arg")
    else
      formatted+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s' "$formatted"
}

run_cmd() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "$@")"
    return 0
  fi
  log_debug "Executing: $(format_command "$@")"
  "$@"
}

kubectl_apply_manifest() {
  local manifest=$1
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl apply -f - <<'EOF'"
    printf '%s\n' "${manifest}"
    log_info "[DRY-RUN] EOF"
    return 0
  fi
  need kubectl || return $?
  printf '%s\n' "${manifest}" | kubectl apply -f -
}

ensure_namespace_safe() {
  local namespace=$1
  if [[ ${DRY_RUN} == true ]]; then
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_debug "Namespace ${namespace} already exists"
    else
      log_info "[DRY-RUN] kubectl create namespace ${namespace}"
    fi
    return 0
  fi
  ensure_namespace "${namespace}"
}

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    log_info "Loading environment overrides from ${ENV_FILE_OVERRIDE}"
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    ENV_FILE_PATH="${ENV_FILE_OVERRIDE}"
    load_env "${ENV_FILE_OVERRIDE}" || die ${EX_CONFIG} "Failed to load ${ENV_FILE_OVERRIDE}"
    return
  fi

  local candidates=(
    "${REPO_ROOT}/.env"
    "${SCRIPT_DIR}/.env"
    "/opt/homelab/.env"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    log_debug "Checking for environment file at ${candidate}"
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      ENV_FILE_PATH="${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  ENV_FILE_PATH=""
  log_debug "No environment file present in default search locations"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage
        die ${EX_USAGE} "--env-file requires a path argument"
      fi
      ENV_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --assume-yes)
      ASSUME_YES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --context-preflight)
      CONTEXT_ONLY=true
      shift
      ;;
    --verbose)
      log_set_level debug
      shift
      ;;
    -h | --help)
      usage
      exit ${EX_OK}
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        usage
        die ${EX_USAGE} "Unexpected positional arguments: $*"
      fi
      ;;
    -*)
      usage
      die ${EX_USAGE} "Unknown option: $1"
      ;;
    *)
      usage
      die ${EX_USAGE} "Positional arguments are not supported"
      ;;
    esac
  done
}

require_env_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die ${EX_CONFIG} "Missing required variables: ${missing[*]}"
  fi
}

ensure_context() {
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"
  local desired=${LABZ_MINIKUBE_PROFILE}
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ ${current} != "${desired}" ]]; then
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] kubectl config use-context ${desired}"
    else
      run_cmd kubectl config use-context "${desired}"
    fi
  else
    log_info "kubectl context already set to ${desired}"
  fi
}

ensure_helm_repo_safe() {
  local name=$1
  local url=$2
  need helm || die ${EX_UNAVAILABLE} "helm is required"
  if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${name}"; then
    log_debug "Helm repository ${name} already present"
  else
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] helm repo add ${name} ${url}"
    else
      run_cmd helm repo add "${name}" "${url}"
    fi
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] helm repo update ${name}"
  else
    run_cmd helm repo update "${name}"
  fi
}

install_metallb() {
  ensure_namespace_safe metallb-system
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl create secret metallb-memberlist"
  else
    if ! kubectl -n metallb-system get secret metallb-memberlist >/dev/null 2>&1; then
      run_cmd kubectl create secret generic -n metallb-system metallb-memberlist \
        --from-literal=secretkey="$(openssl rand -base64 128)"
    fi
  fi

  local version=${METALLB_HELM_VERSION}
  local install_cmd=(
    helm upgrade --install metallb metallb/metallb
    --namespace metallb-system
    --create-namespace
    --version "${version}"
    --wait
    --timeout 10m0s
  )
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${install_cmd[@]}")"
  else
    if ! "${install_cmd[@]}"; then
      log_error "MetalLB installation failed"
      kubectl -n metallb-system get pods || true
      kubectl -n metallb-system describe daemonset metallb-speaker || true
      die ${EX_SOFTWARE} "Failed to install MetalLB"
    fi
  fi
  if [[ ${DRY_RUN} == false ]]; then
    kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=180s
    kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=180s
  fi
}

apply_metallb_pool() {
  local pool_manifest advertisement
  if ! pool_manifest=$(metallb_render_ip_pool_manifest "homelab-pool" "metallb-system"); then
    die ${EX_CONFIG} "Failed to render MetalLB IPAddressPool"
  fi
  advertisement=$(
    cat <<'EOM'
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
EOM
  )
  kubectl_apply_manifest "${pool_manifest}"
  kubectl_apply_manifest "${advertisement}"
}

install_cert_manager() {
  ensure_namespace_safe cert-manager
  local version=${CERT_MANAGER_HELM_VERSION}
  local install_cmd=(
    helm upgrade --install cert-manager jetstack/cert-manager
    --namespace cert-manager
    --create-namespace
    --version "${version}"
    --set crds.enabled=true
    --wait
    --timeout 10m0s
  )
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${install_cmd[@]}")"
  else
    "${install_cmd[@]}"
  fi

  local issuer
  issuer=$(
    cat <<'EOM'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: labz-selfsigned
spec:
  selfSigned: {}
EOM
  )
  kubectl_apply_manifest "${issuer}"
}

install_traefik() {
  ensure_namespace_safe traefik
  local version=${TRAEFIK_HELM_VERSION}
  local install_cmd=(
    helm upgrade --install traefik traefik/traefik
    --namespace traefik
    --create-namespace
    --version "${version}"
    --set service.type=LoadBalancer
    --set service.spec.loadBalancerIP="${TRAEFIK_LOCAL_IP}"
    --set ports.web.redirectTo.port=websecure
    --set ports.websecure.tls.enabled=true
    --set ingressRoute.dashboard.enabled=true
    --set ingressRoute.dashboard.tls.secretName=labz-traefik-tls
    --wait
    --timeout 10m0s
  )
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${install_cmd[@]}")"
  else
    "${install_cmd[@]}"
  fi
}

create_support_namespaces() {
  ensure_namespace_safe data
  ensure_namespace_safe apps
}

main() {
  parse_args "$@"
  load_environment

  require_env_vars LABZ_MINIKUBE_PROFILE LABZ_METALLB_RANGE METALLB_POOL_START METALLB_POOL_END
  : "${METALLB_HELM_VERSION:=0.14.7}"
  : "${CERT_MANAGER_HELM_VERSION:=1.16.3}"
  : "${TRAEFIK_HELM_VERSION:=27.0.2}"
  : "${TRAEFIK_LOCAL_IP:=${METALLB_POOL_START}}"

  if [[ ${CONTEXT_ONLY} == true ]]; then
    ensure_context
    log_info "Context preflight complete"
    return
  fi

  need kubectl helm openssl || die ${EX_UNAVAILABLE} "kubectl, helm, and openssl are required"

  ensure_context
  ensure_helm_repo_safe metallb https://metallb.github.io/metallb
  ensure_helm_repo_safe jetstack https://charts.jetstack.io
  ensure_helm_repo_safe traefik https://traefik.github.io/charts

  install_metallb
  apply_metallb_pool
  install_cert_manager
  install_traefik
  create_support_namespaces

  log_info "Core addons installed. Proceed with application deployment."
}

main "$@"
