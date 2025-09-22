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
