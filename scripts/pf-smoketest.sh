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
readonly EX_DEPENDENCY=65
readonly EX_RUNTIME=69

DEFAULT_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
DEFAULT_GATEWAY="${PF_LAN_GATEWAY:-10.10.0.1}"
DEFAULT_LAN_NETWORK="${PF_LAN_NETWORK:-10.10.0.0}"  # network portion for temporary address validation
DEFAULT_LAN_PREFIX="${PF_LAN_PREFIX:-24}"
DEFAULT_HTTP_URL="${PF_LAN_HTTP_URL:-https://${DEFAULT_GATEWAY}/}"
DEFAULT_WAN_PROBE="${PF_SMOKETEST_TARGET:-1.1.1.1}"
DEFAULT_HTTP_TARGET="${PF_SMOKETEST_HTTP_TARGET:-https://example.com/}"
DEFAULT_NETNS="${PF_SMOKETEST_NETNS:-pf-smoketest}"
DEFAULT_BRIDGE_CANDIDATE="${PF_LAN_BRIDGE:-}"  # may be empty; detection routine will evaluate

VM_NAME="${DEFAULT_VM_NAME}"
LAN_BRIDGE_OVERRIDE=""
SKIP_NETNS=false
SKIP_REACHABILITY=false
LOG_LEVEL_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: pf-smoketest.sh [OPTIONS]

Perform a fast pfSense health check including libvirt domain validation,
LAN reachability probes, and a disposable network namespace DHCP/NAT test.

Options:
  --vm-name NAME        Override the libvirt domain name (default: pfsense-uranus).
  --lan-bridge BRIDGE   Force the LAN bridge name instead of auto-detection.
  --skip-netns          Skip the network namespace DHCP/NAT validation.
  --skip-reachability   Skip host reachability probes (not recommended).
  --log-level LEVEL     Set log verbosity (trace, debug, info, warn, error).
  -h, --help            Show this help message and exit.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vm-name)
        if [[ $# -lt 2 ]]; then
          usage >&2
          exit "${EX_USAGE}"
        fi
        VM_NAME="$2"
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
      -h|--help)
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

SUDO=()
ensure_privileges() {
  if [[ ${EUID:-} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO=(sudo)
    else
      die "${EX_DEPENDENCY}" "Root privileges (or sudo) are required for pf-smoketest network operations."
    fi
  fi
}

interface_exists() {
  local dev="$1"
  if [[ -z ${dev} ]]; then
    return 1
  fi
  if command -v ip >/dev/null 2>&1; then
    "${SUDO[@]}" ip link show dev "${dev}" >/dev/null 2>&1
  else
    [[ -e "/sys/class/net/${dev}" ]]
  fi
}

resolve_bridge_candidate() {
  local candidate="$1"
  local kind="bridge"
  local name="${candidate}"

  if [[ ${candidate} == *:* ]]; then
    kind="${candidate%%:*}"
    name="${candidate#*:}"
  fi

  case "${kind}" in
    bridge|tap)
      printf '%s\n' "${name}"
      return 0
      ;;
    network)
      if [[ -n ${name} ]] && command -v virsh >/dev/null 2>&1 && declare -F pf_lan_resolve_network_bridge >/dev/null 2>&1; then
        if pf_lan_resolve_network_bridge "${name}"; then
          return 0
        fi
      fi
      ;;
    *)
      if [[ -n ${name} ]]; then
        printf '%s\n' "${name}"
        return 0
      fi
      ;;
  esac
  return 1
}

LAN_BRIDGE=""
LAN_BRIDGE_SOURCE=""

