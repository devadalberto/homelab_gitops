#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

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
else
  echo "Unable to locate scripts/lib/pf_lan.sh" >&2
  exit 70
fi

readonly EX_SUCCESS=0
readonly EX_PREFLIGHT=1
readonly EX_VERIFY=2
readonly EX_FATAL=3

LOG_FILE="/var/log/pfsense-ztp.log"
PF_ROOT="/opt/homelab/pfsense"
CONFIG_ROOT="${PF_ROOT}/config"
CONFIG_XML="${CONFIG_ROOT}/config.xml"
USB_IMAGE="${CONFIG_ROOT}/pfSense-ecl-usb.img"
USB_LABEL="ECLCFG"
USB_SIZE_MIB=8

ENV_FILE=""
VM_NAME=""
VM_NAME_ARG=""
FORCE_E1000=false
FORCE_REBUILD=false
DRY_RUN=false
CHECK_ONLY=false
VERBOSE=false
ROLLBACK=false
LENIENT=false

PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-}"
# Preferred way: PF_LAN_LINK specifies both kind and name (bridge:virbr-lan or network:pfsense-lan)
PF_LAN_LINK="${PF_LAN_LINK:-}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-}"
HOMELAB_EDGE_GATEWAY="${HOMELAB_EDGE_GATEWAY:-192.168.88.12}"
# NIC model control:
#   true  -> force change to e1000 (default was true)
#   false -> leave interfaces as virtio
PF_FORCE_E1000="${PF_FORCE_E1000:-false}"

TMP_DIR=""
USB_MOUNT_DIR=""
DOMAIN_XML_PATH=""
DOMAIN_INFO_JSON=""
DOMAIN_BACKUP_FILE=""
DOMAIN_BACKUP_CREATED=false
DOMAIN_STATE=""

CONFIG_CHANGED=false
IMAGE_REBUILT=false
USB_CONTROLLER_ADDED=false
USB_PRESENT=false
USB_DISK_ATTACHED=false
NIC_MODEL_CHANGED=false
LAN_INTERFACE_REWIRED=false
NEEDS_REBOOT=false
DRIFT_DETECTED=false
PING_SUCCESS=false
CURL_SUCCESS=false
VM_AUTO_STARTED=false
LAN_PROBE_IP=""
LAN_NETMASK=""
LAN_VALIDATION_IP=""
BRIDGE_IP_TEMP_ADDED=false
BRIDGE_CLEANUP_TRAP_INSTALLED=false
declare -a BRIDGE_TEMP_CIDRS=()

LAN_LINK_KIND=""
LAN_LINK_NAME=""

REBOOT_MARK_DIR="/run/pf-ztp"
REBOOT_MARK_FILE=""
LENIENT_MARK_FILE=""

# shellcheck disable=SC2317
usage() {
  cat <<'USAGE'
Usage: pf-ztp.sh [OPTIONS]

Zero-touch provisioning helper for pfSense USB bootstrap media and VM wiring.

Options:
  --env-file PATH    Load environment overrides from PATH.
  --vm-name NAME     Operate on the libvirt domain NAME.
  --force-e1000      Ensure the VM NIC model is e1000 (updates domain config).
  --force            Rebuild the ECL USB image even if config.xml is unchanged.
  --dry-run          Log intended actions without mutating the host or VM.
  --check-only       Detect drift without making changes; implies --dry-run.
  --verbose          Increase log verbosity (debug output).
  --lenient          Treat the first connectivity failure as a warning (exit 0).
  --rollback         Restore the most recent domain XML backup and exit.
  -h, --help         Show this help message.

Exit codes:
  0  Success (pfSense LAN reachable).
  1  Preflight failure (missing dependencies, paths, or VM issues).
  2  ECL applied but pfSense LAN not reachable (debug via console).
  3  Fatal error while mutating the VM or performing rollback.
USAGE
}

# shellcheck disable=SC2317
on_error() {
  local exit_code=$?
  local line=0
  if [[ ${#BASH_LINENO[@]} -gt 0 ]]; then
    line=${BASH_LINENO[0]}
  fi
  log_error "Command failed with exit ${exit_code} at line ${line}: ${BASH_COMMAND}"
  exit "${exit_code}"
}

install_error_trap() {
  trap on_error ERR
}

setup_tmp_dir() {
  if [[ -n ${TMP_DIR} ]]; then
    return
  fi
  TMP_DIR="$(mktemp -d)"
  trap_add cleanup_tmp EXIT INT TERM
}

# shellcheck disable=SC2317
cleanup_tmp() {
  if [[ -n ${USB_MOUNT_DIR} ]]; then
    if mountpoint -q "${USB_MOUNT_DIR}" >/dev/null 2>&1; then
      umount "${USB_MOUNT_DIR}" >/dev/null 2>&1 || true
    fi
    rmdir "${USB_MOUNT_DIR}" >/dev/null 2>&1 || true
    USB_MOUNT_DIR=""
  fi
  if [[ -n ${TMP_DIR} && -d ${TMP_DIR} ]]; then
    rm -rf -- "${TMP_DIR}" >/dev/null 2>&1 || true
    TMP_DIR=""
  fi
}

get_lan_link_kind() {
  local link="${PF_LAN_LINK:-}"
  if [[ -z ${link} && -n ${PF_LAN_BRIDGE} ]]; then
    printf "%s" "bridge"
    return 0
  fi
  if [[ -z ${link} ]]; then
    printf "%s" "bridge"
    return 0
  fi
  printf "%s" "${link%%:*}"
}

get_lan_link_name() {
  local link="${PF_LAN_LINK:-}"
  if [[ -z ${link} && -n ${PF_LAN_BRIDGE} ]]; then
    printf "%s" "${PF_LAN_BRIDGE}"
    return 0
  fi
  if [[ -z ${link} ]]; then
    printf "%s" "virbr-lan"
    return 0
  fi
  if [[ ${link} == *:* ]]; then
    printf "%s" "${link#*:}"
  else
    printf "%s" "${link}"
  fi
}

resolve_network_bridge() {
  pf_lan_resolve_network_bridge "$@"
}

setup_logging() {
  local log_dir
  log_dir="$(dirname "${LOG_FILE}")"

  if [[ ! -d ${log_dir} ]]; then
    mkdir -p "${log_dir}" || {
      log_warn "Unable to create log directory ${log_dir}; falling back to stderr"
      return
    }
  fi

  if [[ -w ${log_dir} || ( -e ${LOG_FILE} && -w ${LOG_FILE} ) ]]; then
    exec > >(tee -a "${LOG_FILE}")
    exec 2>&1
    log_info "Logging to ${LOG_FILE}"
  else
    log_warn "Insufficient permissions to write ${LOG_FILE}; continuing without file logging"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_PREFLIGHT} "--env-file requires a path"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --vm-name)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_PREFLIGHT} "--vm-name requires a value"
        fi
        VM_NAME_ARG="$2"
        shift 2
        ;;
      --force-e1000)
        FORCE_E1000=true
        shift
        ;;
      --force)
        FORCE_REBUILD=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --check-only)
        CHECK_ONLY=true
        DRY_RUN=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --lenient)
        LENIENT=true
        shift
        ;;
      --rollback)
        ROLLBACK=true
        shift
        ;;
      -h|--help)
        usage
        exit ${EX_SUCCESS}
        ;;
      --)
        shift
        break
        ;;
      -* )
        usage
        die ${EX_PREFLIGHT} "Unknown option: $1"
        ;;
      * )
        usage
        die ${EX_PREFLIGHT} "Unexpected positional argument: $1"
        ;;
    esac
  done

  if [[ ${ROLLBACK} == true && ${CHECK_ONLY} == true ]]; then
    die ${EX_PREFLIGHT} "--rollback cannot be combined with --check-only"
  fi
  if [[ ${ROLLBACK} == true && ${DRY_RUN} == true ]]; then
    die ${EX_PREFLIGHT} "--rollback cannot be combined with --dry-run"
  fi
}

