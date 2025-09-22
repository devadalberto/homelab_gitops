#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${REPO_ROOT}/scripts/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
else
  FALLBACK_LIB="${REPO_ROOT}/scripts/lib/common_fallback.sh"
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
readonly EX_CONFIG=78

ENV_FILE_OVERRIDE=""
ALLOW_CREATE=true
SUDO=()

usage() {
  cat <<'USAGE'
Usage: net-ensure.sh [OPTIONS]

Ensure the pfSense WAN and LAN bridges exist on the host.

Options:
  --env-file PATH   Load configuration overrides from PATH.
  --help            Show this help message and exit.

Environment:
  NET_CREATE        When set to "0", "false", or "no", only validate bridges
                    without creating or modifying them. Any other value (the
                    default) allows creation of missing bridges.
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
      die ${EX_USAGE} "Positional arguments are not supported."
      ;;
    esac
  done
}

should_allow_create() {
  local raw=${NET_CREATE:-1}
  case "${raw,,}" in
  1 | true | yes | on | '')
    ALLOW_CREATE=true
    ;;
  0 | false | no | off)
    ALLOW_CREATE=false
    ;;
  *)
    log_warn "Unrecognized NET_CREATE value '${raw}'. Proceeding without creating bridges."
    ALLOW_CREATE=false
    ;;
  esac
}

resolve_sudo() {
  if [[ ${ALLOW_CREATE} == false ]]; then
    return
  fi
  if [[ ${EUID:-} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO=(sudo)
    else
      die ${EX_USAGE} "Root privileges (or sudo) are required to create or modify bridges."
    fi
  fi
}

load_environment() {
  local candidates=()
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    candidates=("${ENV_FILE_OVERRIDE}")
  else
    candidates=(
      "${REPO_ROOT}/.env"
      "${SCRIPT_DIR}/.env"
      "/opt/homelab/.env"
    )
  fi

  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -n ${candidate} && -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
  fi
  log_debug "No environment file found; relying on existing environment"
}

bridge_exists() {
  local name=$1
  ip link show dev "${name}" >/dev/null 2>&1
}

bridge_is_up() {
  local name=$1
  local state
  state=$(ip -o link show dev "${name}" 2>/dev/null | awk '{print $9}') || return 1
  [[ ${state} == "UP" ]]
}

ensure_bridge() {
  local label=$1
  local name=$2
  if [[ -z ${name} ]]; then
    die ${EX_CONFIG} "${label} bridge name is not set. Update the environment configuration."
  fi

  if bridge_exists "${name}"; then
    log_info "${label} bridge ${name} already exists"
  else
    if [[ ${ALLOW_CREATE} == false ]]; then
      die ${EX_CONFIG} "${label} bridge ${name} is missing. Re-run with NET_CREATE=1 to create it."
    fi
    log_info "Creating ${label} bridge ${name}"
    "${SUDO[@]}" ip link add name "${name}" type bridge
  fi

  if bridge_is_up "${name}"; then
    log_debug "${label} bridge ${name} is already up"
  else
    if [[ ${ALLOW_CREATE} == false ]]; then
      die ${EX_CONFIG} "${label} bridge ${name} exists but is down. Re-run with NET_CREATE=1 to bring it up."
    fi
    log_info "Bringing up ${label} bridge ${name}"
    "${SUDO[@]}" ip link set dev "${name}" up
  fi
}

main() {
  need ip || die ${EX_USAGE} "ip command is required"
  parse_args "$@"
  should_allow_create
  resolve_sudo
  load_environment

  local wan_mode="${WAN_MODE:-br0}"
  local wan_bridge="${PF_WAN_BRIDGE:-}"
  local lan_bridge="${PF_LAN_BRIDGE:-}"

  if [[ ${wan_mode} == br0 ]]; then
    ensure_bridge "WAN" "${wan_bridge}"
  else
    log_info "WAN_MODE=${wan_mode}; skipping WAN bridge checks"
  fi

  ensure_bridge "LAN" "${lan_bridge}"

  log_info "Bridge validation complete"
}

main "$@"
