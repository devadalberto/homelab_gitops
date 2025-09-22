#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common-env.sh
source "${SCRIPT_DIR}/common-env.sh"

ENV_FILE=""

usage() {
  cat <<'USAGE'
Usage: net-ensure.sh [OPTIONS]

Validate that required network bridges are present.

Options:
  --env-file PATH   Load environment variables from PATH before validation.
  -h, --help        Show this help message and exit.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage >&2
          fatal ${EX_USAGE} "--env-file requires a path"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --env-file=*)
        ENV_FILE="${1#*=}"
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
      -*)
        usage >&2
        fatal ${EX_USAGE} "Unknown option: $1"
        ;;
      *)
        usage >&2
        fatal ${EX_USAGE} "Unexpected positional argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if ! load_env --env-file "${ENV_FILE}"; then
    if [[ -n ${ENV_FILE} ]]; then
      fatal ${EX_CONFIG} "Environment file not found: ${ENV_FILE}"
    fi
    warn "Continuing without an environment file"
  fi

  validate_bridges
  local status=$?

  if (( status == 0 )); then
    if (( ${#HOMELAB_BRIDGES_READY[@]} > 0 )); then
      info "Ready bridges: ${HOMELAB_BRIDGES_READY[*]}"
    fi
    info "Network bridge validation completed successfully"
    return ${EX_OK}
  fi

  if (( status == 2 )); then
    warn "Bridge validation skipped because the ip command is unavailable"
    return ${EX_OK}
  fi

  if (( ${#HOMELAB_BRIDGES_ISSUES[@]} > 0 )); then
    warn "Bridge issues detected: ${HOMELAB_BRIDGES_ISSUES[*]}"
  fi
  fatal ${EX_CONFIG} "Network bridges are missing or down"
}

main "$@"
