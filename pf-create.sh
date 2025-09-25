#!/usr/bin/env bash
# pf-create.sh — Option A (routed-on-a-stick)
# WAN (vtnet0) → br0 (DHCP from 192.168.88.0/24)
# LAN (vtnet1) → pfsense-lan (10.10.0.0/24 behind pfSense)
#
# Usage:
#   sudo ./pf-create.sh --create   [--env-file ./.env] [--disk-size 16] [--memory 2048] [--vcpus 2] [--osinfo freebsd14.0]
#   sudo ./pf-create.sh --finalize [--env-file ./.env]
#
# Notes:
# - Do NOT assign any IP on the host for pfSense WAN. pfSense WAN will use DHCP from upstream via br0.
# - If you want pfSense WAN static, set it INSIDE pfSense (Interfaces → WAN).
# - Make sure bridges exist first: pfsense-lan + br0 (we don't modify them).
# - Installer path expected: $HOME/downloads/netgate-installer-amd64.img.gz (serial image)

set -euo pipefail

ENV_FILE="./.env"
MODE=""
DISK_SIZE_GB=16
MEM_MB=2048
VCPUS=2
OSINFO="freebsd14.0"

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
err()  { printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
pf-create.sh (Option A: routed-on-a-stick)

WAN (vtnet0) -> br0 (DHCP)
LAN (vtnet1) -> pfsense-lan (10.10.0.0/24)

Modes:
  --create     Define VM, create disk (if missing), attach installer (serial), NICs to br0 + pfsense-lan
  --finalize   Detach installer, ensure boot from disk (run after installing pfSense inside the VM)

Options:
  --env-file PATH      Default ./.env
  --disk-size GB       Default 16
  --memory MB          Default 2048
  --vcpus N            Default 2
  --osinfo STRING      Default freebsd14.0 (falls back to detect=on,require=off)

This script DOES NOT change host NICs or netplan.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --create) MODE="create"; shift ;;
    --finalize) MODE="finalize"; shift ;;
    --env-file) ENV_FILE="${2:-}"; shift 2 ;;
    --disk-size) DISK_SIZE_GB="${2:-}"; shift 2 ;;
    --memory) MEM_MB="${2:-}"; shift 2 ;;
    --vcpus) VCPUS="${2:-}"; shift 2 ;;
    --osinfo) OSINFO="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$MODE" ]] || die "Choose a mode: --create or --finalize (see --help)."

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
for c in virsh virt-install qemu-img gunzip awk sed grep tee ip; do require_cmd "$c"; done

[[ -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"

set -a
# shellcheck disable=SC1090
. <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sed 's/\r$//') || true
set +a

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-pfsense-lan}"
PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-br0}"
PF_SERIAL_INSTALLER_PATH="${PF_SERIAL_INSTALLER_PATH:-$HOME/downloads/netgate-installer-amd64.img.gz}"

IMAGEDIR="/var/lib/libvirt/images"
STATE_DIR="/opt/homelab/pfsense"
INSTALLER_IMG="$STATE_DIR/installer.img"
DISK_PATH="$IMAGEDIR/${PF_VM_NAME}.qcow2"

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

log "Using .env: $ENV_FILE"
log "PF_VM_NAME=$PF_VM_NAME"
log "PF_WAN_BRIDGE=$PF_WAN_BRIDGE (Option A expects br0)"
log "PF_LAN_BRIDGE=$PF_LAN_BRIDGE"
log "PF_SERIAL_INSTALLER_PATH=$PF_SERIAL_INSTALLER_PATH"
log "DISK=$DISK_PATH size=${DISK_SIZE_GB}G, MEM=${MEM_MB}MB, VCPUS=${VCPUS}, OSINFO=${OSINFO}"

ACTIVE_IF="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
log "Active route interface: ${ACTIVE_IF:-unknown}"
if [[ "${PF_WAN_BRIDGE}" != "br0" ]]; then
  log "WARNING: Option A expects PF_WAN_BRIDGE=br0. Proceeding with ${PF_WAN_BRIDGE}."