load_env_file() {
  local candidates=()
  if [[ -n ${ENV_FILE} ]]; then
    candidates=("${ENV_FILE}")
  else
    candidates=(
      "${REPO_ROOT}/.env"
      "${PWD}/.env"
      "/opt/homelab/.env"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      set +u
      set -a
      # shellcheck disable=SC1090
      source "${candidate}"
      set +a
      set -u
      return
    fi
  done

  log_warn "No environment file found; continuing with shell environment"
}

ensure_required_env() {
  LAN_CIDR=${LAN_CIDR:-10.10.0.0/24}
  LAN_GW_IP=${LAN_GW_IP:-10.10.0.1}

  if [[ -z ${DHCP_FROM:-} && -n ${LAN_DHCP_FROM:-} ]]; then
    DHCP_FROM=${LAN_DHCP_FROM}
  fi
  if [[ -z ${DHCP_TO:-} && -n ${LAN_DHCP_TO:-} ]]; then
    DHCP_TO=${LAN_DHCP_TO}
  fi

  DHCP_FROM=${DHCP_FROM:-10.10.0.100}
  DHCP_TO=${DHCP_TO:-10.10.0.200}

  compute_lan_settings
}

compute_lan_settings() {
  local python_output
  python_output=$(python3 - <<'PY'
import ipaddress
import os
import sys

lan_cidr = os.environ.get("LAN_CIDR", "10.10.0.0/24")
gw_ip = os.environ.get("LAN_GW_IP", "10.10.0.1").strip()
dhcp_from = os.environ.get("DHCP_FROM", "").strip()
dhcp_to = os.environ.get("DHCP_TO", "").strip()

try:
    network = ipaddress.ip_network(lan_cidr, strict=False)
except ValueError as exc:
    print(f"Invalid LAN_CIDR: {exc}", file=sys.stderr)
    sys.exit(1)

if network.version != 4:
    print("LAN_CIDR must be IPv4", file=sys.stderr)
    sys.exit(1)

def validate_host(label, value, allow_empty=False):
    if not value:
        if allow_empty:
            return None
        print(f"{label} is required", file=sys.stderr)
        sys.exit(1)
    try:
        candidate = ipaddress.ip_address(value)
    except ValueError as exc:
        print(f"{label} invalid: {exc}", file=sys.stderr)
        sys.exit(1)
    if candidate.version != 4:
        print(f"{label} must be IPv4", file=sys.stderr)
        sys.exit(1)
    if candidate not in network:
        print(f"{label}={value} is outside {network.with_prefixlen}", file=sys.stderr)
        sys.exit(1)
    if candidate == network.network_address or candidate == network.broadcast_address:
        print(f"{label}={value} cannot be the network/broadcast address", file=sys.stderr)
        sys.exit(1)
    return candidate

gateway = validate_host("LAN_GW_IP", gw_ip)

dhcp_start = validate_host("DHCP_FROM", dhcp_from, allow_empty=True)
dhcp_end = validate_host("DHCP_TO", dhcp_to, allow_empty=True)

hosts = list(network.hosts())
if not hosts:
    print(f"LAN_CIDR {network.with_prefixlen} has no usable hosts", file=sys.stderr)
    sys.exit(1)

def default_range_start():
    candidate = network.network_address + 99
    if candidate <= network.network_address:
        candidate = hosts[0]
    if candidate >= network.broadcast_address:
        candidate = hosts[-1]
    return candidate

def default_range_end():
    candidate = network.network_address + 199
    if candidate <= network.network_address:
        candidate = hosts[0]
    if candidate >= network.broadcast_address:
        candidate = hosts[-1]
    return candidate

if dhcp_start is None:
    dhcp_start = default_range_start()
if dhcp_end is None:
    dhcp_end = default_range_end()

if dhcp_start > dhcp_end:
    print(f"DHCP_FROM ({dhcp_start}) exceeds DHCP_TO ({dhcp_end})", file=sys.stderr)
    sys.exit(1)

def pick_probe():
    preferred = [
        host for host in hosts
        if host != gateway and host != dhcp_start and host != dhcp_end
    ]
    if preferred:
        return preferred[0]
    for host in hosts:
        if host != gateway:
            return host
    return hosts[0]

probe = pick_probe()

print(f"LAN_PREFIX={network.prefixlen}")
print(f"LAN_NETWORK={network.network_address}")
print(f"LAN_NETMASK={network.netmask}")
print(f"LAN_GW_IP={gateway}")
print(f"DHCP_FROM={dhcp_start}")
print(f"DHCP_TO={dhcp_end}")
print(f"LAN_PROBE_IP={probe}")
PY
  ) || die ${EX_PREFLIGHT} "Failed to derive LAN network settings"

  eval "${python_output}"
  LAN_VALIDATION_IP=${LAN_VALIDATION_IP:-${LAN_PROBE_IP}}

  export LAN_PREFIX LAN_NETWORK LAN_NETMASK LAN_GW_IP DHCP_FROM DHCP_TO LAN_PROBE_IP LAN_VALIDATION_IP
  log_debug "Derived LAN network=${LAN_NETWORK}/${LAN_PREFIX} gateway=${LAN_GW_IP} DHCP=${DHCP_FROM}-${DHCP_TO} probe=${LAN_VALIDATION_IP}"
}

ensure_vm_name() {
  if [[ -n ${VM_NAME_ARG} ]]; then
    VM_NAME="${VM_NAME_ARG}"
  fi
  if [[ -z ${VM_NAME:-} && -n ${PF_VM_NAME:-} ]]; then
    VM_NAME="${PF_VM_NAME}"
  fi
  if [[ -z ${VM_NAME:-} ]]; then
    die ${EX_PREFLIGHT} "--vm-name is required when VM_NAME is not set in the environment"
  fi
}

json_extract() {
  local expr=$1
  python3 - "$expr" <<'PY'
import json
import os
import sys

expr = sys.argv[1]
raw = os.environ.get("DOMAIN_INFO_JSON", "")
if not raw:
    print("", end="")
    sys.exit(0)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("", end="")
    sys.exit(0)

tokens = []
i = 0
while i < len(expr):
    ch = expr[i]
    if ch == '.':
        i += 1
        continue
    if ch == '[':
        j = expr.find(']', i)
        if j == -1:
            tokens = []
            break
        tokens.append(int(expr[i + 1:j]))
        i = j + 1
        continue
    j = i
    while j < len(expr) and expr[j] not in '.[':
        j += 1
    tokens.append(expr[i:j])
    i = j

obj = data
for token in tokens:
    if isinstance(token, int):
        if not isinstance(obj, list) or token >= len(obj):
            obj = None
            break
        obj = obj[token]
    else:
        if not isinstance(obj, dict) or token not in obj:
            obj = None
            break
        obj = obj[token]

if obj is None:
    print("", end="")
elif isinstance(obj, bool):
    print("true" if obj else "false")
else:
    print(obj)
PY
}

fetch_domain_info() {
  setup_tmp_dir
  local domain_tmp
  domain_tmp="${TMP_DIR}/${VM_NAME}-domain.xml"
  if ! virsh dumpxml "${VM_NAME}" >"${domain_tmp}"; then
    die ${EX_PREFLIGHT} "Failed to dump domain XML for ${VM_NAME}"
  fi
  DOMAIN_XML_PATH="${domain_tmp}"
  DOMAIN_INFO_JSON=$(python3 - "${domain_tmp}" "${USB_IMAGE}" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
image_path = sys.argv[2]
tree = ET.parse(path)
root = tree.getroot()
info = {}
info["usb_controller_present"] = any(
    ctrl.get("type") == "usb" for ctrl in root.findall("./devices/controller")
)
usb_disk = {
    "attached": False,
    "target": None,
    "readonly": False,
}
for disk in root.findall("./devices/disk"):
    if disk.get("device") != "disk":
        continue
    source = disk.find("source")
    if source is None:
        continue
    if source.get("file") == image_path:
        usb_disk["attached"] = True
        target = disk.find("target")
        if target is not None:
            usb_disk["target"] = target.get("dev")
        driver = disk.find("driver")
        if disk.find("readonly") is not None:
            usb_disk["readonly"] = True
        elif driver is not None and driver.get("readonly") == "yes":
            usb_disk["readonly"] = True
        break
info["usb_disk"] = usb_disk
interfaces = []
for iface in root.findall("./devices/interface"):
    entry = {
        "type": iface.get("type"),
        "kind": iface.get("type"),
        "target": None,
        "bridge": None,
        "source": None,
        "model": None,
        "mac": None,
        "alias": None,
    }
    target = iface.find("target")
    if target is not None:
        entry["target"] = target.get("dev")
    source = iface.find("source")
    if source is not None:
        bridge_name = source.get("bridge")
        network_name = source.get("network")
        dev_name = source.get("dev")
        if bridge_name is not None:
            entry["kind"] = "bridge"
            entry["bridge"] = bridge_name
            entry["source"] = bridge_name
        elif network_name is not None:
            entry["kind"] = "network"
            entry["source"] = network_name
        elif dev_name is not None:
            entry["kind"] = "device"
            entry["source"] = dev_name
    model = iface.find("model")
    if model is not None:
        entry["model"] = model.get("type")
    mac = iface.find("mac")
    if mac is not None:
        entry["mac"] = mac.get("address")
    alias = iface.find("alias")
    if alias is not None:
        entry["alias"] = alias.get("name")
    interfaces.append(entry)
info["interfaces"] = interfaces
print(json.dumps(info))
PY
  )
  export DOMAIN_INFO_JSON
}

capture_domain_state() {
  local state
  if ! state=$(virsh domstate "${VM_NAME}" 2>/dev/null); then
    die ${EX_PREFLIGHT} "Failed to determine domain state for ${VM_NAME}"
  fi
  DOMAIN_STATE="${state}"
  log_debug "Domain ${VM_NAME} state: ${DOMAIN_STATE}"
}

ensure_domain_started_if_needed() {
  if [[ ${DOMAIN_STATE} != "shut off" && ${DOMAIN_STATE} != "pmsuspended" ]]; then
    return
  fi

  local state_message
  state_message="${VM_NAME} is ${DOMAIN_STATE}"

  if [[ ${CHECK_ONLY} == true ]]; then
    log_info "[CHECK-ONLY] ${state_message}; automatic start skipped"
    return
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] ${state_message}; automatic start skipped"
    return
  fi

  log_info "${state_message}; starting domain"
  if ! virsh start "${VM_NAME}" >/dev/null; then
    die ${EX_FATAL} "Unable to start ${VM_NAME}"
  fi
  VM_AUTO_STARTED=true
  capture_domain_state
  log_info "Started ${VM_NAME}"
}