detect_lan_bridge() {
  if [[ -n ${LAN_BRIDGE_OVERRIDE} ]]; then
    if interface_exists "${LAN_BRIDGE_OVERRIDE}"; then
      LAN_BRIDGE="${LAN_BRIDGE_OVERRIDE}"
      LAN_BRIDGE_SOURCE="--lan-bridge"
      return 0
    fi
    die "${EX_RUNTIME}" "Specified LAN bridge '${LAN_BRIDGE_OVERRIDE}' not present on host."
  fi

  local -a candidates=()
  local -a reasons=()

  if [[ -n ${PF_LAN_LINK:-} ]]; then
    local resolved=""
    if resolved=$(resolve_bridge_candidate "${PF_LAN_LINK}" 2>/dev/null); then
      candidates+=("${resolved}")
      reasons+=("PF_LAN_LINK=${PF_LAN_LINK}")
    else
      log_warn "Unable to resolve PF_LAN_LINK='${PF_LAN_LINK}' to a host bridge."
    fi
  fi

  if [[ -n ${DEFAULT_BRIDGE_CANDIDATE} ]]; then
    candidates+=("${DEFAULT_BRIDGE_CANDIDATE}")
    reasons+=("PF_LAN_BRIDGE=${DEFAULT_BRIDGE_CANDIDATE}")
  fi

  candidates+=("pfsense-lan")
  reasons+=("fallback pfsense-lan")

  local idx
  for idx in "${!candidates[@]}"; do
    local candidate="${candidates[$idx]}"
    local reason="${reasons[$idx]}"
    if [[ -z ${candidate} ]]; then
      continue
    fi
    if interface_exists "${candidate}"; then
      LAN_BRIDGE="${candidate}"
      LAN_BRIDGE_SOURCE="${reason}"
      return 0
    fi
    log_debug "LAN candidate '${candidate}' (${reason}) not present."
  done

  die "${EX_RUNTIME}" "Unable to detect an operational pfSense LAN bridge."
}

VIRSH_CMD=()
setup_command_wrappers() {
  ensure_privileges
  VIRSH_CMD=("${SUDO[@]}" virsh)
}

check_dependencies() {
  local -a base_reqs=(virsh ip ping curl nc timeout awk sed grep)
  if ! need "${base_reqs[@]}"; then
    die "${EX_DEPENDENCY}" "Missing required commands: ${base_reqs[*]}"
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
    log_warn "Domain '${VM_NAME}' state is '${state}'. Attempting to start..."
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

  if iflist=$("${VIRSH_CMD[@]}" domiflist "${VM_NAME}" 2>/dev/null); then
    log_debug "domiflist for ${VM_NAME}:\n${iflist}"
  fi

  if ! "${VIRSH_CMD[@]}" domifaddr "${VM_NAME}" --full --source arp >/dev/null 2>&1; then
    log_warn "domifaddr data unavailable (guest agent missing?); continuing."
  else
    local ifaddr
    ifaddr=$("${VIRSH_CMD[@]}" domifaddr "${VM_NAME}" --full --source arp 2>/dev/null || true)
    if [[ -n ${ifaddr} ]]; then
      log_debug "domifaddr output:\n${ifaddr}"
    fi
  fi
}

reachability_probes() {
  if [[ ${SKIP_REACHABILITY} == true ]]; then
    log_warn "Skipping host reachability probes per --skip-reachability."
    return
  fi

  local gateway="${DEFAULT_GATEWAY}"
  local https_url="${DEFAULT_HTTP_URL}"

  log_info "Pinging pfSense LAN gateway ${gateway}"
  if ! ping -c1 -W2 "${gateway}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Unable to reach pfSense gateway ${gateway} via ICMP."
  fi
  log_info "pfSense gateway ${gateway} responded to ICMP."

  log_info "Checking TCP/443 on ${gateway}"
  if ! timeout 5 nc -z "${gateway}" 443 >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Port 443 on ${gateway} is unreachable."
  fi
  log_info "pfSense HTTPS port reachable."

  log_info "Performing HTTPS probe ${https_url}"
  if ! curl -ksS --connect-timeout 5 --max-time 10 -o /dev/null "${https_url}"; then
    die "${EX_RUNTIME}" "HTTPS probe to ${https_url} failed."
  fi
  log_info "HTTPS probe to ${https_url} succeeded."
}

NETNS_NAME="${DEFAULT_NETNS}"
VETH_HOST="${NETNS_NAME}-host"
VETH_NS="${NETNS_NAME}-ns"
TMP_DIR=""
DHCP_REQUEST_CMD=()
DHCP_RELEASE_CMD=()
DHCP_RELEASE_REQUIRED=false

