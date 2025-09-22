#!/usr/bin/env bash
set -euo pipefail

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

PF_LAN_LIB="${REPO_ROOT}/scripts/lib/pf_lan.sh"
if [[ -f "${PF_LAN_LIB}" ]]; then
  # shellcheck source=scripts/lib/pf_lan.sh
  source "${PF_LAN_LIB}"
fi

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_CONFIG=78
readonly EX_DEPENDENCY=65
readonly EX_RUNTIME=69

ENV_FILE=""
LAN_BRIDGE_OVERRIDE=""
SKIP_NETNS=false
SKIP_REACHABILITY=false
LOG_LEVEL_OVERRIDE=""

VM_NAME=""
LAN_BRIDGE=""
LAN_BRIDGE_SOURCE=""
LAN_GW_IP=""
HTTPS_PROBE_URL=""
NETNS_NAME=""
NETNS_HOST_IF=""
NETNS_NS_IF=""
WAN_ICMP_TARGET=""
WAN_HTTP_TARGET=""

SUDO=()
VIRSH_CMD=()
TMP_DIR=""

DHCP_REQUEST_CMD=()
DHCP_RELEASE_CMD=()
DHCP_RELEASE_REQUIRED=false
DHCP_LEASE_ACQUIRED=false

NETNS_CREATED=false
VETH_CREATED=false

usage() {
  cat <<'USAGE'
Usage: pf-smoketest.sh [OPTIONS]

Validate pfSense libvirt domain status, LAN reachability, and perform a
network namespace DHCP/NAT probe against the LAN bridge.

Options:
  --env-file PATH       Source environment variables from PATH before running.
  --lan-bridge NAME     Override the LAN bridge used for probing.
  --vm-name NAME        Override the pfSense libvirt domain name.
  --skip-netns          Skip the network namespace DHCP/NAT validation.
  --skip-reachability   Skip host reachability probes (gateway/HTTPS).
  --log-level LEVEL     Adjust logging verbosity (trace, debug, info, warn, error).
  -h, --help            Show this help message and exit.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit "${EX_USAGE}"
      fi
      ENV_FILE="$2"
      shift 2
      ;;
    --lan-bridge)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit "${EX_USAGE}"
      fi
      LAN_BRIDGE_OVERRIDE="$2"
      shift 2
      ;;
    --vm-name)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit "${EX_USAGE}"
      fi
      VM_NAME="$2"
      shift 2
      ;;
    --skip-netns)
      SKIP_NETNS=true
      shift
      ;;
    --skip-reachability)
      SKIP_REACHABILITY=true
      shift
      ;;
    --log-level)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit "${EX_USAGE}"
      fi
      LOG_LEVEL_OVERRIDE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit "${EX_OK}"
      ;;
    --)
      shift
      break
      ;;
    -*)
      log_error "Unknown option: $1"
      usage >&2
      exit "${EX_USAGE}"
      ;;
    *)
      break
      ;;
    esac
  done
}

load_env_file() {
  local path="$1"
  if [[ ! -f ${path} ]]; then
    die "${EX_CONFIG}" "Environment file '${path}' not found."
  fi
  if [[ ! -r ${path} ]]; then
    die "${EX_CONFIG}" "Environment file '${path}' is not readable."
  fi
  # shellcheck disable=SC1090
  source "${path}"
}

initialize_defaults() {
  if [[ -z ${VM_NAME} ]]; then
    VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
  fi

  local env_bridge="${LAN_BRIDGE:-}"
  if [[ -n ${LAN_BRIDGE_OVERRIDE} ]]; then
    LAN_BRIDGE="${LAN_BRIDGE_OVERRIDE}"
    LAN_BRIDGE_SOURCE="--lan-bridge"
  elif [[ -n ${env_bridge} ]]; then
    LAN_BRIDGE="${env_bridge}"
    LAN_BRIDGE_SOURCE="environment"
  elif [[ -n ${PF_LAN_BRIDGE:-} ]]; then
    LAN_BRIDGE="${PF_LAN_BRIDGE}"
    LAN_BRIDGE_SOURCE="PF_LAN_BRIDGE"
  else
    LAN_BRIDGE=""
    LAN_BRIDGE_SOURCE="auto-detect"
  fi

  if [[ -n ${LAN_GW_IP:-} ]]; then
    :
  elif [[ -n ${PF_LAN_GATEWAY:-} ]]; then
    LAN_GW_IP="${PF_LAN_GATEWAY}"
  else
    LAN_GW_IP="10.10.0.1"
  fi

  HTTPS_PROBE_URL="${PF_LAN_HTTP_URL:-https://${LAN_GW_IP}/}"
  NETNS_NAME="${PF_SMOKETEST_NETNS:-pf-smoketest}"
  NETNS_HOST_IF="${NETNS_NAME}-host"
  NETNS_NS_IF="${NETNS_NAME}-ns"
  WAN_ICMP_TARGET="${PF_SMOKETEST_TARGET:-1.1.1.1}"
  WAN_HTTP_TARGET="${PF_SMOKETEST_HTTP_TARGET:-https://example.com/}"
}