backup_domain_xml() {
  setup_tmp_dir
  local backup_dir="${CONFIG_ROOT}/backups"
  local timestamp
  timestamp="$(date +%Y%m%d%H%M%S)"
  local archive_path="${backup_dir}/${VM_NAME}-domain-${timestamp}.xml"
  DOMAIN_BACKUP_FILE="${backup_dir}/${VM_NAME}-domain.xml.bak"
  if [[ ${DOMAIN_BACKUP_CREATED} == true ]]; then
    log_debug "Domain XML already backed up at ${DOMAIN_BACKUP_FILE}"
    return
  fi
  DOMAIN_BACKUP_CREATED=true
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would back up domain XML to ${archive_path}"
    return
  fi
  mkdir -p "${backup_dir}"
  cp "${DOMAIN_XML_PATH}" "${archive_path}"
  cp "${DOMAIN_XML_PATH}" "${DOMAIN_BACKUP_FILE}"
  log_info "Domain XML backed up to ${archive_path} (latest: ${DOMAIN_BACKUP_FILE})"
}

restore_domain_backup() {
  local backup_dir="${CONFIG_ROOT}/backups"
  local pointer="${backup_dir}/${VM_NAME}-domain.xml.bak"
  if [[ ! -f ${pointer} ]]; then
    die ${EX_FATAL} "No domain XML backup found at ${pointer}"
  fi
  local disk_attached
  disk_attached=$(json_extract "usb_disk.attached")
  local disk_target
  disk_target=$(json_extract "usb_disk.target")
  if [[ ${disk_attached} == true && -n ${disk_target} ]]; then
    log_info "Detaching USB image ${disk_target} from running domain"
    virsh detach-disk "${VM_NAME}" "${disk_target}" --config --live >/dev/null || log_warn "Unable to detach USB disk ${disk_target}; manual cleanup may be required"
  fi
  log_info "Restoring domain XML for ${VM_NAME} from ${pointer}"
  if ! virsh define "${pointer}" >/dev/null; then
    die ${EX_FATAL} "Failed to restore domain definition from ${pointer}"
  fi
  log_info "Rollback complete"
}

