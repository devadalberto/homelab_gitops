#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DIR")"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || source "$ROOT/.env.example"

IMAGES_DIR="/var/lib/libvirt/images"
PF_WORK="${WORK_ROOT}/pfsense"
LAN_NET_NAME="pfsense-lan"
LAN_BRIDGE="virbr-lan"
CONFIG_TARGET="sdb"

INSTALL_PATH="${PF_ISO_PATH:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --installation-path)
      INSTALL_PATH="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--installation-path path]"
      exit 1
      ;;
  esac
done

mkdir -p "${PF_WORK}" "${IMAGES_DIR}"

CONFIG_DIR="${PF_WORK}/config"
CONFIG_ISO="${CONFIG_DIR}/pfSense-config.iso"
CONFIG_GEN="${DIR}/pf-config-gen.sh"

if [[ ! -f "${CONFIG_ISO}" ]]; then
  echo "pfSense config ISO not found at ${CONFIG_ISO}; generating via ${CONFIG_GEN}."
  "${CONFIG_GEN}"
fi

if [[ ! -f "${CONFIG_ISO}" ]]; then
  echo "pfSense config ISO missing; rerun ${CONFIG_GEN}" >&2
  exit 1
fi

echo "Using pfSense config ISO at ${CONFIG_ISO}"

ensure_config_iso_attached() {
  local dom_state current_source
  dom_state="$(virsh domstate "${VM_NAME}" 2>/dev/null | tr -d '\r')"
  if [[ -z "${dom_state}" ]]; then
    return
  fi

  if [[ "${dom_state}" != "shut off" && "${dom_state}" != "pmsuspended" ]]; then
    echo "Warning: ${VM_NAME} is currently '${dom_state}'. Shut the VM down before swapping config media." >&2
    return
  fi

  current_source="$(virsh domblklist "${VM_NAME}" 2>/dev/null | awk -v target="${CONFIG_TARGET}" 'NR>2 && $1==target {print $2}')"

  if [[ -z "${current_source}" ]]; then
    if virsh attach-disk "${VM_NAME}" "${CONFIG_ISO}" "${CONFIG_TARGET}" --type cdrom --mode readonly --config >/dev/null; then
      echo "Attached pfSense config ISO to ${VM_NAME} (${CONFIG_TARGET})."
    else
      echo "Warning: failed to attach pfSense config ISO; use 'virsh attach-disk ${VM_NAME} ${CONFIG_ISO} ${CONFIG_TARGET} --type cdrom --mode readonly --config'." >&2
    fi
    return
  fi

  if [[ "${current_source}" != "${CONFIG_ISO}" ]]; then
    if virsh change-media "${VM_NAME}" "${CONFIG_TARGET}" "${CONFIG_ISO}" --insert --force --config >/dev/null; then
      echo "Updated pfSense config ISO for ${VM_NAME}."
    else
      echo "Warning: failed to update pfSense config ISO; use 'virsh change-media ${VM_NAME} ${CONFIG_TARGET} ${CONFIG_ISO} --insert --force --config' once the VM is stopped." >&2
    fi
  else
    echo "pfSense config ISO already attached to ${VM_NAME}."
  fi
}

# Libvirt LAN (isolated L2)
if virsh net-info "${LAN_NET_NAME}" &>/dev/null; then
  echo "Libvirt network '${LAN_NET_NAME}' exists."
else
  NET_XML="${PF_WORK}/${LAN_NET_NAME}.xml"
  cat > "$NET_XML" <<EOF
<network>
  <name>${LAN_NET_NAME}</name>
  <bridge name='${LAN_BRIDGE}' stp='on' delay='0'/>
  <forward mode='bridge'/>
</network>
EOF
  virsh net-define "$NET_XML"
  virsh net-autostart "${LAN_NET_NAME}"
  virsh net-start "${LAN_NET_NAME}"
fi

# ISO
ISO="${PF_WORK}/pfsense.iso"
if [[ ! -f "$ISO" ]]; then
  if [[ -f "$INSTALL_PATH" ]]; then
    gzip -dc "$INSTALL_PATH" > "$ISO"
  else
    echo "Installer not found at $INSTALL_PATH"
    exit 1
  fi
fi
[[ -s "$ISO" ]] || { echo "pfSense ISO missing"; exit 1; }

# VM Disk
VM_DISK="${IMAGES_DIR}/${VM_NAME}.qcow2"
if [[ ! -f "$VM_DISK" ]]; then
  qemu-img create -f qcow2 "$VM_DISK" "${DISK_SIZE_GB}G"
fi

# WAN attachment
if [[ "${WAN_MODE}" == "br0" ]]; then
  WAN_OPT="--network bridge=br0,model=virtio"
else
  WAN_OPT="--network type=direct,source=${WAN_NIC},source_mode=bridge,model=virtio"
fi

# Define VM if not exists
if virsh dominfo "${VM_NAME}" &>/dev/null; then
  echo "VM '${VM_NAME}' already defined."
else
  OSVAR=""
  if osinfo-query os | grep -q 'freebsd13'; then OSVAR="--os-variant freebsd13.2"; fi

  virt-install \
    --name "${VM_NAME}" \
    --memory "${RAM_MB}" \
    --vcpus "${VCPUS}" \
    --cpu host \
    --hvm \
    --virt-type kvm \
    --graphics vnc \
    --cdrom "${ISO}" \
    --disk "path=${VM_DISK},bus=virtio,format=qcow2" \
    --disk "path=${CONFIG_ISO},device=cdrom,readonly=yes,target=${CONFIG_TARGET}" \
    ${WAN_OPT} \
    --network "network=${LAN_NET_NAME},model=virtio" \
    --noautoconsole \
    ${OSVAR}
fi

ensure_config_iso_attached

echo "pfSense VM ready. Use 'virt-viewer --connect qemu:///system ${VM_NAME}' to install."