fi
if [[ "${ACTIVE_IF:-}" == "br0" || "${ACTIVE_IF:-}" == "eno1" ]]; then
  log "Guard: Host SSH path is via ${ACTIVE_IF}. This script WILL NOT alter br0/eno1."
fi

ensure_dir() { mkdir -p "$1"; }
bridge_exists() { ip link show "$1" >/dev/null 2>&1; }
ensure_bridge_present() { bridge_exists "$1" || die "Bridge not found: $1 (create it first)."; }

case "$MODE" in
  create)
    ensure_bridge_present "$PF_WAN_BRIDGE"
    ensure_bridge_present "$PF_LAN_BRIDGE"

    ensure_dir "$STATE_DIR"
    [[ -f "$PF_SERIAL_INSTALLER_PATH" ]] || die "Installer not found: $PF_SERIAL_INSTALLER_PATH"
    case "$PF_SERIAL_INSTALLER_PATH" in
      *.gz)  log "Expanding gz installer to $INSTALLER_IMG"; gunzip -c "$PF_SERIAL_INSTALLER_PATH" > "$INSTALLER_IMG" ;;
      *.img|*.iso) log "Copying installer to $INSTALLER_IMG"; cp -f "$PF_SERIAL_INSTALLER_PATH" "$INSTALLER_IMG" ;;
      *) die "Unsupported installer extension. Use .img(.gz) or .iso(.gz)";;
    esac

    ensure_dir "$IMAGEDIR"
    if [[ -f "$DISK_PATH" ]]; then
      log "Disk already exists: $DISK_PATH"
    else
      log "Creating qcow2 disk: $DISK_PATH (${DISK_SIZE_GB}G)"
      qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE_GB}G" >/dev/null
    fi

    if virsh dominfo "$PF_VM_NAME" >/dev/null 2>&1; then
      log "Domain already exists: $PF_VM_NAME (nothing to do)."
      exit 0
    fi

    OSINFO_ARGS=(--osinfo "$OSINFO")
    if ! osinfo-query os 2>/dev/null | grep -qi "$OSINFO"; then
      log "osinfo '$OSINFO' not found; using detect=on,require=off"
      OSINFO_ARGS=(--osinfo detect=on,require=off)
    fi

    log "Running virt-install (WAN=${PF_WAN_BRIDGE}, LAN=${PF_LAN_BRIDGE})..."
    virt-install \
      --name "$PF_VM_NAME" \
      --memory "$MEM_MB" \
      --vcpus "$VCPUS" \
      --cpu host \
      --import \
      --disk "path=$DISK_PATH,format=qcow2,bus=virtio" \
      --disk "path=$INSTALLER_IMG,device=cdrom" \
      --network "bridge=$PF_WAN_BRIDGE,model=virtio" \
      --network "bridge=$PF_LAN_BRIDGE,model=virtio" \
      --graphics none \
      --noautoconsole \
      --console pty,target_type=serial \
      --boot useserial=on,menu=on \
      "${OSINFO_ARGS[@]}"

    log "VM defined."
    log "Start:   virsh start $PF_VM_NAME"
    log "Console: virsh console $PF_VM_NAME   (exit with Ctrl-])"
    log "Inside pfSense install: set WAN=DHCP, LAN=10.10.0.1/24."
    ;;

  finalize)
    virsh dominfo "$PF_VM_NAME" >/dev/null 2>&1 || die "Domain not found: $PF_VM_NAME"
    CD_PATH="$(virsh domblklist "$PF_VM_NAME" | awk '/installer\.img/{print $2}' || true)"
    if [[ -n "$CD_PATH" ]]; then
      log "Detaching installer $CD_PATH"
      virsh detach-disk "$PF_VM_NAME" "$CD_PATH" --config || true
    else
      log "No installer.img attached."
    fi

    log "Ensuring boot from disk (hd) with serial console"
    virsh update-device "$PF_VM_NAME" /dev/stdin --config <<'XML' || true
<domain>
  <os>
    <boot dev='hd'/>
  </os>
  <devices>
    <serial type='pty'>
      <target type='isa-serial' port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
  </devices>
</domain>
XML

    log "Finalize complete. Reboot the VM to boot from disk:"
    log "  virsh reboot $PF_VM_NAME"
    ;;
esac

