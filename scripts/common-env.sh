#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "scripts/common-env.sh is a helper library and must be sourced." >&2
  exit 64
fi

if [[ -n ${_HOMELAB_COMMON_ENV_SH_SOURCED:-} ]]; then
  return 0
fi
readonly _HOMELAB_COMMON_ENV_SH_SOURCED=1

HOMELAB_COMMON_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMELAB_REPO_ROOT="$(cd "${HOMELAB_COMMON_ENV_DIR}/.." && pwd)"
export HOMELAB_COMMON_ENV_DIR
export HOMELAB_REPO_ROOT

: "${REPO_ROOT:=${HOMELAB_REPO_ROOT}}"

readonly HOMELAB_ROOT="/opt/homelab"
readonly HOMELAB_ENV_DEFAULT="${HOMELAB_ROOT}/.env"
readonly HOMELAB_PFSENSE_ROOT="${HOMELAB_ROOT}/pfsense"
readonly HOMELAB_PFSENSE_CONFIG_DIR="${HOMELAB_PFSENSE_ROOT}/config"
readonly HOMELAB_BACKUP_DIR="${HOMELAB_ROOT}/backups"
readonly HOMELAB_STATE_DIR="${HOMELAB_ROOT}/state"

: "${EX_OK:=0}"
: "${EX_USAGE:=64}"
: "${EX_UNAVAILABLE:=69}"
: "${EX_SOFTWARE:=70}"
: "${EX_OSERR:=71}"
: "${EX_CONFIG:=78}"

COMMON_ENV_LIB="${HOMELAB_REPO_ROOT}/scripts/lib/common.sh"
if [[ -f ${COMMON_ENV_LIB} ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_ENV_LIB}"
elif [[ -f ${HOMELAB_REPO_ROOT}/scripts/lib/common_fallback.sh ]]; then
  # shellcheck source=scripts/lib/common_fallback.sh
  source "${HOMELAB_REPO_ROOT}/scripts/lib/common_fallback.sh"
else
  echo "homelab: unable to locate scripts/lib/common.sh" >&2
  return "${EX_SOFTWARE}"
fi

: "${HOMELAB_ENV_FILE:=}"
declare -ag HOMELAB_BRIDGES_READY=()
declare -ag HOMELAB_BRIDGES_ISSUES=()

# Default variables shown by dump_effective_env when no explicit list is provided.
# shellcheck disable=SC2034
HOMELAB_ENV_SUMMARY_VARS=(
  LABZ_DOMAIN
  LAB_DOMAIN_BASE
  LABZ_TRAEFIK_HOST
  LABZ_NEXTCLOUD_HOST
  LABZ_JELLYFIN_HOST
  LABZ_METALLB_RANGE
  PF_WAN_BRIDGE
  PF_LAN_BRIDGE
  WAN_MODE
  LAN_CIDR
  LAN_GW_IP
  LAN_DHCP_FROM
  LAN_DHCP_TO
  METALLB_POOL_START
  METALLB_POOL_END
  TRAEFIK_LOCAL_IP
  WORK_ROOT
  PG_BACKUP_HOSTPATH
)

log() {
  local level=${1:-info}
  shift || true
  case "${level,,}" in
  trace) log_trace "$@" ;;
  debug) log_debug "$@" ;;
  info) log_info "$@" ;;
  warn | warning) log_warn "$@" ;;
  error | err) log_error "$@" ;;
  fatal | crit | critical) log_fatal "$@" ;;
  *) log_info "${level} $*" ;;
  esac
}

info() { log_info "$@"; }
warn() { log_warn "$@"; }
fatal() { die "$@"; }

