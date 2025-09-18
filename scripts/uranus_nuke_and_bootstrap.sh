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
readonly EX_TEMPFAIL=75
readonly EX_CONFIG=78

ASSUME_YES=false
DELETE_PREVIOUS=false
DRY_RUN=false
CONTEXT_ONLY=false
ENV_FILE_OVERRIDE=""
ENV_FILE_PATH=""

REGISTRY_LOCAL_PORT=5000
REGISTRY_SERVICE_PORT=80

declare -a BACKGROUND_PIDS=()

cleanup_background_jobs() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]}"; do
    if [[ -n ${pid} ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      log_debug "Stopping background job ${pid}"
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done
}

register_background_job() {
  BACKGROUND_PIDS+=("$1")
}

wait_for_background_jobs() {
  local pid
  if [[ ${#BACKGROUND_PIDS[@]} -eq 0 ]]; then
    return
  fi
  log_info "Waiting for background jobs to finish (press Ctrl+C to exit)"
  for pid in "${BACKGROUND_PIDS[@]}"; do
    if [[ -n ${pid} ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      wait "${pid}" || true
    fi
  done
}

trap cleanup_background_jobs EXIT INT TERM

usage() {
  cat <<'USAGE'
Usage: uranus_nuke_and_bootstrap.sh [OPTIONS]

Recreate the Uranus homelab Minikube environment using configuration from an
environment file.

Options:
  --env-file PATH               Load configuration overrides from PATH.
  --assume-yes                  Automatically confirm prompts.
  --delete-previous-environment Remove any existing Minikube profile before starting.
  --dry-run                     Log mutating actions without executing them.
  --context-preflight           Validate environment and exit without changes.
  --verbose                     Increase logging verbosity to debug.
  -h, --help                    Show this help message.

Exit codes:
  0   Success.
  64  Usage error (invalid CLI arguments).
  69  Missing required dependencies.
  70  Runtime failure while bootstrapping Minikube.
  75  Temporary failure (e.g., registry addon not ready).
  78  Configuration error (missing environment file or variables).
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
      --delete-previous-environment)
        DELETE_PREVIOUS=true
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
      -h|--help)
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

confirm_action() {
  local prompt=$1
  if [[ ${ASSUME_YES} == true ]]; then
    log_info "--assume-yes supplied; automatically confirming: ${prompt}"
    return 0
  fi
  local reply
  read -r -p "${prompt} [y/N]: " reply
  if [[ ${reply} =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    return 0
  fi
  return 1
}

ensure_dependencies() {
  need minikube kubectl helm || die ${EX_UNAVAILABLE} "minikube, kubectl, and helm are required"
}

enable_mount_directory() {
  local path=$1
  if [[ -z ${path} ]]; then
    return
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command mkdir -p "${path}")"
    return
  fi
  run_cmd mkdir -p "${path}"
}

ensure_mount_directories() {
  log_info "Ensuring host mount directories exist"
  enable_mount_directory "${LABZ_MOUNT_BACKUPS}"
  enable_mount_directory "${LABZ_MOUNT_MEDIA}"
  enable_mount_directory "${LABZ_MOUNT_NEXTCLOUD}"
}

profile_is_running() {
  local profile=$1
  if minikube status -p "${profile}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

delete_previous_profile() {
  if [[ ${DELETE_PREVIOUS} != true ]]; then
    return
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command minikube delete -p "${LABZ_MINIKUBE_PROFILE}")"
    return
  fi
  if ! profile_is_running "${LABZ_MINIKUBE_PROFILE}"; then
    log_info "Minikube profile ${LABZ_MINIKUBE_PROFILE} not present; skipping deletion"
    return
  fi
  if confirm_action "Delete existing Minikube profile ${LABZ_MINIKUBE_PROFILE}?"; then
    if ! run_cmd minikube delete -p "${LABZ_MINIKUBE_PROFILE}"; then
      log_warn "Failed to delete Minikube profile ${LABZ_MINIKUBE_PROFILE}; continuing"
    fi
  else
    log_info "Skipping deletion of existing profile"
  fi
}

build_minikube_args() {
  MINIKUBE_ARGS=(
    start
    --profile "${LABZ_MINIKUBE_PROFILE}"
    --driver "${LABZ_MINIKUBE_DRIVER}"
    --cpus "${LABZ_MINIKUBE_CPUS}"
    --memory "${LABZ_MINIKUBE_MEMORY}"
    --disk-size "${LABZ_MINIKUBE_DISK}"
  )
  if [[ -n ${LABZ_MINIKUBE_EXTRA_ARGS} ]]; then
    # shellcheck disable=SC2206
    local extra_args
    read -r -a extra_args <<<"${LABZ_MINIKUBE_EXTRA_ARGS}"
    MINIKUBE_ARGS+=("${extra_args[@]}")
  fi
}

start_minikube() {
  log_info "Starting Minikube profile ${LABZ_MINIKUBE_PROFILE}"
  build_minikube_args
  if [[ ${SKIP_MINIKUBE_START} == true ]]; then
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would verify Minikube status for profile ${LABZ_MINIKUBE_PROFILE}"
      log_info "[DRY-RUN] Skipping Minikube start because SKIP_MINIKUBE_START=true"
      return
    fi
    if profile_is_running "${LABZ_MINIKUBE_PROFILE}"; then
      log_info "Skipping Minikube start (SKIP_MINIKUBE_START=true and profile running)"
      return
    fi
    log_warn "Minikube profile not running; starting despite SKIP_MINIKUBE_START=true"
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] minikube $(format_command "${MINIKUBE_ARGS[@]}")"
    return
  fi
  if ! retry 3 10 minikube "${MINIKUBE_ARGS[@]}"; then
    log_error "Minikube failed to start"
    minikube logs -p "${LABZ_MINIKUBE_PROFILE}" || true
    die ${EX_SOFTWARE} "Unable to start Minikube profile ${LABZ_MINIKUBE_PROFILE}"
  fi
}

switch_kubectl_context() {
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"
  local desired=${LABZ_MINIKUBE_PROFILE}
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ ${current} == "${desired}" ]]; then
    log_info "kubectl context already set to ${desired}"
    return
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command kubectl config use-context "${desired}")"
    return
  fi
  if ! run_cmd kubectl config use-context "${desired}"; then
    die ${EX_SOFTWARE} "Failed to switch kubectl context to ${desired}"
  fi
}

context_preflight() {
  log_info "Running context preflight checks"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "Dry-run mode: not executing Minikube context checks"
    return
  fi
  if profile_is_running "${LABZ_MINIKUBE_PROFILE}"; then
    log_info "Minikube profile ${LABZ_MINIKUBE_PROFILE} is available"
  else
    log_warn "Minikube profile ${LABZ_MINIKUBE_PROFILE} not currently running"
  fi
  log_info "Context preflight complete"
}

enable_registry_addon() {
  log_info "Enabling Minikube registry addon"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command minikube -p "${LABZ_MINIKUBE_PROFILE}" addons enable registry)"
    return
  fi
  if ! retry 3 5 minikube -p "${LABZ_MINIKUBE_PROFILE}" addons enable registry; then
    die ${EX_SOFTWARE} "Failed to enable Minikube registry addon"
  fi
}

wait_for_registry() {
  log_info "Waiting for registry deployment to become ready"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command kubectl -n kube-system rollout status deployment/registry --timeout=120s)"
    return
  fi
  if ! retry 3 10 kubectl -n kube-system rollout status deployment/registry --timeout=120s; then
    log_error "Registry deployment failed to become ready"
    kubectl -n kube-system get pods || true
    kubectl -n kube-system describe deployment registry || true
    kubectl -n kube-system logs deployment/registry --tail=100 || true
    die ${EX_TEMPFAIL} "Registry deployment is not ready"
  fi
}