update_config_xml() {
  if [[ ! -f ${CONFIG_XML} ]]; then
    log_error "pfSense config not found at ${CONFIG_XML}"
    DRIFT_DETECTED=true
    if [[ ${CHECK_ONLY} == true ]]; then
      return 1
    fi
    if [[ ${DRY_RUN} == true ]]; then
      return 1
    fi
    die ${EX_PREFLIGHT} "Cannot continue without ${CONFIG_XML}"
  fi

  local mode
  if [[ ${CHECK_ONLY} == true || ${DRY_RUN} == true ]]; then
    mode="check"
  else
    mode="commit"
  fi

  local result
  result=$(python3 - "${CONFIG_XML}" "${LAN_GW_IP}" "${LAN_PREFIX}" "${DHCP_FROM}" "${DHCP_TO}" "${mode}" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

config_path, gw_ip, subnet_bits, dhcp_from, dhcp_to, mode = sys.argv[1:7]
commit = mode == "commit"

try:
    tree = ET.parse(config_path)
except FileNotFoundError:
    print("status=missing")
    sys.exit(0)

root = tree.getroot()
lan = root.find("./interfaces/lan")
if lan is None:
    print("error=missing_lan")
    sys.exit(1)

changed = False
actions = {
    "ipaddr": "skipped",
    "subnet": "skipped",
    "dhcp_from": "skipped",
    "dhcp_to": "skipped",
}

ipaddr = lan.find("ipaddr")
if ipaddr is None:
    ipaddr = ET.SubElement(lan, "ipaddr")
current_ip = (ipaddr.text or "").strip()
if not current_ip:
    ipaddr.text = gw_ip
    changed = True
    actions["ipaddr"] = "set"
elif current_ip == gw_ip:
    actions["ipaddr"] = "match"
else:
    actions["ipaddr"] = f"existing:{current_ip}"

subnet = lan.find("subnet")
if subnet is None:
    subnet = ET.SubElement(lan, "subnet")
current_subnet = (subnet.text or "").strip()
if current_subnet != subnet_bits:
    subnet.text = subnet_bits
    changed = True
    actions["subnet"] = "updated"
else:
    actions["subnet"] = "match"

dhcp_root = root.find("./dhcpd")
if dhcp_root is None:
    dhcp_root = ET.SubElement(root, "dhcpd")
lan_dhcp = dhcp_root.find("lan")
if lan_dhcp is None:
    lan_dhcp = ET.SubElement(dhcp_root, "lan")
range_elem = lan_dhcp.find("range")
if range_elem is None:
    range_elem = ET.SubElement(lan_dhcp, "range")

from_elem = range_elem.find("from")
if from_elem is None:
    from_elem = ET.SubElement(range_elem, "from")
current_from = (from_elem.text or "").strip()
if not current_from:
    from_elem.text = dhcp_from
    changed = True
    actions["dhcp_from"] = "set"
elif current_from == dhcp_from:
    actions["dhcp_from"] = "match"
else:
    actions["dhcp_from"] = f"existing:{current_from}"

to_elem = range_elem.find("to")
if to_elem is None:
    to_elem = ET.SubElement(range_elem, "to")
current_to = (to_elem.text or "").strip()
if not current_to:
    to_elem.text = dhcp_to
    changed = True
    actions["dhcp_to"] = "set"
elif current_to == dhcp_to:
    actions["dhcp_to"] = "match"
else:
    actions["dhcp_to"] = f"existing:{current_to}"

if changed and commit:
    tmp_path = f"{config_path}.tmp"
    tree.write(tmp_path, encoding="utf-8", xml_declaration=True)
    os.replace(tmp_path, config_path)

print(f"changed={'true' if changed else 'false'}")
for key, value in actions.items():
    print(f"{key}={value}")
PY
  ) || die ${EX_PREFLIGHT} "Failed to inspect ${CONFIG_XML}"

  local changed_flag="false"
  local ip_action=""
  local dhcp_from_action=""
  local dhcp_to_action=""
  local status_value=""
  local error_value=""

  while IFS='=' read -r key value; do
    case "${key}" in
      changed)
        changed_flag=${value}
        ;;
      status)
        status_value=${value}
        ;;
      error)
        error_value=${value}
        ;;
      ipaddr)
        ip_action=${value}
        ;;
      dhcp_from)
        dhcp_from_action=${value}
        ;;
      dhcp_to)
        dhcp_to_action=${value}
        ;;
    esac
  done <<<"${result}"

  if [[ ${status_value} == "missing" ]]; then
    die ${EX_PREFLIGHT} "config.xml disappeared during processing"
  fi
  if [[ ${error_value} == "missing_lan" ]]; then
    die ${EX_PREFLIGHT} "config.xml missing <interfaces><lan> definition"
  fi

  if [[ ${changed_flag} == "true" ]]; then
    CONFIG_CHANGED=true
    if [[ ${CHECK_ONLY} == true ]]; then
      DRIFT_DETECTED=true
    fi
    log_info "Aligned ${CONFIG_XML} LAN gateway ${LAN_GW_IP}, /${LAN_PREFIX}, DHCP ${DHCP_FROM}-${DHCP_TO}"
  else
    log_debug "${CONFIG_XML} already matches requested LAN settings"
  fi

  if [[ ${ip_action} == existing:* ]]; then
    log_warn "LAN IP already populated (${ip_action#existing:}); leaving as-is"
  fi
  if [[ ${dhcp_from_action} == existing:* ]]; then
    log_warn "DHCP range start already populated (${dhcp_from_action#existing:}); leaving as-is"
  fi
  if [[ ${dhcp_to_action} == existing:* ]]; then
    log_warn "DHCP range end already populated (${dhcp_to_action#existing:}); leaving as-is"
  fi
}

select_mkfs_command() {
  if command -v mkfs.vfat >/dev/null 2>&1; then
    command -v mkfs.vfat
    return 0
  fi
  if command -v mkfs.fat >/dev/null 2>&1; then
    command -v mkfs.fat
    return 0
  fi
  return 1
}

build_usb_image() {
  local mkfs_cmd
  if ! mkfs_cmd=$(select_mkfs_command); then
    die ${EX_PREFLIGHT} "mkfs.vfat or mkfs.fat is required to build the USB image"
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would create ${USB_IMAGE} with label ${USB_LABEL}"
    return
  fi

  mkdir -p "${CONFIG_ROOT}"
  if command -v truncate >/dev/null 2>&1; then
    truncate -s "${USB_SIZE_MIB}M" "${USB_IMAGE}.tmp"
  else
    dd if=/dev/zero of="${USB_IMAGE}.tmp" bs=1M count=${USB_SIZE_MIB} status=none
  fi
  ${mkfs_cmd} -F 32 -n "${USB_LABEL}" "${USB_IMAGE}.tmp" >/dev/null
  USB_MOUNT_DIR="$(mktemp -d)"
  mount -o loop "${USB_IMAGE}.tmp" "${USB_MOUNT_DIR}"
  mkdir -p "${USB_MOUNT_DIR}/config"
  cp "${CONFIG_XML}" "${USB_MOUNT_DIR}/config/config.xml"
  sync
  umount "${USB_MOUNT_DIR}"
  rmdir "${USB_MOUNT_DIR}"
  USB_MOUNT_DIR=""
  mv "${USB_IMAGE}.tmp" "${USB_IMAGE}"
  IMAGE_REBUILT=true
  log_info "Rebuilt ${USB_IMAGE} with updated config.xml"
}

ensure_usb_image() {
  local needs_rebuild=false
  if [[ ! -f ${USB_IMAGE} ]]; then
    log_info "USB bootstrap image ${USB_IMAGE} missing"
    needs_rebuild=true
  elif [[ ${CONFIG_CHANGED} == true ]]; then
    needs_rebuild=true
  elif [[ ${CONFIG_XML} -nt ${USB_IMAGE} ]]; then
    log_info "${USB_IMAGE} older than ${CONFIG_XML}; scheduling rebuild"
    needs_rebuild=true
  elif [[ ${FORCE_REBUILD} == true ]]; then
    log_info "--force requested; scheduling USB image rebuild"
    needs_rebuild=true
  fi

  if [[ ${needs_rebuild} == true ]]; then
    if [[ ${CHECK_ONLY} == true ]]; then
      DRIFT_DETECTED=true
      log_info "[CHECK-ONLY] USB image would be rebuilt"
      return
    fi
    build_usb_image
  else
    log_debug "Reusing existing USB image ${USB_IMAGE}"
  fi
}

