#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78

ASSUME_YES=false
DELETE_PREVIOUS=false
ENV_FILE_OVERRIDE=""
DRY_RUN=false
CHECK_ONLY=false
CONTEXT_ONLY=false

usage() {
  cat <<'USAGE'
Usage: uranus_homelab.sh [OPTIONS]

Run the full Uranus homelab workflow (preflight, bootstrap, core addons, and
applications) using the shared helpers.

Options:
  --env-file PATH               Load configuration overrides from PATH.
  --assume-yes                  Automatically confirm prompts in child scripts.
  --delete-previous-environment Remove any existing Minikube profile before bootstrap.
  --dry-run                     Invoke child scripts in dry-run mode.
  --check-only                  Detect pfSense drift without applying changes.
  --context-preflight           Only run context discovery via preflight script.
  --verbose                     Increase logging verbosity to debug.
  -h, --help                    Show this help message.

Exit codes:
  0   Success.
  64  Usage error (invalid CLI arguments).
  69  Missing required dependencies.
  70  Runtime failure in a child script.
  78  Configuration error (missing environment file).
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

load_environment() {
  local -a args=()

  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    args+=(--env-file "${ENV_FILE_OVERRIDE}")
  fi

  if ! load_env "${args[@]}"; then
    if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Failed to load environment file: ${ENV_FILE_OVERRIDE}"
    fi
    warn "Continuing without an environment file"
    return 1
  fi

  return 0
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
    --check-only)
      CHECK_ONLY=true
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

build_common_args() {
  local -n target=$1
  target=()
  if [[ -n ${HOMELAB_ENV_FILE:-} ]]; then
    target+=("--env-file" "${HOMELAB_ENV_FILE}")
  fi
  if [[ ${ASSUME_YES} == true ]]; then
    target+=("--assume-yes")
  fi
  if [[ ${DRY_RUN} == true ]]; then
    target+=("--dry-run")
  fi
}

run_script() {
  local description=$1
  local relative=$2
  shift 2
  local args=("$@")
  local script_path="${REPO_ROOT}/${relative}"

  if [[ ! -x ${script_path} ]]; then
    log_warn "${relative} not found or not executable"
    return
  fi

  log_info "${description}"
  log_debug "Invoking: ${relative} $(format_command "${args[@]}")"
  if ! (cd "${REPO_ROOT}" && "${script_path}" "${args[@]}"); then
    die ${EX_SOFTWARE} "${relative} failed"
  fi
}

run_preflight() {
  local args=()
  build_common_args args
  if [[ ${DELETE_PREVIOUS} == true ]]; then
    args+=("--delete-previous-environment")
  fi
  if [[ ${CONTEXT_ONLY} == true ]]; then
    args+=("--context-preflight")
  else
    args+=("--preflight-only")
  fi
  run_script "Running preflight checks" "scripts/preflight_and_bootstrap.sh" "${args[@]}"
}

run_bootstrap() {
  local args=()
  build_common_args args
  if [[ ${DELETE_PREVIOUS} == true ]]; then
    args+=("--delete-previous-environment")
  fi
  run_script "Running nuke and bootstrap" "scripts/uranus_nuke_and_bootstrap.sh" "${args[@]}"
}

run_pfsense_ztp() {
  local common_args=()
  build_common_args common_args

  local env_file
  env_file="${HOMELAB_ENV_FILE:-./.env}"

  local pf_args=(
    "--env-file" "${env_file}"
    "--vm-name" "${PF_VM_NAME:-pfsense-uranus}"
    "--verbose"
  )

  local i=0
  while ((i < ${#common_args[@]})); do
    case "${common_args[i]}" in
    --env-file)
      ((i += 2))
      continue
      ;;
    --dry-run)
      pf_args+=("--dry-run")
      ;;
    esac
    ((++i))
  done

  if [[ ${CHECK_ONLY} == true ]]; then
    pf_args+=("--check-only")
  fi

  local cmd=(sudo -E ./scripts/pf-ztp.sh "${pf_args[@]}")

  log_info "Running pfSense zero-touch provisioning"
  log_debug "Invoking: $(format_command "${cmd[@]}")"

  if ! (cd "${REPO_ROOT}" && "${cmd[@]}"); then
    local status=$?
    die "${status}" "scripts/pf-ztp.sh failed with exit ${status}"
  fi
}

run_core_addons() {
  local args=()
  build_common_args args
  run_script "Installing core addons" "scripts/uranus_homelab_one.sh" "${args[@]}"
}

run_applications() {
  local args=()
  build_common_args args
  run_script "Deploying applications" "scripts/uranus_homelab_apps.sh" "${args[@]}"
}

main() {
  parse_args "$@"
  load_environment

  run_preflight
  if [[ ${CONTEXT_ONLY} == true ]]; then
    log_info "Context preflight complete"
    return
  fi

  run_pfsense_ztp
  run_bootstrap
  run_core_addons
  run_applications
  log_info "Uranus homelab setup complete."
}

main "$@"