start_registry_port_forward() {
  local cmd=(
    kubectl -n kube-system port-forward --address 0.0.0.0 svc/registry \
      "${REGISTRY_LOCAL_PORT}:${REGISTRY_SERVICE_PORT}"
  )
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${cmd[@]}")"
    return
  fi
  "${cmd[@]}" >/dev/null 2>&1 &
  local pf_pid=$!
  sleep 2
  if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
    die ${EX_TEMPFAIL} "Registry port-forward failed to start"
  fi
  register_background_job "${pf_pid}"
  log_info "Registry port-forward active at localhost:${REGISTRY_LOCAL_PORT} (PID ${pf_pid})"
}

print_summary() {
  local registry_url="localhost:${REGISTRY_LOCAL_PORT}"
  log_info "Bootstrap complete. Local registry is reachable while this script is running."
  log_info "To push images:   docker tag IMAGE ${registry_url}/IMAGE && docker push ${registry_url}/IMAGE"
  log_info "To pull in cluster: use image reference ${registry_url}/IMAGE"
  log_info "Press Ctrl+C when you are finished to stop the registry port-forward."
}

main() {
  parse_args "$@"
  load_environment

  require_env_vars \
    LABZ_MINIKUBE_PROFILE LABZ_MINIKUBE_DRIVER LABZ_MINIKUBE_CPUS \
    LABZ_MINIKUBE_MEMORY LABZ_MINIKUBE_DISK LABZ_MOUNT_BACKUPS \
    LABZ_MOUNT_MEDIA LABZ_MOUNT_NEXTCLOUD LABZ_METALLB_RANGE \
    METALLB_POOL_START METALLB_POOL_END

  : "${LABZ_MINIKUBE_EXTRA_ARGS:=}"
  : "${SKIP_MINIKUBE_START:=false}"
  : "${REGISTRY_LOCAL_PORT:=5000}"
  : "${REGISTRY_SERVICE_PORT:=80}"

  ensure_dependencies

  if [[ ${CONTEXT_ONLY} == true ]]; then
    context_preflight
    return
  fi

  ensure_mount_directories
  delete_previous_profile
  start_minikube
  switch_kubectl_context
  enable_registry_addon
  wait_for_registry
  start_registry_port_forward

  if [[ ${DRY_RUN} == true ]]; then
    log_info "Dry-run complete. No actions were executed."
    return
  fi

  print_summary
  wait_for_background_jobs
}

main "$@"