ensure_usb_controller() {
  local present
  present=$(json_extract "usb_controller_present")
  if [[ ${present} == true ]]; then
    log_debug "USB controller already defined for ${VM_NAME}"
    return
  fi
  if [[ ${CHECK_ONLY} == true ]]; then
    DRIFT_DETECTED=true
    log_warn "[CHECK-ONLY] USB controller missing"
    return
  fi
  backup_domain_xml
  USB_CONTROLLER_ADDED=true
  local controller_xml
  controller_xml="${TMP_DIR}/usb-controller.xml"
  cat >"${controller_xml}" <<'XML'
<controller type='usb' model='qemu-xhci'/>
XML
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would attach USB controller to ${VM_NAME}"
    return
  fi
  if ! virsh attach-device "${VM_NAME}" "${controller_xml}" --live --config >/dev/null; then
    die ${EX_FATAL} "Failed to attach USB controller to ${VM_NAME}"
  fi
  log_info "Attached USB controller to ${VM_NAME}"
}

ensure_usb_disk_attachment() {
  local attached
  attached=$(json_extract "usb_disk.attached")
  if [[ ${attached} == true ]]; then
    USB_PRESENT=true
    local readonly_flag
    readonly_flag=$(json_extract "usb_disk.readonly")
    if [[ ${readonly_flag} != true ]]; then
      log_warn "USB disk is attached but not read-only"
      if [[ ${CHECK_ONLY} == true ]]; then
        DRIFT_DETECTED=true
      fi
    else
      log_debug "USB image already attached to ${VM_NAME}"
    fi
    return
  fi
  if [[ ${CHECK_ONLY} == true ]]; then
    DRIFT_DETECTED=true
    log_warn "[CHECK-ONLY] USB bootstrap disk not attached"
    return
  fi
  backup_domain_xml
  USB_DISK_ATTACHED=true
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would attach ${USB_IMAGE} as USB disk"
    return
  fi
  if virsh attach-disk "${VM_NAME}" "${USB_IMAGE}" sdz --targetbus usb --mode readonly --config --live >/dev/null 2>&1; then
    log_info "Attached ${USB_IMAGE} to ${VM_NAME} via virsh attach-disk"
    USB_PRESENT=true
    return
  fi
  log_warn "virsh attach-disk failed; falling back to attach-device"
  local disk_xml
  disk_xml="${TMP_DIR}/usb-disk.xml"
  cat >"${disk_xml}" <<XML
<disk type='file' device='disk'>
  <driver name='qemu' type='raw' cache='none'/>
  <source file='${USB_IMAGE}'/>
  <target dev='sdz' bus='usb'/>
  <readonly/>
  <shareable/>
</disk>
XML
  if ! virsh attach-device "${VM_NAME}" "${disk_xml}" --live --config >/dev/null; then
    die ${EX_FATAL} "Failed to attach USB disk image to ${VM_NAME}"
  fi
  log_info "Attached ${USB_IMAGE} to ${VM_NAME} via attach-device"
  USB_PRESENT=true
}

update_interface_model() {
  local target=$1
  local bridge=$2
  local snippet="${TMP_DIR}/iface-${target}.xml"

  if [[ ${DOMAIN_STATE} != "shut off" && ${DOMAIN_STATE} != "pmsuspended" ]]; then
    log_warn "Skipping NIC model change for ${target:-unknown}; ${VM_NAME} is ${DOMAIN_STATE}. Shutdown required for model switch."
    DRIFT_DETECTED=true
    return 1
  fi

  python3 - "${DOMAIN_XML_PATH}" "${target}" "${snippet}" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, target_dev, output = sys.argv[1:4]
tree = ET.parse(path)
root = tree.getroot()
for iface in root.findall("./devices/interface"):
    target = iface.find("target")
    if target is not None and target.get("dev") == target_dev:
        model = iface.find("model")
        if model is None:
            model = ET.SubElement(iface, "model")
        model.set("type", "e1000")
        xml_str = ET.tostring(iface, encoding="unicode")
        with open(output, "w", encoding="utf-8") as fh:
            fh.write(xml_str)
        break
else:
    with open(output, "w", encoding="utf-8") as fh:
        fh.write("")
PY
  if [[ ! -s ${snippet} ]]; then
    log_warn "Unable to prepare interface XML for ${target}; skipping"
    return 1
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would set NIC ${target} (${bridge}) model to e1000"
    return 0
  fi
  if ! virsh update-device "${VM_NAME}" "${snippet}" --live --config >/dev/null; then
    die ${EX_FATAL} "Failed to update NIC ${target} to e1000"
  fi
  log_info "Updated NIC ${target} (${bridge}) to e1000"
  return 0
}

