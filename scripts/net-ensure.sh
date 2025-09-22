#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/load-env.sh
source "${SCRIPT_DIR}/load-env.sh"

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78

ENV_FILE_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: net-ensure.sh [--env-file PATH]

Validate that the pfSense WAN and LAN bridges exist.
Set NET_CREATE=1 in the environment to create missing bridges.

Options:
  --env-file PATH  Load environment variables from PATH before validation.
  -h, --help       Show this help message.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          exit ${EX_USAGE}
        fi
        ENV_FILE_OVERRIDE="$2"
        shift 2
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
        usage
        exit ${EX_USAGE}
        ;;
      *)
        usage
        exit ${EX_USAGE}
        ;;
    esac
  done
}

bridge_exists() {
  local bridge=$1
  ip link show dev "${bridge}" >/dev/null 2>&1
}

bridge_is_up() {
  local bridge=$1
  local state
  state=$(ip -o link show dev "${bridge}" 2>/dev/null | awk '{print $9}') || return 1
  [[ ${state} == "UP" ]]
}

add_unique() {
  local array_name=$1
  local value=$2
  declare -n array_ref="${array_name}"
  local existing
  for existing in "${array_ref[@]:-}"; do
    if [[ ${existing} == "${value}" ]]; then
      return 0
    fi
  done
  array_ref+=("${value}")
}

ensure_bridge_ready() {
  local role=$1
  local bridge=$2
  local create_allowed=$3

  if [[ -z ${bridge} ]]; then
    die ${EX_CONFIG} "${role} bridge name is empty; check PF_${role}_BRIDGE in the environment"
  fi

  if bridge_exists "${bridge}"; then
    if bridge_is_up "${bridge}"; then
      log_info "Bridge ${bridge} (${role}) already exists and is up."
      add_unique READY_BRIDGES "${bridge}"
      return 0
    fi

    if [[ ${create_allowed} == true ]]; then
      log_info "Bridge ${bridge} (${role}) exists but is down; bringing it up."
      sudo ip link set "${bridge}" up
      if bridge_is_up "${bridge}"; then
        log_info "Bridge ${bridge} (${role}) is now up."
        add_unique READY_BRIDGES "${bridge}"
        return 0
      fi
      die ${EX_SOFTWARE} "Failed to bring bridge ${bridge} (${role}) up"
    fi

    log_warn "Bridge ${bridge} (${role}) exists but is down."
    add_unique MISSING_BRIDGES "${bridge} (down)"
    return 1
  fi

  if [[ ${create_allowed} == true ]]; then
    log_info "Creating bridge ${bridge} (${role})."
    sudo ip link add name "${bridge}" type bridge
    sudo ip link set "${bridge}" up
    if bridge_is_up "${bridge}"; then
      log_info "Bridge ${bridge} (${role}) created and up."
      add_unique READY_BRIDGES "${bridge}"
      return 0
    fi
    die ${EX_SOFTWARE} "Bridge ${bridge} (${role}) creation failed"
  fi

  log_warn "Bridge ${bridge} (${role}) is missing."
  add_unique MISSING_BRIDGES "${bridge} (missing)"
  return 1
}

main() {
  parse_args "$@"

  if ! command -v ip >/dev/null 2>&1; then
    die ${EX_UNAVAILABLE} "ip command is required"
  fi

  homelab_load_env "${ENV_FILE_OVERRIDE}" || die ${EX_CONFIG} "Failed to load environment"

  local env_source
  env_source=${HOMELAB_ENV_FILE:-${ENV_FILE_OVERRIDE:-${ENV_FILE:-}}}
  if [[ -z ${env_source} ]]; then
    env_source="the environment"
  fi

  declare -a READY_BRIDGES=()
  declare -a MISSING_BRIDGES=()

  declare -n wan_ref=PF_WAN_BRIDGE
  declare -n lan_ref=PF_LAN_BRIDGE

  if [[ -z ${wan_ref:-} ]]; then
    die ${EX_CONFIG} "PF_WAN_BRIDGE must be set in ${env_source}"
  fi
  if [[ -z ${lan_ref:-} ]]; then
    die ${EX_CONFIG} "PF_LAN_BRIDGE must be set in ${env_source}"
  fi

  local create_allowed=false
  case ${NET_CREATE:-} in
    1|true|TRUE|yes|YES|on|enable|enabled)
      create_allowed=true
      ;;
  esac

  log_info "Validating WAN bridge ${wan_ref}."
  ensure_bridge_ready "WAN" "${wan_ref}" "${create_allowed}"

  log_info "Validating LAN bridge ${lan_ref}."
  ensure_bridge_ready "LAN" "${lan_ref}" "${create_allowed}"

  if [[ ${#MISSING_BRIDGES[@]} -gt 0 ]]; then
    log_error "Network bridges missing or down: ${MISSING_BRIDGES[*]}"
    log_error "Set NET_CREATE=1 make net.ensure to create missing bridges."
    exit ${EX_CONFIG}
  fi

  if [[ ${create_allowed} == true ]]; then
    log_info "Bridge creation mode enabled (NET_CREATE=1)."
  fi

  if [[ ${#READY_BRIDGES[@]} -gt 0 ]]; then
    log_info "All requested network bridges are ready: ${READY_BRIDGES[*]}."
  fi

  exit ${EX_OK}
}

main "$@"
