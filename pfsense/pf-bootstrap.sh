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

INSTALL_PATH="${PF_SERIAL_INSTALLER_PATH:-${PF_ISO_PATH:-}}"
HEADLESS="${PF_HEADLESS:-true}"

usage() {
  cat <<'USAGE'
Usage: pf-bootstrap.sh [--installation-path PATH] [--headless] [--no-headless]

Options:
  --installation-path PATH   Override the pfSense installer to stage (.iso[.gz] or .img[.gz])
  --headless                 Force serial/headless install (default)
  --no-headless              Enable the legacy VNC console
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --installation-path)
      INSTALL_PATH="$2"
      shift 2
      ;;
    --headless)
      HEADLESS=true
      shift
      ;;
    --no-headless)
      HEADLESS=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

case "$HEADLESS" in
  true|false) ;;
  *)
    echo "HEADLESS must be 'true' or 'false' (got '$HEADLESS')" >&2
    exit 1
    ;;
esac

if [[ -z "${INSTALL_PATH}" ]]; then
  echo "Installer path not provided. Set PF_SERIAL_INSTALLER_PATH or PF_ISO_PATH, or pass --installation-path." >&2
  exit 1
fi

mkdir -p "${PF_WORK}" "${IMAGES_DIR}"

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

# Installer image (prefer serial build)
if [[ ! -f "$INSTALL_PATH" ]]; then
  echo "Installer not found at $INSTALL_PATH" >&2
  exit 1
fi

INSTALL_MEDIA=""
if [[ "$INSTALL_PATH" == *.gz ]]; then
  if [[ "$INSTALL_PATH" == *.img.gz ]]; then
    INSTALL_MEDIA="${PF_WORK}/pfsense-installer.img"
  else
    INSTALL_MEDIA="${PF_WORK}/pfsense-installer.iso"
  fi
  echo "Staging pfSense installer from $INSTALL_PATH to $INSTALL_MEDIA"
  gzip -dc "$INSTALL_PATH" > "$INSTALL_MEDIA"
else
  INSTALL_MEDIA="$INSTALL_PATH"
fi

[[ -s "$INSTALL_MEDIA" ]] || { echo "pfSense installer missing" >&2; exit 1; }

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

# Installer attachment args
INSTALL_MEDIA_ARGS=(--cdrom "$INSTALL_MEDIA")
if [[ "$INSTALL_MEDIA" == *.img ]]; then
  INSTALL_MEDIA_ARGS=(--disk "path=${INSTALL_MEDIA},device=disk,bus=usb")
fi

if [[ "$HEADLESS" == true ]]; then
  GRAPHICS_ARGS=(--graphics none)
  CONSOLE_ARGS=(--noautoconsole --console pty,target.type=serial --serial pty,target.type=serial --extra-args "console=ttyS0")
else
  GRAPHICS_ARGS=(--graphics vnc)
  CONSOLE_ARGS=(--noautoconsole --console pty,target.type=serial --serial pty,target.type=serial)
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
    "${GRAPHICS_ARGS[@]}" \
    "${INSTALL_MEDIA_ARGS[@]}" \
    --disk "path=${VM_DISK},bus=virtio,format=qcow2" \
    ${WAN_OPT} \
    --network "network=${LAN_NET_NAME},model=virtio" \
    "${CONSOLE_ARGS[@]}" \
    ${OSVAR}
fi

echo "pfSense VM ready. Connect via 'virsh console ${VM_NAME}' to complete the serial installer."