rewire_lan_interface() {
  local idx="$1"
  local kind="$2"
  local name="$3"

  if [[ -z ${kind} || -z ${name} ]]; then
    log_error "rewire_lan_interface requires kind and name"
    return 1
  fi

  local target=""
  local mac=""
  local detach_type=""
  local domain_active=false

  if [[ -n ${DOMAIN_STATE} && ${DOMAIN_STATE} != "shut off" && ${DOMAIN_STATE} != "pmsuspended" ]]; then
    domain_active=true
  fi

  if [[ -n ${idx} ]]; then
    target=$(json_extract "interfaces[${idx}].target")
    mac=$(json_extract "interfaces[${idx}].mac")
    detach_type=$(json_extract "interfaces[${idx}].type")
  fi

  if [[ -z ${target} ]]; then
    target="vnet1"
  fi

  if [[ -z ${mac} ]]; then
    mac=$(json_extract "interfaces[1].mac")
  fi

  backup_domain_xml

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would detach ${target:-LAN?} and attach ${kind}:${name}"
    return 0
  fi

  local -a detach_flags=()
  local -a attach_flags=()

  if [[ ${domain_active} == true ]]; then
    detach_flags+=("--live")
    attach_flags+=("--live")
  fi

  detach_flags+=("--config")
  attach_flags+=("--config")

  local detached=false
  local -a candidate_types=()
  if [[ -n ${detach_type} ]]; then
    candidate_types+=("${detach_type}")
  fi
  candidate_types+=("bridge" "network")

  for dtype in "${candidate_types[@]}"; do
    if [[ -z ${dtype} ]]; then
      continue
    fi
    local -a detach_cmd=(virsh detach-interface "${VM_NAME}" --type "${dtype}")
    detach_cmd+=("${detach_flags[@]}")
    if [[ -n ${mac} ]]; then
      detach_cmd+=("--mac" "${mac}")
    fi
    if "${detach_cmd[@]}" >/dev/null 2>&1; then
      detached=true
      break
    fi
  done

  if [[ ${detached} != true ]]; then
    log_warn "Unable to confirm detaching existing LAN interface; continuing"
  fi

  local force=false
  if [[ ${FORCE_E1000} == true || ${PF_FORCE_E1000} == "true" ]]; then
    force=true
  fi

  local -a attach_cmd=(virsh attach-interface "${VM_NAME}")
  if [[ ${kind} == "bridge" ]]; then
    attach_cmd+=("bridge" "${name}")
  else
    attach_cmd+=("network" "${name}")
  fi
  if [[ ${force} == true ]]; then
    attach_cmd+=("--model" "e1000")
  fi
  if [[ -n ${mac} ]]; then
    attach_cmd+=("--mac" "${mac}")
  fi
  attach_cmd+=("${attach_flags[@]}")

  if ! "${attach_cmd[@]}" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

inspect_interfaces() {
  LAN_LINK_KIND="$(get_lan_link_kind)"
  LAN_LINK_NAME="$(get_lan_link_name)"

  local idx=0
  local detected_wan_source=""
  local detected_wan_kind=""
  local detected_lan_source=""
  local detected_lan_kind=""
  local detected_lan_idx=""
  local first_source=""
  local first_kind=""
  local first_target=""

  while true; do
    local target
    target=$(json_extract "interfaces[${idx}].target")
    local kind
    kind=$(json_extract "interfaces[${idx}].kind")
    local source
    source=$(json_extract "interfaces[${idx}].source")
    local model
    model=$(json_extract "interfaces[${idx}].model")
    local alias
    alias=$(json_extract "interfaces[${idx}].alias")

    if [[ -z ${target} && -z ${kind} && -z ${source} && -z ${alias} ]]; then
      break
    fi

    if [[ -z ${kind} ]]; then
      kind=$(json_extract "interfaces[${idx}].type")
    fi

    if [[ -z ${first_source} && -n ${source} ]]; then
      first_source=${source}
      first_kind=${kind}
      first_target=${target}
    fi

    case "${target}" in
      vnet0)
        if [[ -n ${PF_WAN_BRIDGE} && -n ${source} && ${source} != "${PF_WAN_BRIDGE}" ]]; then
          log_warn "Interface ${target} linked to ${source:-unknown}; expected ${PF_WAN_BRIDGE}"
        fi
        if [[ -z ${detected_wan_source} && -n ${source} ]]; then
          detected_wan_source=${source}
          detected_wan_kind=${kind}
        fi
        ;;
      vnet1)
        if [[ -z ${detected_lan_source} && -n ${source} ]]; then
          detected_lan_source=${source}
          detected_lan_kind=${kind}
          detected_lan_idx=${idx}
        fi
        ;;
    esac

    local force="${FORCE_E1000}"
    if [[ ${PF_FORCE_E1000} == "true" ]]; then
      force=true
    fi

    if [[ ${force} == true && ${model} != "e1000" ]]; then
      if [[ ${CHECK_ONLY} == true ]]; then
        DRIFT_DETECTED=true
        log_warn "[CHECK-ONLY] NIC ${target:-idx ${idx}} is ${model:-unknown}; would change to e1000"
      else
        backup_domain_xml
        if update_interface_model "${target}" "${source}"; then
          NIC_MODEL_CHANGED=true
        fi
      fi
    fi

    ((++idx))
  done

  if [[ -z ${PF_WAN_BRIDGE} && -n ${detected_wan_source} ]]; then
    PF_WAN_BRIDGE=${detected_wan_source}
    log_info "Auto-detected WAN link ${PF_WAN_BRIDGE} (${detected_wan_kind:-unknown}) for ${VM_NAME}"
  fi

  local actual_lan_kind="${detected_lan_kind:-${first_kind}}"
  local actual_lan_source="${detected_lan_source:-${first_source}}"
  local lan_idx="${detected_lan_idx:-}"

  if [[ -z ${lan_idx} && -n ${actual_lan_source} ]]; then
    lan_idx=0
  fi

  local wanted_desc="${LAN_LINK_KIND}:${LAN_LINK_NAME}"
  local actual_desc="${actual_lan_kind:-unknown}:${actual_lan_source:-unknown}"
  local wired_ok=false
  if [[ -n ${actual_lan_source} && -n ${LAN_LINK_NAME} ]]; then
    if [[ ${LAN_LINK_KIND} == "bridge" && ${actual_lan_kind} == "bridge" && ${actual_lan_source} == "${LAN_LINK_NAME}" ]]; then
      wired_ok=true
    elif [[ ${LAN_LINK_KIND} == "network" && ${actual_lan_kind} == "network" && ${actual_lan_source} == "${LAN_LINK_NAME}" ]]; then
      wired_ok=true
    fi
  fi

  if [[ ${wired_ok} != true ]]; then
    if [[ ${CHECK_ONLY} == true ]]; then
      DRIFT_DETECTED=true
      log_warn "[CHECK-ONLY] LAN interface on ${actual_desc}; would rewire to ${wanted_desc}"
    elif [[ ${DRY_RUN} == true ]]; then
      log_warn "[DRY-RUN] LAN interface on ${actual_desc}; would rewire to ${wanted_desc}"
    else
      if rewire_lan_interface "${lan_idx}" "${LAN_LINK_KIND}" "${LAN_LINK_NAME}"; then
        LAN_INTERFACE_REWIRED=true
        if [[ ${FORCE_E1000} == true || ${PF_FORCE_E1000} == "true" ]]; then
          NIC_MODEL_CHANGED=true
        fi
        detected_lan_kind=${LAN_LINK_KIND}
        detected_lan_source=${LAN_LINK_NAME}
        actual_lan_kind=${LAN_LINK_KIND}
        actual_lan_source=${LAN_LINK_NAME}
        log_info "LAN interface rewired to ${wanted_desc}"
      else
        log_error "Failed to rewire LAN interface to ${wanted_desc}"
      fi
    fi
  fi

  if [[ ${LAN_LINK_KIND} == "bridge" ]]; then
    PF_LAN_BRIDGE=${LAN_LINK_NAME}
  fi

  if [[ ${LAN_LINK_KIND} == "network" && -z ${PF_LAN_BRIDGE} ]]; then
    local resolved_bridge=""
    if resolved_bridge=$(resolve_network_bridge "${LAN_LINK_NAME}"); then
      if [[ -n ${resolved_bridge} ]]; then
        PF_LAN_BRIDGE=${resolved_bridge}
        log_info "Resolved network ${LAN_LINK_NAME} to host bridge ${PF_LAN_BRIDGE}"
      fi
    fi
  fi

  if [[ -z ${PF_LAN_BRIDGE} && ${actual_lan_kind} == "bridge" && -n ${actual_lan_source} ]]; then
    PF_LAN_BRIDGE=${actual_lan_source}
    log_info "Auto-detected LAN bridge ${PF_LAN_BRIDGE} for ${VM_NAME}"
  fi

  if [[ -z ${PF_LAN_BRIDGE} && -n ${first_source} ]]; then
    PF_LAN_BRIDGE=${first_source}
    log_warn "Falling back to bridge ${PF_LAN_BRIDGE} (interface ${first_target:-unknown}) for LAN operations"
  fi

  if [[ -z ${PF_WAN_BRIDGE} ]]; then
    PF_WAN_BRIDGE=${detected_wan_source:-${first_source:-br0}}
  fi
}

register_bridge_temp_cidr() {
  local cidr=${1:-}
  if [[ -z ${cidr} ]]; then
    return 1
  fi

  BRIDGE_IP_TEMP_ADDED=true

  local existing
  for existing in "${BRIDGE_TEMP_CIDRS[@]}"; do
    if [[ ${existing} == "${cidr}" ]]; then
      return 0
    fi
  done

  BRIDGE_TEMP_CIDRS+=("${cidr}")
  return 0
}

ensure_bridge_cleanup_trap() {
  if [[ ${BRIDGE_CLEANUP_TRAP_INSTALLED} == true ]]; then
    return
  fi
  trap_add cleanup_bridge_ip EXIT INT TERM
  BRIDGE_CLEANUP_TRAP_INSTALLED=true
}

