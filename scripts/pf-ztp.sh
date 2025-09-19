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

readonly EX_OK=0
readonly EX_ERROR=1
readonly EX_DRIFT=2
readonly EX_VERIFY=3

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
DRY_RUN=false
CHECK_ONLY=false
VERBOSE=false
ROLLBACK=false

PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-}"

TMP_DIR=""
USB_MOUNT_DIR=""
DOMAIN_XML_PATH=""
DOMAIN_INFO_JSON=""
DOMAIN_BACKUP_FILE=""
DOMAIN_BACKUP_CREATED=false

CONFIG_CHANGED=false
IMAGE_REBUILT=false
USB_CONTROLLER_ADDED=false
USB_DISK_ATTACHED=false
NIC_MODEL_CHANGED=false
NEEDS_REBOOT=false
DRIFT_DETECTED=false
PING_SUCCESS=false
CURL_SUCCESS=false

usage() {
  cat <<'USAGE'
Usage: pf-ztp.sh [OPTIONS]

Zero-touch provisioning helper for pfSense USB bootstrap media and VM wiring.

Options:
  --env-file PATH    Load environment overrides from PATH.
  --vm-name NAME     Operate on the libvirt domain NAME.
  --force-e1000      Ensure the VM NIC model is e1000 (updates domain config).
  --dry-run          Log intended actions without mutating the host or VM.
  --check-only       Detect drift without making changes; implies --dry-run.
  --verbose          Increase log verbosity (debug output).
  --rollback         Restore the most recent domain XML backup and exit.
  -h, --help         Show this help message.

Exit codes:
  0  Success.
  1  Failure while preparing or applying changes.
  2  Drift detected during --check-only.
  3  Verification checks (ping/curl) failed.
USAGE
}

setup_tmp_dir() {
  if [[ -n ${TMP_DIR} ]]; then
    return
  fi
  TMP_DIR="$(mktemp -d)"
  trap_add cleanup_tmp EXIT INT TERM
}

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
          die ${EX_ERROR} "--env-file requires a path"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --vm-name)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_ERROR} "--vm-name requires a value"
        fi
        VM_NAME_ARG="$2"
        shift 2
        ;;
      --force-e1000)
        FORCE_E1000=true
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
      --rollback)
        ROLLBACK=true
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
      -* )
        usage
        die ${EX_ERROR} "Unknown option: $1"
        ;;
      * )
        usage
        die ${EX_ERROR} "Unexpected positional argument: $1"
        ;;
    esac
  done

  if [[ ${ROLLBACK} == true && ${CHECK_ONLY} == true ]]; then
    die ${EX_ERROR} "--rollback cannot be combined with --check-only"
  fi
  if [[ ${ROLLBACK} == true && ${DRY_RUN} == true ]]; then
    die ${EX_ERROR} "--rollback cannot be combined with --dry-run"
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
  if [[ -z ${LAN_GW_IP:-} ]]; then
    die ${EX_ERROR} "LAN_GW_IP is required"
  fi
  if [[ -z ${LAN_CIDR:-} ]]; then
    die ${EX_ERROR} "LAN_CIDR is required"
  fi

  if [[ -z ${LAN_DHCP_FROM:-} ]]; then
    LAN_DHCP_FROM="10.10.0.100"
  fi
  if [[ -z ${LAN_DHCP_TO:-} ]]; then
    LAN_DHCP_TO="10.10.0.200"
  fi

  if ! [[ ${LAN_DHCP_FROM} =~ ^[0-9.]+$ ]]; then
    die ${EX_ERROR} "LAN_DHCP_FROM must be an IPv4 address"
  fi
  if ! [[ ${LAN_DHCP_TO} =~ ^[0-9.]+$ ]]; then
    die ${EX_ERROR} "LAN_DHCP_TO must be an IPv4 address"
  fi
}

compute_lan_prefix() {
  local result
  result=$(python3 - "$LAN_CIDR" <<'PY'
import ipaddress
import sys
cidr = sys.argv[1]
try:
    net = ipaddress.ip_network(cidr, strict=False)
except ValueError as exc:
    print(f"Invalid LAN_CIDR: {exc}", file=sys.stderr)
    sys.exit(1)
print(f"{net.prefixlen} {net.network_address}")
PY
  ) || die ${EX_ERROR} "Failed to parse LAN_CIDR ${LAN_CIDR}"
  LAN_PREFIX="${result%% *}"
  LAN_NETWORK="${result#* }"
}

