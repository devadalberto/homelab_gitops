#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

STATE_FILE=""
ENV_FILE_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: resume-state.sh [OPTIONS]

Emit the current Uranus bootstrap state marker.

Options:
  --env-file PATH   Load configuration overrides from PATH.
  --state-file PATH Read the state marker from PATH instead of the default.
  --help            Show this help message.

Exit codes:
  0  Success.
  64 Usage error (invalid CLI arguments).
USAGE
}

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    log_info "Loading environment overrides from ${ENV_FILE_OVERRIDE}"
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_USAGE} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    load_env "${ENV_FILE_OVERRIDE}" || die ${EX_USAGE} "Failed to load ${ENV_FILE_OVERRIDE}"
    return
  fi
  local parent_root
  parent_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
  local candidates=(
    "${parent_root}/.env"
    "${SCRIPT_DIR}/.env"
    "/opt/homelab/.env"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    log_debug "Checking for environment file at ${candidate}"
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_USAGE} "Failed to load ${candidate}"
      return
    fi
  done
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
      --state-file)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--state-file requires a path argument"
        fi
        STATE_FILE="$2"
        shift 2
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

main() {
  parse_args "$@"
  load_environment
  : "${URANUS_STATE_FILE:=/root/.uranus_bootstrap_state}"
  STATE_FILE="${STATE_FILE:-${URANUS_STATE_FILE}}"
  if [[ -f ${STATE_FILE} ]]; then
    cat "${STATE_FILE}"
  else
    printf 'start\n'
  fi
}

main "$@"