ensure_bridge_ipv4() {
  if [[ ${CHECK_ONLY} == true || ${DRY_RUN} == true ]]; then
    log_debug "Skipping host bridge IP assignment in dry-run/check mode"
    pf_lan_temp_addr_reset
    BRIDGE_IP_TEMP_ADDED=false
    BRIDGE_TEMP_CIDR=""
    return
  fi

  if pf_lan_temp_addr_ensure "${PF_LAN_BRIDGE:-}" "${LAN_VALIDATION_IP:-}" "${LAN_PREFIX:-}" "${LAN_NETWORK}"; then
    if [[ ${PF_LAN_TEMP_ADDR_ADDED} == true ]]; then
      BRIDGE_IP_TEMP_ADDED=true
      BRIDGE_TEMP_CIDR=${PF_LAN_TEMP_ADDR_CIDR}
    else
      BRIDGE_IP_TEMP_ADDED=false
      BRIDGE_TEMP_CIDR=""
    fi
    return
  fi

  local bridge="${PF_LAN_BRIDGE:-}"
  local fallback_ip="${LAN_VALIDATION_IP:-}"
  local fallback_prefix="${LAN_PREFIX:-}"
  local cidr=""

  if [[ -n ${fallback_ip} && -n ${fallback_prefix} ]]; then
    cidr="${fallback_ip}/${fallback_prefix}"
  fi

  if [[ -z ${bridge} ]]; then
    log_warn "Unable to determine LAN bridge; skipping manual temporary address assignment"
    return
  fi

  if [[ -z ${cidr} ]]; then
    log_warn "Missing LAN validation IPv4 address or prefix; skipping manual temporary assignment on ${bridge}"
    return
  fi

  log_info "Assigning temporary ${cidr} to ${bridge} for connectivity checks"
  if ip addr add "${cidr}" dev "${bridge}" >/dev/null 2>&1; then
    register_bridge_temp_cidr "${cidr}"
  else
    log_warn "Unable to assign ${cidr} to ${bridge}; connectivity checks may fail"
  fi
}

