#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

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

main() {
  parse_args "$@"
  if ! load_env "${ENV_FILE_OVERRIDE}"; then
    if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_USAGE} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    log_debug "No environment file present in default search locations"
  fi
  : "${URANUS_STATE_FILE:=/root/.uranus_bootstrap_state}"
  STATE_FILE="${STATE_FILE:-${URANUS_STATE_FILE}}"
  if [[ -f ${STATE_FILE} ]]; then
    cat "${STATE_FILE}"
  else
    printf 'start\n'
  fi
}

main "$@"
