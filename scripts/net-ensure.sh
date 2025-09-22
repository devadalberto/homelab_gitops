#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common-env.sh
source "${SCRIPT_DIR}/common-env.sh"

ENV_FILE_OVERRIDE=""
ALLOW_CREATE=false
SUDO=()

declare -a READY_BRIDGES=()
declare -a BRIDGE_ISSUES=()

usage() {
  cat <<'USAGE'
Usage: net-ensure.sh [OPTIONS]

Validate that the pfSense WAN and LAN bridges exist on the host. When
NET_CREATE is truthy the script will create or repair missing bridges.

Options:
  --env-file PATH   Load configuration overrides from PATH before validation.
  -h, --help        Show this help message and exit.

Environment:
  NET_CREATE        When set to "1", "true", "yes", or "on", missing bridges
                    will be created and brought online. Any other value leaves
                    existing bridges untouched.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          fatal ${EX_USAGE} "--env-file requires a path"
        fi
        ENV_FILE_OVERRIDE="$2"
        shift 2
        ;;
      --env-file=*)
        ENV_FILE_OVERRIDE="${1#*=}"
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

should_allow_create() {
  local raw=${NET_CREATE:-1}
  case "${raw,,}" in
    1|true|yes|on|enable|enabled)
      ALLOW_CREATE=true
      ;;
    0|false|no|off|disable|disabled)
      ALLOW_CREATE=false
      ;;
    *)
      ALLOW_CREATE=false
      ;;
  esac
}

resolve_sudo() {
  if [[ ${ALLOW_CREATE} == false ]]; then
    return
  fi
  if [[ ${EUID:-0} -eq 0 ]]; then
    SUDO=()
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    fatal ${EX_USAGE} "Root privileges (or sudo) are required to create bridges"
  fi
}

bridge_exists() {
  local bridge=$1
  ip link show dev "${bridge}" >/dev/null 2>&1
}

bridge_state() {
  local bridge=$1
  ip -o link show dev "${bridge}" 2>/dev/null | awk '{print $9}'
}

ensure_bridge_ready() {
  local role=$1
  local bridge=$2

  if [[ -z ${bridge} ]]; then
    BRIDGE_ISSUES+=("${role}:<unset>")
    warn "${role} bridge environment variable is not set"
    return 1
  fi

  if bridge_exists "${bridge}"; then
    local state
    state=$(bridge_state "${bridge}")
    if [[ ${state} == "UP" ]]; then
      READY_BRIDGES+=("${bridge}")
      info "${role} bridge ${bridge} is present and up"
      return 0
    fi

    if [[ ${ALLOW_CREATE} == true ]]; then
      info "${role} bridge ${bridge} is ${state:-down}; bringing it up"
      "${SUDO[@]}" ip link set dev "${bridge}" up
      state=$(bridge_state "${bridge}")
      if [[ ${state} == "UP" ]]; then
        READY_BRIDGES+=("${bridge}")
        info "${role} bridge ${bridge} is now up"
        return 0
      fi
      BRIDGE_ISSUES+=("${role}:${bridge}:failed-up")
      fatal ${EX_SOFTWARE} "Failed to bring ${role} bridge ${bridge} up"
    fi

    BRIDGE_ISSUES+=("${role}:${bridge}:${state:-down}")
    warn "${role} bridge ${bridge} exists but is ${state:-down}"
    return 1
  fi

  if [[ ${ALLOW_CREATE} == true ]]; then
    info "Creating ${role} bridge ${bridge}"
    "${SUDO[@]}" ip link add name "${bridge}" type bridge
    "${SUDO[@]}" ip link set dev "${bridge}" up
    if bridge_exists "${bridge}"; then
      READY_BRIDGES+=("${bridge}")
      info "${role} bridge ${bridge} created and up"
      return 0
    fi
    BRIDGE_ISSUES+=("${role}:${bridge}:create-failed")
    fatal ${EX_SOFTWARE} "Failed to create ${role} bridge ${bridge}"
  fi

  BRIDGE_ISSUES+=("${role}:${bridge}:missing")
  warn "${role} bridge ${bridge} is missing"
  return 1
}

main() {
  parse_args "$@"

  if ! load_env "${ENV_FILE_OVERRIDE}"; then
    if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
      fatal ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    warn "Continuing without an environment file"
  fi

  should_allow_create
  resolve_sudo

  require_cmd ip || fatal ${EX_UNAVAILABLE} "ip command is required"

  local env_source
  env_source=${HOMELAB_ENV_FILE:-${ENV_FILE_OVERRIDE:-environment}}

  READY_BRIDGES=()
  BRIDGE_ISSUES=()

  if [[ ${WAN_MODE:-br0} == br0 ]]; then
    ensure_bridge_ready "WAN" "${PF_WAN_BRIDGE:-}"
  else
    info "WAN_MODE=${WAN_MODE}; skipping WAN bridge validation"
  fi
  ensure_bridge_ready "LAN" "${PF_LAN_BRIDGE:-}"

  if (( ${#BRIDGE_ISSUES[@]} > 0 )); then
    if [[ ${ALLOW_CREATE} == true ]]; then
      fatal ${EX_SOFTWARE} "Bridge operations did not complete successfully"
    fi
    fatal ${EX_CONFIG} "Network bridges missing or down (source: ${env_source})"
  fi

  if [[ ${ALLOW_CREATE} == true ]]; then
    info "NET_CREATE enabled; bridges verified"
  fi

  if (( ${#READY_BRIDGES[@]} > 0 )); then
    info "Ready bridges: ${READY_BRIDGES[*]}"
  fi
}

main "$@"