cleanup_bridge_ip() {
  if [[ ${PF_LAN_TEMP_ADDR_ADDED:-false} == true ]]; then
    if [[ $(type -t pf_lan_temp_addr_cleanup) == function ]]; then
      pf_lan_temp_addr_cleanup || log_warn "Failed to remove pf-lan temporary IP ${PF_LAN_TEMP_ADDR_CIDR:-} from ${PF_LAN_TEMP_ADDR_DEVICE:-}"
    fi
  fi

  if [[ ${BRIDGE_IP_TEMP_ADDED} != true ]]; then
    return
  fi
  if ! command -v ip >/dev/null 2>&1; then
    return
  fi
  if [[ -z ${PF_LAN_BRIDGE:-} ]]; then
    return
  fi
  if [[ ${#BRIDGE_TEMP_CIDRS[@]} -eq 0 ]]; then
    BRIDGE_IP_TEMP_ADDED=false
    return
  fi
  local cidr
  for cidr in "${BRIDGE_TEMP_CIDRS[@]}"; do
    ip addr del "${cidr}" dev "${PF_LAN_BRIDGE}" >/dev/null 2>&1 || log_warn "Failed to remove temporary IP ${cidr} from ${PF_LAN_BRIDGE}"
  done
  BRIDGE_IP_TEMP_ADDED=false
  BRIDGE_TEMP_CIDRS=()
}

reboot_vm() {
  if [[ ${CHECK_ONLY} == true || ${DRY_RUN} == true ]]; then
    log_info "Skipping VM reboot due to dry-run/check mode"
    return
  fi
  if [[ ${NEEDS_REBOOT} != true ]]; then
    log_debug "No reboot required"
    return
  fi
  log_info "Rebooting ${VM_NAME}"
  if ! virsh reboot "${VM_NAME}" >/dev/null; then
    log_warn "virsh reboot failed; attempting shutdown/start"
    virsh shutdown "${VM_NAME}" >/dev/null || log_warn "Failed to shutdown ${VM_NAME}"
    sleep 3
    virsh start "${VM_NAME}" >/dev/null || die ${EX_FATAL} "Unable to start ${VM_NAME}"
  fi
}

# shellcheck disable=SC2317
check_ping() {
  ping -c 1 -W 2 "${LAN_GW_IP}" >/dev/null 2>&1
}

# shellcheck disable=SC2317
check_https() {
  curl -kIs --connect-timeout 5 --max-time 8 "https://${LAN_GW_IP}/" >/dev/null 2>&1
}

probe_default_lan_gateway() {
  local fallback_ip="192.168.1.1"
  if [[ ${LAN_GW_IP} == "${fallback_ip}" ]]; then
    return
  fi
  local alias_cidr="192.168.1.2/24"
  local bridge="${PF_LAN_BRIDGE:-}"
  local alias_ready=false

  if [[ -n ${bridge} && ${CHECK_ONLY} != true && ${DRY_RUN} != true ]]; then
    if command -v ip >/dev/null 2>&1; then
      local current_cidrs=""
      current_cidrs=$(ip -o -4 addr show dev "${bridge}" 2>/dev/null | awk '{print $4}' || true)
      if [[ -n ${current_cidrs} ]] && grep -qxF "${alias_cidr}" <<<"${current_cidrs}"; then
        log_debug "Bridge ${bridge} already has ${alias_cidr}; reusing for legacy gateway probe"
        if register_bridge_temp_cidr "${alias_cidr}"; then
          alias_ready=true
        fi
      elif ip addr add "${alias_cidr}" dev "${bridge}" >/dev/null 2>&1; then
        log_debug "Assigned temporary ${alias_cidr} to ${bridge} for legacy gateway probe"
        if register_bridge_temp_cidr "${alias_cidr}"; then
          alias_ready=true
        fi
      else
        log_warn "Unable to assign ${alias_cidr} to ${bridge}; legacy gateway probe may be unreliable"
      fi
    else
      log_warn "ip command not available; cannot assign ${alias_cidr} to ${bridge} for legacy gateway probe"
    fi
  elif [[ -z ${bridge} ]]; then
    log_warn "Unable to determine LAN bridge; skipping temporary ${alias_cidr} assignment for legacy gateway probe"
  fi

  if [[ ${alias_ready} == true ]]; then
    ensure_bridge_cleanup_trap
  fi

  if ping -c 1 -W 2 "${fallback_ip}" >/dev/null 2>&1; then
    log_warn "pfSense responded at legacy default ${fallback_ip}; configuration import likely failed."
  fi
  if curl -kIs --connect-timeout 3 --max-time 5 "https://${fallback_ip}/" >/dev/null 2>&1; then
    log_warn "HTTPS probe to ${fallback_ip} succeeded; USB bootstrap may not have applied."
  fi
}

verify_connectivity() {
  if [[ ${CHECK_ONLY} == true ]]; then
    log_info "Skipping connectivity checks in --check-only mode"
    echo "PASS: [CHECK-ONLY] ping ${LAN_GW_IP} (skipped)"
    echo "PASS: [CHECK-ONLY] curl -kI https://${LAN_GW_IP}/ (skipped)"
    return
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "Skipping connectivity checks in --dry-run mode"
    echo "PASS: [DRY-RUN] ping ${LAN_GW_IP} (skipped)"
    echo "PASS: [DRY-RUN] curl -kI https://${LAN_GW_IP}/ (skipped)"
    return
  fi
  ensure_bridge_ipv4
  ensure_bridge_cleanup_trap
  log_info "Waiting for pfSense services on ${LAN_GW_IP} (up to ~200s)"
  if retry 40 5 check_ping; then
    PING_SUCCESS=true
    echo "PASS: ping ${LAN_GW_IP}"
  else
    echo "FAIL: ping ${LAN_GW_IP}"
  fi
  if retry 40 5 check_https; then
    CURL_SUCCESS=true
    echo "PASS: curl -kI https://${LAN_GW_IP}/"
  else
    echo "FAIL: curl -kI https://${LAN_GW_IP}/"
  fi
  if [[ ${PING_SUCCESS} != true || ${CURL_SUCCESS} != true ]]; then
    probe_default_lan_gateway
  fi
  cleanup_bridge_ip
}

print_static_route_guidance() {
  if [[ ${PING_SUCCESS} == true && ${CURL_SUCCESS} == true ]]; then
    cat <<GUIDANCE
TP-Link static route suggestion:
  Destination: ${LAN_NETWORK}
  Subnet mask: ${LAN_NETMASK}
  Gateway: ${HOMELAB_EDGE_GATEWAY}

If the router cannot add a static route, configure host routes instead:
  Windows (Admin): route add ${LAN_NETWORK} mask ${LAN_NETMASK} ${HOMELAB_EDGE_GATEWAY} -p
  Linux/macOS:     sudo ip route add ${LAN_NETWORK}/${LAN_PREFIX} via ${HOMELAB_EDGE_GATEWAY}
GUIDANCE
  fi
}

print_summary() {
  local summary_note=""
  local detail_note=""
  if [[ ${VM_AUTO_STARTED} == true ]]; then
    summary_note=" (VM auto-started)"
    detail_note=" vm_auto_started=true"
  fi

  if [[ ${CHECK_ONLY} == true ]]; then
    local drift="false"
    if [[ ${DRIFT_DETECTED} == true ]]; then
      drift="true"
    fi
    echo "SUMMARY: pfSense ZTP check-only (drift=${drift})${summary_note}"
    echo "LAN_READY=unknown mode=check-only drift=${drift} ip=${LAN_GW_IP} prefix=${LAN_PREFIX} bridge=${PF_LAN_BRIDGE:-unknown}${detail_note}"
    return
  fi

  if [[ ${DRY_RUN} == true ]]; then
    echo "SUMMARY: pfSense ZTP dry-run (connectivity checks skipped)${summary_note}"
    echo "LAN_READY=unknown mode=dry-run ip=${LAN_GW_IP} prefix=${LAN_PREFIX} bridge=${PF_LAN_BRIDGE:-unknown}${detail_note}"
    return
  fi

  local reason=""
  if [[ ${PING_SUCCESS} == true && ${CURL_SUCCESS} == true ]]; then
    echo "SUMMARY: pfSense LAN reachable at ${LAN_GW_IP}${summary_note}"
    echo "LAN_READY=true ip=${LAN_GW_IP} prefix=${LAN_PREFIX} bridge=${PF_LAN_BRIDGE:-unknown}${detail_note}"
    return
  fi

  if [[ ${PING_SUCCESS} != true ]]; then
    reason="ping"
  fi
  if [[ ${CURL_SUCCESS} != true ]]; then
    if [[ -n ${reason} ]]; then
      reason+="/"
    fi
    reason+="https"
  fi
  if [[ -z ${reason} ]]; then
    reason="unknown"
  fi
  echo "SUMMARY: pfSense LAN unreachable (failed: ${reason})${summary_note}"
  echo "LAN_READY=false ip=${LAN_GW_IP} prefix=${LAN_PREFIX} bridge=${PF_LAN_BRIDGE:-unknown} failed=${reason}${detail_note}"
}

main() {
  parse_args "$@"

  if [[ ${VERBOSE} == true ]]; then
    log_set_level debug || true
  fi

  if [[ ${EUID} -ne 0 ]]; then
    die ${EX_PREFLIGHT} "Root privileges are required; rerun with sudo"
  fi

  if [[ ${ROLLBACK} == true ]]; then
    setup_logging
    install_error_trap
    load_env_file
    ensure_vm_name
    setup_tmp_dir
    fetch_domain_info
    capture_domain_state
    restore_domain_backup
    exit ${EX_SUCCESS}
  fi

  setup_logging
  install_error_trap
  load_env_file
  if [[ -n ${VM_NAME_ARG} ]]; then
    VM_NAME="${VM_NAME_ARG}"
  fi
  ensure_required_env
  ensure_vm_name

  setup_tmp_dir

  update_config_xml || true
  ensure_usb_image

  if ! command -v virsh >/dev/null 2>&1; then
    die ${EX_PREFLIGHT} "virsh command is required"
  fi

  fetch_domain_info
  capture_domain_state
  ensure_domain_started_if_needed
  ensure_usb_controller
  ensure_usb_disk_attachment
  inspect_interfaces

  REBOOT_MARK_FILE="${REBOOT_MARK_DIR}/${VM_NAME}.last"
  LENIENT_MARK_FILE="${REBOOT_MARK_DIR}/${VM_NAME}.lenient"
  mkdir -p "${REBOOT_MARK_DIR}"

  if [[ ${CONFIG_CHANGED} == true || ${IMAGE_REBUILT} == true || ${USB_CONTROLLER_ADDED} == true || ${USB_DISK_ATTACHED} == true || ${NIC_MODEL_CHANGED} == true || ${LAN_INTERFACE_REWIRED} == true ]]; then
    NEEDS_REBOOT=true
  fi

  if [[ ${USB_PRESENT} == true && ${NEEDS_REBOOT} != true ]]; then
    if [[ -f ${REBOOT_MARK_FILE} ]]; then
      if find "${REBOOT_MARK_FILE}" -mmin +10 -print -quit >/dev/null 2>&1; then
        NEEDS_REBOOT=true
      fi
    else
      NEEDS_REBOOT=true
    fi
  fi

  if [[ ${CHECK_ONLY} == true ]]; then
    print_summary
    if [[ ${DRIFT_DETECTED} == true ]]; then
      exit ${EX_PREFLIGHT}
    fi
    exit ${EX_SUCCESS}
  fi

  if [[ ${DRY_RUN} == true ]]; then
    print_summary
    exit ${EX_SUCCESS}
  fi

  reboot_vm

  if [[ ${NEEDS_REBOOT} == true ]]; then
    date -u +%FT%TZ >"${REBOOT_MARK_FILE}" || true
  fi

  verify_connectivity
  print_summary
  if [[ ${PING_SUCCESS} == true && ${CURL_SUCCESS} == true ]]; then
    if [[ -n ${LENIENT_MARK_FILE:-} && -f ${LENIENT_MARK_FILE} ]]; then
      rm -f -- "${LENIENT_MARK_FILE}" >/dev/null 2>&1 || true
    fi
    print_static_route_guidance
    exit ${EX_SUCCESS}
  fi

  if [[ ${LENIENT} == true ]]; then
    if [[ -n ${LENIENT_MARK_FILE:-} && ! -f ${LENIENT_MARK_FILE} ]]; then
      log_warn "Lenient mode: pfSense LAN unreachable; tolerating the first connectivity failure. Marker: ${LENIENT_MARK_FILE}. Rerun to enforce strict checks."
      if printf '%s\n' "$(date -u +%FT%TZ) lenient-first-failure" >"${LENIENT_MARK_FILE}"; then
        exit ${EX_SUCCESS}
      fi
      log_warn "Unable to record lenient state at ${LENIENT_MARK_FILE}; enforcing failure to avoid repeated leniency."
    fi
    if [[ -n ${LENIENT_MARK_FILE:-} && -f ${LENIENT_MARK_FILE} ]]; then
      log_warn "Lenient grace already consumed (marker: ${LENIENT_MARK_FILE}); connectivity failure will be treated as fatal."
    fi
  fi

  exit ${EX_VERIFY}
}

main "$@"