ensure_privileges() {
  if [[ ${EUID:-} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO=(sudo)
    else
      die "${EX_DEPENDENCY}" "Root privileges (or sudo) are required for pf-smoketest network operations."
    fi
  fi
}

setup_command_wrappers() {
  ensure_privileges
  VIRSH_CMD=("${SUDO[@]}" virsh)
}

interface_exists() {
  local dev="$1"
  if [[ -z ${dev} ]]; then
    return 1
  fi
  "${SUDO[@]}" ip link show dev "${dev}" >/dev/null 2>&1
}

detect_lan_bridge() {
  if [[ -n ${LAN_BRIDGE} ]]; then
    if interface_exists "${LAN_BRIDGE}"; then
      return 0
    fi
    die "${EX_RUNTIME}" "Specified LAN bridge '${LAN_BRIDGE}' not present on host."
  fi

  local -a candidates=()
  local -a reasons=()

  if [[ -n ${PF_LAN_LINK:-} ]]; then
    if declare -F pf_lan_resolve_network_bridge >/dev/null 2>&1; then
      local resolved=""
      if resolved=$(pf_lan_resolve_network_bridge "${PF_LAN_LINK}" 2>/dev/null); then
        candidates+=("${resolved}")
        reasons+=("PF_LAN_LINK=${PF_LAN_LINK}")
      fi
    fi
  fi

  if [[ -n ${PF_LAN_BRIDGE:-} ]]; then
    candidates+=("${PF_LAN_BRIDGE}")
    reasons+=("PF_LAN_BRIDGE=${PF_LAN_BRIDGE}")
  fi

  candidates+=("pfsense-lan")
  reasons+=("fallback pfsense-lan")

  local idx
  for idx in "${!candidates[@]}"; do
    local candidate="${candidates[$idx]}"
    if interface_exists "${candidate}"; then
      LAN_BRIDGE="${candidate}"
      LAN_BRIDGE_SOURCE="${reasons[$idx]}"
      return 0
    fi
  done

  die "${EX_RUNTIME}" "Unable to detect an operational pfSense LAN bridge."
}

check_dependencies() {
  local -a deps=(virsh ip ping curl nc timeout awk sed grep)
  if ! need "${deps[@]}"; then
    die "${EX_DEPENDENCY}" "Missing required commands for pf-smoketest."
  fi
  if [[ ${SKIP_NETNS} == false ]]; then
    if ! need ip; then
      die "${EX_DEPENDENCY}" "'ip' command is required for network namespace validation."
    fi
  fi
}

ensure_domain_running() {
  log_info "Validating libvirt domain '${VM_NAME}'"
  if ! "${VIRSH_CMD[@]}" dominfo "${VM_NAME}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Libvirt domain '${VM_NAME}' not found."
  fi

  local state
  state=$("${VIRSH_CMD[@]}" domstate "${VM_NAME}" 2>/dev/null || true)
  if [[ ${state} != "running" ]]; then
    log_warn "Domain '${VM_NAME}' is '${state}'. Attempting to start..."
    if ! "${VIRSH_CMD[@]}" start "${VM_NAME}" >/dev/null 2>&1; then
      die "${EX_RUNTIME}" "Unable to start domain '${VM_NAME}'."
    fi
    sleep 2
    state=$("${VIRSH_CMD[@]}" domstate "${VM_NAME}" 2>/dev/null || true)
    if [[ ${state} != "running" ]]; then
      die "${EX_RUNTIME}" "Domain '${VM_NAME}' failed to reach running state (state=${state})."
    fi
  fi
  log_info "Domain '${VM_NAME}' is running."
}

reachability_probes() {
  if [[ ${SKIP_REACHABILITY} == true ]]; then
    log_warn "Skipping host reachability probes per --skip-reachability."
    return
  fi

  log_info "Pinging pfSense LAN gateway ${LAN_GW_IP}"
  if ! ping -c1 -W2 "${LAN_GW_IP}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Unable to reach pfSense gateway ${LAN_GW_IP} via ICMP."
  fi
  log_info "pfSense gateway ${LAN_GW_IP} responded to ICMP."

  log_info "Checking TCP/443 on ${LAN_GW_IP}"
  if ! timeout 5 nc -z "${LAN_GW_IP}" 443 >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Port 443 on ${LAN_GW_IP} is unreachable."
  fi
  log_info "pfSense HTTPS port reachable."

  log_info "Performing HTTPS probe ${HTTPS_PROBE_URL}"
  if ! curl -ksS --connect-timeout 5 --max-time 10 -o /dev/null "${HTTPS_PROBE_URL}"; then
    die "${EX_RUNTIME}" "HTTPS probe to ${HTTPS_PROBE_URL} failed."
  fi
  log_info "HTTPS probe to ${HTTPS_PROBE_URL} succeeded."
}

choose_dhcp_client() {
  local iface="$1"
  DHCP_REQUEST_CMD=()
  DHCP_RELEASE_CMD=()
  DHCP_RELEASE_REQUIRED=false

  if command -v dhclient >/dev/null 2>&1; then
    DHCP_REQUEST_CMD=(dhclient -1 -v -pf "${TMP_DIR}/dhclient-${iface}.pid" -lf "${TMP_DIR}/dhclient-${iface}.leases" "${iface}")
    DHCP_RELEASE_CMD=(dhclient -r "${iface}")
    DHCP_RELEASE_REQUIRED=true
    log_debug "Using dhclient for DHCP in namespace."
    return 0
  fi

  if command -v udhcpc >/dev/null 2>&1; then
    DHCP_REQUEST_CMD=(udhcpc -i "${iface}" -q -n -t 5 -T 3)
    DHCP_RELEASE_REQUIRED=false
    log_debug "Using udhcpc for DHCP in namespace."
    return 0
  fi

  if command -v busybox >/dev/null 2>&1 && busybox udhcpc --help >/dev/null 2>&1; then
    DHCP_REQUEST_CMD=(busybox udhcpc -i "${iface}" -q -n -t 5 -T 3)
    DHCP_RELEASE_REQUIRED=false
    log_debug "Using busybox udhcpc for DHCP in namespace."
    return 0
  fi

  return 1
}

cleanup() {
  local status=$?
  set +e

  if [[ ${DHCP_RELEASE_REQUIRED} == true && ${DHCP_LEASE_ACQUIRED} == true && ${NETNS_CREATED} == true ]]; then
    if [[ ${#DHCP_RELEASE_CMD[@]} -gt 0 ]]; then
      "${SUDO[@]}" ip netns exec "${NETNS_NAME}" "${DHCP_RELEASE_CMD[@]}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n ${NETNS_HOST_IF} && ${VETH_CREATED} == true ]]; then
    "${SUDO[@]}" ip link delete "${NETNS_HOST_IF}" >/dev/null 2>&1 || true
  fi

  if [[ ${NETNS_CREATED} == true ]]; then
    "${SUDO[@]}" ip netns delete "${NETNS_NAME}" >/dev/null 2>&1 || true
  fi

  if [[ -n ${TMP_DIR} && -d ${TMP_DIR} ]]; then
    rm -rf -- "${TMP_DIR}" >/dev/null 2>&1 || true
  fi

  set -e
  return "${status}"
}

trap cleanup EXIT INT TERM

netns_dhcp_nat_probe() {
  if [[ ${SKIP_NETNS} == true ]]; then
    log_warn "Skipping network namespace validation per --skip-netns."
    return
  fi

  NETNS_CREATED=false
  VETH_CREATED=false
  DHCP_LEASE_ACQUIRED=false
  TMP_DIR=""

  if [[ -z ${LAN_BRIDGE} ]]; then
    die "${EX_RUNTIME}" "LAN bridge not detected; cannot perform netns validation."
  fi

  log_info "Starting network namespace DHCP/NAT validation (bridge=${LAN_BRIDGE})"

  TMP_DIR="$(mktemp -d -t pf-smoke-XXXXXX)"

  if ! choose_dhcp_client "eth0"; then
    die "${EX_DEPENDENCY}" "No supported DHCP client available (dhclient/udhcpc)."
  fi

  if "${SUDO[@]}" ip link show "${NETNS_HOST_IF}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Temporary veth '${NETNS_HOST_IF}' already exists; aborting to avoid conflicts."
  fi

  "${SUDO[@]}" ip netns add "${NETNS_NAME}"
  NETNS_CREATED=true

  "${SUDO[@]}" ip link add "${NETNS_HOST_IF}" type veth peer name "${NETNS_NS_IF}"
  VETH_CREATED=true

  "${SUDO[@]}" ip link set "${NETNS_HOST_IF}" master "${LAN_BRIDGE}"
  "${SUDO[@]}" ip link set "${NETNS_HOST_IF}" up
  "${SUDO[@]}" ip link set "${NETNS_NS_IF}" netns "${NETNS_NAME}"
  "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip link set lo up
  "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip link set "${NETNS_NS_IF}" name eth0
  "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip link set eth0 up

  log_info "Requesting DHCP lease inside namespace ${NETNS_NAME}"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" timeout 30 "${DHCP_REQUEST_CMD[@]}"; then
    die "${EX_RUNTIME}" "Failed to acquire DHCP lease inside namespace ${NETNS_NAME}."
  fi
  DHCP_LEASE_ACQUIRED=true

  local addr_output
  addr_output=$("${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip -4 -o addr show dev eth0)
  if [[ -z ${addr_output} ]]; then
    die "${EX_RUNTIME}" "No IPv4 address assigned to namespace interface."
  fi
  local acquired_cidr
  acquired_cidr=$(printf '%s\n' "${addr_output}" | awk '{print $4}' | head -n1)
  log_info "Namespace received address ${acquired_cidr}."

  local default_route
  default_route=$("${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip route show default || true)
  if [[ -z ${default_route} ]]; then
    die "${EX_RUNTIME}" "Namespace did not receive a default route from DHCP."
  fi
  log_info "Namespace default route: ${default_route}"

  log_info "Pinging pfSense gateway ${LAN_GW_IP} from namespace"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ping -c1 -W2 "${LAN_GW_IP}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Namespace unable to reach pfSense gateway ${LAN_GW_IP}."
  fi

  log_info "Verifying external connectivity via ping to ${WAN_ICMP_TARGET}"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ping -c1 -W3 "${WAN_ICMP_TARGET}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Namespace unable to reach ${WAN_ICMP_TARGET}; pfSense NAT may be failing."
  fi

  log_info "Validating HTTP connectivity (${WAN_HTTP_TARGET}) from namespace"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" curl -ksS --connect-timeout 5 --max-time 10 -o /dev/null "${WAN_HTTP_TARGET}"; then
    die "${EX_RUNTIME}" "Namespace HTTP probe to ${WAN_HTTP_TARGET} failed."
  fi

  log_info "Network namespace DHCP/NAT validation successful."
}

main() {
  parse_args "$@"

  if [[ -n ${ENV_FILE} ]]; then
    load_env_file "${ENV_FILE}"
  fi

  initialize_defaults

  if [[ -n ${LOG_LEVEL_OVERRIDE} ]]; then
    log_set_level "${LOG_LEVEL_OVERRIDE}"
  fi

  setup_command_wrappers
  check_dependencies
  detect_lan_bridge

  log_info "Using LAN bridge ${LAN_BRIDGE} (${LAN_BRIDGE_SOURCE})"
  log_info "Using pfSense gateway ${LAN_GW_IP}"

  ensure_domain_running
  reachability_probes
  netns_dhcp_nat_probe

  log_info "pfSense smoketest completed successfully."
}

main "$@"
