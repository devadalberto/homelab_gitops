#!/usr/bin/env bash
set -euo pipefail

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

ENV_FILE_OVERRIDE=""
ENV_FILE_PATH=""

CONTEXT_RETRY_ATTEMPTS=${K8S_SMOKETEST_CONTEXT_ATTEMPTS:-30}
CONTEXT_RETRY_DELAY=${K8S_SMOKETEST_CONTEXT_DELAY:-5}
DESIRED_CONTEXT=""

usage() {
  cat <<'USAGE'
Usage: k8s-smoketest.sh [OPTIONS]

Validate Kubernetes cluster readiness for the homelab Minikube profile.

Options:
  --env-file PATH     Load environment configuration from PATH.
  --verbose           Increase logging verbosity to debug.
  -h, --help          Show this help message and exit.
USAGE
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

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    log_info "Loading environment overrides from ${ENV_FILE_OVERRIDE}"
    ENV_FILE_PATH="${ENV_FILE_OVERRIDE}"
    load_env "${ENV_FILE_OVERRIDE}" || die ${EX_CONFIG} "Failed to load ${ENV_FILE_OVERRIDE}"
    return
  fi

  local candidates=(
    "${REPO_ROOT}/.env"
    "${SCRIPT_DIR}/.env"
    "${REPO_ROOT}/.env.example"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      ENV_FILE_PATH="${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done

  log_warn "No environment file found; relying on existing environment variables"
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
      --verbose)
        log_set_level debug
        shift
        ;;
      -h|--help)
        usage
        exit ${EX_OK}
        ;;
      --)
        shift
        break
        ;;
      -* )
        usage
        die ${EX_USAGE} "Unknown option: $1"
        ;;
      * )
        usage
        die ${EX_USAGE} "Positional arguments are not supported"
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    usage
    die ${EX_USAGE} "Positional arguments are not supported"
  fi
}

validate_context_retry_config() {
  if ! [[ ${CONTEXT_RETRY_ATTEMPTS} =~ ^[0-9]+$ ]] || (( CONTEXT_RETRY_ATTEMPTS <= 0 )); then
    die ${EX_USAGE} "K8S_SMOKETEST_CONTEXT_ATTEMPTS must be a positive integer"
  fi
  if ! [[ ${CONTEXT_RETRY_DELAY} =~ ^[0-9]+$ ]] || (( CONTEXT_RETRY_DELAY <= 0 )); then
    die ${EX_USAGE} "K8S_SMOKETEST_CONTEXT_DELAY must be a positive integer"
  fi
}

ensure_kubectl_context() {
  local desired=$1
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"

  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ ${current} == "${desired}" ]]; then
    log_info "kubectl already targeting context ${desired}"
    return 0
  fi

  if [[ -n ${current} ]]; then
    log_info "Switching kubectl context from ${current} to ${desired}"
  else
    log_info "Setting kubectl context to ${desired}"
  fi

  local attempt=1
  while (( attempt <= CONTEXT_RETRY_ATTEMPTS )); do
    if kubectl config use-context "${desired}" >/dev/null 2>&1; then
      log_info "kubectl context set to ${desired}"
      return 0
    fi

    if ! kubectl config get-contexts "${desired}" >/dev/null 2>&1; then
      log_warn "kubectl context ${desired} is not yet available (attempt ${attempt}/${CONTEXT_RETRY_ATTEMPTS}); waiting for Minikube profile ${LABZ_MINIKUBE_PROFILE} to finish provisioning..."
    else
      log_warn "Failed to switch kubectl context to ${desired} (attempt ${attempt}/${CONTEXT_RETRY_ATTEMPTS}); retrying in ${CONTEXT_RETRY_DELAY}s..."
    fi

    sleep "${CONTEXT_RETRY_DELAY}"
    ((attempt++))
  done

  die ${EX_UNAVAILABLE} "Unable to switch kubectl context to ${desired} after ${CONTEXT_RETRY_ATTEMPTS} attempts"
}

wait_for_ready_nodes() {
  log_info "Validating Kubernetes nodes report Ready status"
  if ! retry 12 5 kubectl get nodes >/dev/null 2>&1; then
    die ${EX_UNAVAILABLE} "kubectl get nodes failed after repeated attempts"
  fi

  local ready_count
  ready_count=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {count++} END {print count+0}')
  if [[ -z ${ready_count} || ${ready_count} -eq 0 ]]; then
    die ${EX_SOFTWARE} "No Ready nodes detected in context ${DESIRED_CONTEXT}"
  fi
  log_info "Detected ${ready_count} Ready node(s) in context ${DESIRED_CONTEXT}"
}

main() {
  parse_args "$@"
  validate_context_retry_config
  load_environment

  require_env_vars LABZ_MINIKUBE_PROFILE
  DESIRED_CONTEXT="${LABZ_MINIKUBE_PROFILE}"

  log_info "Using kubectl context ${DESIRED_CONTEXT} derived from LABZ_MINIKUBE_PROFILE"
  ensure_kubectl_context "${DESIRED_CONTEXT}"

  wait_for_ready_nodes

  log_info "Kubernetes smoketest completed successfully."
}

main "$@"