ensure_vm_name() {
  if [[ -n ${VM_NAME_ARG} ]]; then
    VM_NAME="${VM_NAME_ARG}"
  fi
  if [[ -z ${VM_NAME:-} ]]; then
    die ${EX_ERROR} "--vm-name is required when VM_NAME is not set in the environment"
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
    die ${EX_ERROR} "Failed to dump domain XML for ${VM_NAME}"
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
        "target": None,
        "bridge": None,
        "model": None,
        "mac": None,
        "alias": None,
    }
    target = iface.find("target")
    if target is not None:
        entry["target"] = target.get("dev")
    source = iface.find("source")
    if source is not None:
        entry["bridge"] = source.get("bridge")
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
    die ${EX_ERROR} "No domain XML backup found at ${pointer}"
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
    die ${EX_ERROR} "Failed to restore domain definition from ${pointer}"
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
    die ${EX_ERROR} "Cannot continue without ${CONFIG_XML}"
  fi

  local mode
  if [[ ${CHECK_ONLY} == true || ${DRY_RUN} == true ]]; then
    mode="check"
  else
    mode="commit"
  fi

  local result
  result=$(python3 - "${CONFIG_XML}" "${LAN_GW_IP}" "${LAN_PREFIX}" "${LAN_DHCP_FROM}" "${LAN_DHCP_TO}" "${mode}" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET
config_path, gw_ip, subnet_bits, dhcp_from, dhcp_to, mode = sys.argv[1:7]
commit = mode == "commit"
try:
    tree = ET.parse(config_path)
except FileNotFoundError:
    print("MISSING")
    sys.exit(0)
root = tree.getroot()
changed = False
lan = root.find("./interfaces/lan")
if lan is None:
    print("ERROR: Missing <interfaces><lan> in config.xml", file=sys.stderr)
    sys.exit(1)
ipaddr = lan.find("ipaddr")
if ipaddr is None:
    ipaddr = ET.SubElement(lan, "ipaddr")
if (ipaddr.text or "") != gw_ip:
    ipaddr.text = gw_ip
    changed = True
subnet = lan.find("subnet")
if subnet is None:
    subnet = ET.SubElement(lan, "subnet")
if (subnet.text or "") != subnet_bits:
    subnet.text = subnet_bits
    changed = True
dhcpd = root.find("./dhcpd/lan")
if dhcpd is None:
    dhcpd = root.find("./dhcpd")
    if dhcpd is None:
        dhcpd = ET.SubElement(root, "dhcpd")
    dhcpd = dhcpd.find("lan") or ET.SubElement(dhcpd, "lan")
range_elem = dhcpd.find("range")
if range_elem is None:
    range_elem = ET.SubElement(dhcpd, "range")
from_elem = range_elem.find("from")
if from_elem is None:
    from_elem = ET.SubElement(range_elem, "from")
if (from_elem.text or "") != dhcp_from:
    from_elem.text = dhcp_from
    changed = True
to_elem = range_elem.find("to")
if to_elem is None:
    to_elem = ET.SubElement(range_elem, "to")
if (to_elem.text or "") != dhcp_to:
    to_elem.text = dhcp_to
    changed = True
if changed and commit:
    tmp_path = f"{config_path}.tmp"
    tree.write(tmp_path, encoding="utf-8", xml_declaration=True)
    os.replace(tmp_path, config_path)
print("CHANGED" if changed else "UNCHANGED")
PY
  ) || die ${EX_ERROR} "Failed to inspect ${CONFIG_XML}"

  if [[ ${result} == "CHANGED" ]]; then
    CONFIG_CHANGED=true
    if [[ ${CHECK_ONLY} == true ]]; then
      DRIFT_DETECTED=true
    fi
    log_info "Updated ${CONFIG_XML} with LAN gateway ${LAN_GW_IP}, /${LAN_PREFIX}, DHCP ${LAN_DHCP_FROM}-${LAN_DHCP_TO}"
  else
    log_debug "${CONFIG_XML} already matches requested LAN settings"
  fi
}

select_mkfs_command() {
  if command -v mkfs.vfat >/dev/null 2>&1; then
    echo "$(command -v mkfs.vfat)"
    return 0
  fi
  if command -v mkfs.fat >/dev/null 2>&1; then
    echo "$(command -v mkfs.fat)"
    return 0
  fi
  return 1
}

build_usb_image() {
  local mkfs_cmd
  if ! mkfs_cmd=$(select_mkfs_command); then
    die ${EX_ERROR} "mkfs.vfat or mkfs.fat is required to build the USB image"
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would create ${USB_IMAGE} with label ${USB_LABEL}"
    return
  fi

  mkdir -p "${CONFIG_ROOT}"
  truncate -s "${USB_SIZE_MIB}M" "${USB_IMAGE}.tmp"
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
    die ${EX_ERROR} "Failed to attach USB controller to ${VM_NAME}"
  fi
  log_info "Attached USB controller to ${VM_NAME}"
}

ensure_usb_disk_attachment() {
  local attached
  attached=$(json_extract "usb_disk.attached")
  if [[ ${attached} == true ]]; then
    local readonly
    readonly=$(json_extract "usb_disk.readonly")
    if [[ ${readonly} != true ]]; then
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
    die ${EX_ERROR} "Failed to attach USB disk image to ${VM_NAME}"
  fi
  log_info "Attached ${USB_IMAGE} to ${VM_NAME} via attach-device"
}