require_cmd() {
  if [[ $# -eq 0 ]]; then
    log_warn "require_cmd called without arguments"
    return 64
  fi
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  if ((${#missing[@]} > 0)); then
    log_error "Missing required commands: ${missing[*]}"
    return 1
  fi
  return 0
}

load_env() {
  local override=""
  local required=false
  local silent=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file | -e)
      if [[ $# -lt 2 ]]; then
        log_error "load_env: $1 requires a path argument"
        return "${EX_USAGE}"
      fi
      override="$2"
      shift 2
      ;;
    --env-file=* | -e=*)
      override="${1#*=}"
      shift
      ;;
    --required)
      required=true
      shift
      ;;
    --silent)
      silent=true
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      if [[ -z ${override} ]]; then
        override="$1"
      fi
      shift
      ;;
    esac
  done

  if [[ -z ${override} && -n ${ENV_FILE:-} ]]; then
    override="${ENV_FILE}"
  fi

  local -a candidates=()
  if [[ -n ${override} ]]; then
    candidates=("${override}")
  else
    candidates=(
      "${PWD}/.env"
      "${REPO_ROOT}/.env"
      "${HOMELAB_ENV_DEFAULT}"
      "${REPO_ROOT}/.env.example"
    )
  fi

  local candidate=""
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      if [[ ${silent} != true ]]; then
        info "Loading environment from ${candidate}"
      fi
      local previous_opts
      previous_opts=$(set +o)
      set -a
      # shellcheck disable=SC1090
      source "${candidate}"
      eval "${previous_opts}"
      HOMELAB_ENV_FILE="${candidate}"
      export HOMELAB_ENV_FILE
      return 0
    fi
  done

  HOMELAB_ENV_FILE=""

  if [[ -n ${override} ]]; then
    if [[ ${required} == true ]]; then
      return 1
    fi
    warn "Environment file not found: ${override}"
    return 1
  fi

  if [[ ${required} == true ]]; then
    return 1
  fi

  if [[ ${silent} != true ]]; then
    warn "No environment file found (checked: ${candidates[*]})"
  fi
  return 1
}

_homelab_record_bridge_state() {
  local role=$1
  local bridge=$2

  if [[ -z ${bridge} ]]; then
    HOMELAB_BRIDGES_ISSUES+=("${role}:<unset>:missing")
    warn "PF_${role}_BRIDGE is not set"
    return
  fi

  if ! ip link show dev "${bridge}" >/dev/null 2>&1; then
    HOMELAB_BRIDGES_ISSUES+=("${role}:${bridge}:missing")
    warn "${role} bridge ${bridge} not found"
    return
  fi

  local state
  state=$(ip -o link show dev "${bridge}" 2>/dev/null | awk '{print $9}')
  if [[ ${state} != "UP" ]]; then
    HOMELAB_BRIDGES_ISSUES+=("${role}:${bridge}:${state:-down}")
    warn "${role} bridge ${bridge} is ${state:-down}"
    return
  fi

  HOMELAB_BRIDGES_READY+=("${role}:${bridge}")
  info "${role} bridge ${bridge} is present and up"
}

validate_bridges() {
  HOMELAB_BRIDGES_READY=()
  HOMELAB_BRIDGES_ISSUES=()

  if ! command -v ip >/dev/null 2>&1; then
    warn "ip command not available; skipping bridge validation"
    return 2
  fi

  local wan_mode=${WAN_MODE:-br0}
  if [[ ${wan_mode} == "br0" ]]; then
    _homelab_record_bridge_state "WAN" "${PF_WAN_BRIDGE:-}"
  else
    info "WAN_MODE=${wan_mode}; skipping WAN bridge validation"
  fi
  _homelab_record_bridge_state "LAN" "${PF_LAN_BRIDGE:-}"

  if ((${#HOMELAB_BRIDGES_ISSUES[@]} > 0)); then
    return 1
  fi
  return 0
}

dump_effective_env() {
  local header="Effective environment"
  local print_header=true
  local -a vars=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-header)
      print_header=false
      shift
      ;;
    --header)
      if [[ $# -lt 2 ]]; then
        warn "dump_effective_env: --header requires a value"
        shift
      else
        header="$2"
        print_header=true
        shift 2
      fi
      ;;
    --)
      shift
      break
      ;;
    --*)
      warn "dump_effective_env: unrecognized option $1"
      shift
      ;;
    *)
      vars+=("$1")
      shift
      ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    vars+=("$@")
  fi

  if [[ ${#vars[@]} -eq 0 ]]; then
    vars=("${HOMELAB_ENV_SUMMARY_VARS[@]}")
  fi

  if [[ ${print_header} == true ]]; then
    printf '\n%s\n' "${header}"
    printf '%s\n' "$(printf '%*s' "${#header}" '' | tr ' ' '-')"
  fi

  if [[ -n ${HOMELAB_ENV_FILE} ]]; then
    printf '  %-20s %s\n' "Environment file" "${HOMELAB_ENV_FILE}"
  else
    printf '  %-20s %s\n' "Environment file" "(none)"
  fi

  local var value
  for var in "${vars[@]}"; do
    if [[ -n ${!var-} ]]; then
      value=${!var}
    else
      value="<unset>"
    fi
    printf '  %-20s %s\n' "${var}" "${value}"
  done
}

ensure_dirs() {
  local dir
  for dir in "$@"; do
    [[ -z ${dir} ]] && continue
    if [[ -d ${dir} ]]; then
      continue
    fi
    if mkdir -p "${dir}" >/dev/null 2>&1; then
      info "Created directory ${dir}"
      continue
    fi
    if command -v sudo >/dev/null 2>&1; then
      info "Creating directory ${dir} with sudo"
      if sudo mkdir -p "${dir}"; then
        continue
      fi
    fi
    fatal ${EX_OSERR} "Failed to create directory ${dir}"
  done
}
