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
readonly EX_CONFIG=78

DRY_RUN=false
CONTEXT_ONLY=false
ENV_FILE_OVERRIDE=""
STATE_FILE=""
BRIDGE_NAME=""
NIC=""

declare -a NAMESERVERS=()

usage() {
  cat <<'USAGE'
Usage: net-bridge.sh [OPTIONS] -- <WAN_NIC>

Configure a netplan bridge for the specified WAN interface.

Options:
  --env-file PATH         Load configuration overrides from PATH.
  --state-file PATH       Override the bootstrap state file path.
  --dry-run               Log actions without modifying the system.
  --context-preflight     Display detected network context and exit.
  -h, --help              Show this help message.

Exit codes:
  0  Success.
  64 Usage error (invalid CLI arguments).
  69 Missing required dependencies.
  70 Runtime failure.
  78 Configuration error (missing environment or network data).
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
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  log_debug "No environment file present in default search locations"
}

parse_nameservers() {
  local raw=${NET_BRIDGE_NAMESERVERS:-"1.1.1.1,9.9.9.9"}
  local old_ifs=${IFS}
  IFS=','
  read -r -a NAMESERVERS <<<"${raw}"
  IFS=${old_ifs}
  local idx value trimmed
  for idx in "${!NAMESERVERS[@]}"; do
    value="${NAMESERVERS[idx]}"
    trimmed=$(printf '%s' "${value}" | tr -d '[:space:]')
    NAMESERVERS[idx]="${trimmed}"
  done
  local filtered=()
  for value in "${NAMESERVERS[@]}"; do
    [[ -n ${value} ]] && filtered+=("${value}")
  done
  if [[ ${#filtered[@]} -eq 0 ]]; then
    filtered=(1.1.1.1 9.9.9.9)
  fi
  NAMESERVERS=("${filtered[@]}")
}

join_nameservers() {
  local joined=""
  local ns
  for ns in "${NAMESERVERS[@]}"; do
    if [[ -z ${joined} ]]; then
      joined="${ns}"
    else
      joined+=" ${ns}"
    fi
  done
  printf '%s' "${joined}"
}

parse_args() {
  local positional=()
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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --context-preflight)
      CONTEXT_ONLY=true
      shift
      ;;
    -h | --help)
      usage
      exit ${EX_OK}
      ;;
    --)
      shift
      positional=("$@")
      break
      ;;
    -*)
      usage
      die ${EX_USAGE} "Unknown option: $1"
      ;;
    *)
      usage
      die ${EX_USAGE} "WAN NIC must be specified after --"
      ;;
    esac
  done

  if [[ ${#positional[@]} -eq 0 ]]; then
    usage
    die ${EX_USAGE} "Missing WAN NIC argument"
  fi
  if [[ ${#positional[@]} -gt 1 ]]; then
    usage
    die ${EX_USAGE} "Unexpected extra positional arguments: ${positional[*]:1}"
  fi
  NIC="${positional[0]}"
}

HOST_IPV4=""
HOST_MASK=""
HOST_GATEWAY=""

collect_defaults() {
  : "${NET_BRIDGE_STATE_FILE:=/root/.uranus_bootstrap_state}"
  : "${NET_BRIDGE_NAME:=br0}"
  STATE_FILE="${STATE_FILE:-${NET_BRIDGE_STATE_FILE}}"
  BRIDGE_NAME="${NET_BRIDGE_NAME}"
  parse_nameservers
}

resolve_network_values() {
  need ip awk cut || die ${EX_UNAVAILABLE} "ip utility is required"
  local address_data
  address_data=$(ip -4 -br addr show "${NIC}" 2>/dev/null | awk '{print $3}' || true)
  if [[ -n ${address_data} && ${address_data} == */* ]]; then
    HOST_IPV4=${address_data%/*}
    HOST_MASK=${address_data#*/}
  fi
  HOST_GATEWAY=$(ip route | awk -v dev="${NIC}" '($1 == "default" && (!dev || $0 ~ " dev " dev " ")) {print $3; exit}')

  if [[ -n ${NET_BRIDGE_HOST_IPV4:-} ]]; then
    HOST_IPV4="${NET_BRIDGE_HOST_IPV4}"
  fi
  if [[ -n ${NET_BRIDGE_HOST_MASK:-} ]]; then
    HOST_MASK="${NET_BRIDGE_HOST_MASK}"
  fi
  if [[ -n ${NET_BRIDGE_GATEWAY:-} ]]; then
    HOST_GATEWAY="${NET_BRIDGE_GATEWAY}"
  fi
}

require_network_values() {
  if [[ -n ${HOST_IPV4} && -n ${HOST_MASK} && -n ${HOST_GATEWAY} ]]; then
    return
  fi
  if [[ ${DRY_RUN} == true ]]; then
    die ${EX_CONFIG} "Network parameters for ${NIC} must be provided when using --dry-run"
  fi
  if [[ ! -t 0 ]]; then
    die ${EX_CONFIG} "Unable to determine network parameters for ${NIC}; provide NET_BRIDGE_HOST_* overrides"
  fi
  log_warn "Network information for ${NIC} could not be auto-detected"
  read -r -p "Enter host IPv4 for ${BRIDGE_NAME} (e.g., 192.168.88.12): " HOST_IPV4
  read -r -p "Enter CIDR mask (e.g., 24): " HOST_MASK
  read -r -p "Enter default gateway (e.g., 192.168.88.1): " HOST_GATEWAY
  if [[ -z ${HOST_IPV4} || -z ${HOST_MASK} || -z ${HOST_GATEWAY} ]]; then
    die ${EX_CONFIG} "All network parameters must be provided"
  fi
}

context_preflight() {
  log_info "Network bridge context preflight"
  log_info "Bridge name: ${BRIDGE_NAME}"
  log_info "Target interface: ${NIC}"
  log_info "State file: ${STATE_FILE}"
  log_info "Current IPv4: ${HOST_IPV4:-unset}/${HOST_MASK:-unset}"
  log_info "Default gateway: ${HOST_GATEWAY:-unset}"
  log_info "Nameservers: $(join_nameservers)"
}

backup_netplan() {
  local backup_dir="/etc/netplan.backup.$(date +%F_%H%M%S)"
  log_info "Creating netplan backup at ${backup_dir}"
  run_cmd cp -a /etc/netplan "${backup_dir}"
}

write_netplan_config() {
  local config_path="/etc/netplan/60-${BRIDGE_NAME}.yaml"
  local ns_list
  ns_list=$(printf '%s' "${NAMESERVERS[*]}" | tr ' ' ',')
  log_info "Writing netplan configuration to ${config_path}"
  if [[ ${DRY_RUN} == true ]]; then
    local preview
    printf -v preview '[DRY-RUN] netplan configuration:\nnetwork:\n  version: 2\n  renderer: networkd\n  ethernets:\n    %s: {dhcp4: no}\n  bridges:\n    %s:\n      interfaces: [%s]\n      addresses: [%s/%s]\n      gateway4: %s\n      nameservers:\n        addresses: [%s]\n      parameters:\n        stp: true\n        forward-delay: 0' \
      "${NIC}" "${BRIDGE_NAME}" "${NIC}" "${HOST_IPV4}" "${HOST_MASK}" "${HOST_GATEWAY}" "${ns_list}"
    log_info "${preview}"
    return
  fi
  cat <<EOF_CONF >"${config_path}"
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}: {dhcp4: no}
  bridges:
    ${BRIDGE_NAME}:
      interfaces: [${NIC}]
      addresses: [${HOST_IPV4}/${HOST_MASK}]
      gateway4: ${HOST_GATEWAY}
      nameservers:
        addresses: [${ns_list}]
      parameters:
        stp: true
        forward-delay: 0
EOF_CONF
}

apply_netplan() {
  log_info "Applying netplan configuration"
  run_cmd netplan generate
  run_cmd netplan apply
}

update_state_marker() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would write state marker to ${STATE_FILE}"
    return
  fi
  printf 'post_%s_reboot\n' "${BRIDGE_NAME}" >"${STATE_FILE}"
}

reboot_host() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would reboot host"
    return
  fi
  log_warn "Rebooting host to apply bridge configuration"
  sleep 3
  reboot
}

main() {
  parse_args "$@"
  load_environment
  collect_defaults
  resolve_network_values
  require_network_values

  if [[ ${CONTEXT_ONLY} == true ]]; then
    context_preflight
    return
  fi

  need cp netplan || die ${EX_UNAVAILABLE} "cp and netplan are required"
  backup_netplan
  write_netplan_config
  apply_netplan
  update_state_marker
  log_info "Bridge ${BRIDGE_NAME} configured on interface ${NIC}"
  reboot_host
}

main "$@"