update_interface_model() {
  local target=$1
  local bridge=$2
  local snippet="${TMP_DIR}/iface-${target}.xml"
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
    die ${EX_ERROR} "Failed to update NIC ${target} to e1000"
  fi
  log_info "Updated NIC ${target} (${bridge}) to e1000"
  return 0
}

inspect_interfaces() {
  local idx=0
  while true; do
    local target
    target=$(json_extract "interfaces[${idx}].target")
    if [[ -z ${target} ]]; then
      break
    fi
    local bridge
    bridge=$(json_extract "interfaces[${idx}].bridge")
    local model
    model=$(json_extract "interfaces[${idx}].model")
    if [[ -z ${PF_WAN_BRIDGE} ]]; then
      PF_WAN_BRIDGE="br0"
    fi
    if [[ -z ${PF_LAN_BRIDGE} ]]; then
      PF_LAN_BRIDGE="virbr-lan"
    fi
    case "${target}" in
      vnet0)
        if [[ ${bridge} != "${PF_WAN_BRIDGE}" ]]; then
          log_warn "Interface ${target} bridged to ${bridge:-unknown}; expected ${PF_WAN_BRIDGE}"
        fi
        ;;
      vnet1)
        if [[ ${bridge} != "${PF_LAN_BRIDGE}" ]]; then
          log_warn "Interface ${target} bridged to ${bridge:-unknown}; expected ${PF_LAN_BRIDGE}"
        fi
        ;;
    esac
    if [[ ${FORCE_E1000} == true && ${model} != "e1000" ]]; then
      if [[ ${CHECK_ONLY} == true ]]; then
        DRIFT_DETECTED=true
        log_warn "[CHECK-ONLY] NIC ${target} is ${model:-unknown}; would change to e1000"
      else
        backup_domain_xml
        if update_interface_model "${target}" "${bridge}"; then
          NIC_MODEL_CHANGED=true
        fi
      fi
    fi
    ((idx++))
  done
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
    virsh start "${VM_NAME}" >/dev/null || die ${EX_ERROR} "Unable to start ${VM_NAME}"
  fi
}

check_ping() {
  ping -c 1 -W 2 "${LAN_GW_IP}" >/dev/null 2>&1
}

check_https() {
  curl -kIs --connect-timeout 5 --max-time 10 "https://${LAN_GW_IP}/" >/dev/null 2>&1
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
  log_info "Waiting for pfSense services on ${LAN_GW_IP}"
  if retry 10 6 check_ping; then
    PING_SUCCESS=true
    echo "PASS: ping ${LAN_GW_IP}"
  else
    echo "FAIL: ping ${LAN_GW_IP}"
  fi
  if retry 10 6 check_https; then
    CURL_SUCCESS=true
    echo "PASS: curl -kI https://${LAN_GW_IP}/"
  else
    echo "FAIL: curl -kI https://${LAN_GW_IP}/"
  fi
}

print_static_route_guidance() {
  if [[ ${PING_SUCCESS} == true && ${CURL_SUCCESS} == true ]]; then
    cat <<GUIDANCE
TP-Link static route suggestion:
  Destination: ${LAN_NETWORK}/${LAN_PREFIX}
  Gateway: ${LAN_GW_IP}
  Interface: LAN
GUIDANCE
  fi
}

main() {
  parse_args "$@"

  if [[ ${VERBOSE} == true ]]; then
    log_set_level debug || true
  fi

  if [[ ${ROLLBACK} == true ]]; then
    setup_logging
    load_env_file
    ensure_vm_name
    setup_tmp_dir
    fetch_domain_info
    restore_domain_backup
    exit ${EX_OK}
  fi

  setup_logging
  load_env_file
  if [[ -n ${VM_NAME_ARG} ]]; then
    VM_NAME="${VM_NAME_ARG}"
  fi
  ensure_required_env
  compute_lan_prefix
  ensure_vm_name

  setup_tmp_dir

  update_config_xml || true
  ensure_usb_image

  if ! command -v virsh >/dev/null 2>&1; then
    die ${EX_ERROR} "virsh command is required"
  fi

  fetch_domain_info
  ensure_usb_controller
  ensure_usb_disk_attachment
  inspect_interfaces

  if [[ ${CONFIG_CHANGED} == true || ${IMAGE_REBUILT} == true || ${USB_CONTROLLER_ADDED} == true || ${USB_DISK_ATTACHED} == true || ${NIC_MODEL_CHANGED} == true ]]; then
    NEEDS_REBOOT=true
  fi

  if [[ ${CHECK_ONLY} == true ]]; then
    if [[ ${DRIFT_DETECTED} == true ]]; then
      exit ${EX_DRIFT}
    fi
    exit ${EX_OK}
  fi

  reboot_vm
  verify_connectivity
  if [[ ${PING_SUCCESS} == true && ${CURL_SUCCESS} == true ]]; then
    print_static_route_guidance
    exit ${EX_OK}
  fi
  exit ${EX_VERIFY}
}

main "$@"