cleanup_netns() {
  local status=$?
  if [[ -n ${TMP_DIR} && -d ${TMP_DIR} ]]; then
    rm -rf -- "${TMP_DIR}" >/dev/null 2>&1 || true
    TMP_DIR=""
  fi

  if [[ ${DHCP_RELEASE_REQUIRED} == true && -n ${NETNS_NAME} ]]; then
    if [[ -n ${DHCP_RELEASE_CMD[*]} ]]; then
      if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" "${DHCP_RELEASE_CMD[@]}" >/dev/null 2>&1; then
        log_debug "DHCP release command failed; continuing cleanup."
      else
        log_debug "Released DHCP lease inside netns ${NETNS_NAME}."
      fi
    fi
  fi

  if [[ -n ${VETH_HOST} ]]; then
    if "${SUDO[@]}" ip link show "${VETH_HOST}" >/dev/null 2>&1; then
      "${SUDO[@]}" ip link delete "${VETH_HOST}" >/dev/null 2>&1 || true
    fi
  fi

  if [[ -n ${NETNS_NAME} ]]; then
    if "${SUDO[@]}" ip netns list | awk '{print $1}' | grep -Fx "${NETNS_NAME}" >/dev/null 2>&1; then
      "${SUDO[@]}" ip netns delete "${NETNS_NAME}" >/dev/null 2>&1 || true
    fi
  fi

  return "${status}"
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

netns_dhcp_nat_validation() {
  if [[ ${SKIP_NETNS} == true ]]; then
    log_warn "Skipping network namespace validation per --skip-netns."
    return
  fi

  if [[ -z ${LAN_BRIDGE} ]]; then
    die "${EX_RUNTIME}" "LAN bridge not detected; cannot perform netns validation."
  fi

  log_info "Starting network namespace DHCP/NAT validation (bridge=${LAN_BRIDGE})"

  TMP_DIR="$(mktemp -d -t pf-smoke-XXXXXX)"
  trap_add cleanup_netns EXIT INT TERM

  if ! choose_dhcp_client "eth0"; then
    die "${EX_DEPENDENCY}" "No supported DHCP client available (dhclient/udhcpc)."
  fi

  if "${SUDO[@]}" ip link show "${VETH_HOST}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Temporary veth '${VETH_HOST}' already exists; aborting to avoid conflicts."
  fi

  "${SUDO[@]}" ip netns add "${NETNS_NAME}"
  "${SUDO[@]}" ip link add "${VETH_HOST}" type veth peer name "${VETH_NS}"
  "${SUDO[@]}" ip link set "${VETH_HOST}" master "${LAN_BRIDGE}"
  "${SUDO[@]}" ip link set "${VETH_HOST}" up
  "${SUDO[@]}" ip link set "${VETH_NS}" netns "${NETNS_NAME}"
  "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip link set lo up
  "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip link set "${VETH_NS}" name eth0
  "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ip link set eth0 up

  log_info "Requesting DHCP lease inside namespace ${NETNS_NAME}"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" timeout 30 "${DHCP_REQUEST_CMD[@]}"; then
    die "${EX_RUNTIME}" "Failed to acquire DHCP lease inside namespace ${NETNS_NAME}."
  fi

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

  local gateway="${DEFAULT_GATEWAY}"
  log_info "Pinging pfSense gateway ${gateway} from namespace"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ping -c1 -W2 "${gateway}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Namespace unable to reach pfSense gateway ${gateway}."
  fi

  local wan_target="${DEFAULT_WAN_PROBE}"
  log_info "Verifying external connectivity via ping to ${wan_target}"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" ping -c1 -W3 "${wan_target}" >/dev/null 2>&1; then
    die "${EX_RUNTIME}" "Namespace unable to reach ${wan_target}; pfSense NAT may be failing."
  fi

  local http_target="${DEFAULT_HTTP_TARGET}"
  log_info "Validating HTTP connectivity (${http_target}) from namespace"
  if ! "${SUDO[@]}" ip netns exec "${NETNS_NAME}" curl -ksS --connect-timeout 5 --max-time 10 -o /dev/null "${http_target}"; then
    die "${EX_RUNTIME}" "Namespace HTTP probe to ${http_target} failed."
  fi

  log_info "Network namespace DHCP/NAT validation successful."
}

main() {
  parse_args "$@"

  if [[ -n ${LOG_LEVEL_OVERRIDE} ]]; then
    log_set_level "${LOG_LEVEL_OVERRIDE}"
  fi

  setup_command_wrappers
  check_dependencies
  detect_lan_bridge
  log_info "Detected LAN bridge ${LAN_BRIDGE} (${LAN_BRIDGE_SOURCE:-auto-detected})"

  ensure_domain_running
  reachability_probes
  netns_dhcp_nat_validation

  log_info "pfSense smoketest completed successfully."
}

main "$@"
