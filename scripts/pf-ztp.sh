#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--env-file" ]]; then ENV_FILE="${2:-./.env}"; shift 2; else ENV_FILE="./.env"; fi
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

fatal(){ echo "[FATAL] $*" >&2; exit "${2:-40}"; }

PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-${PF_SERIAL_INSTALLER_PATH:-}}"
[[ -n "${PF_INSTALLER_SRC:-}" ]] || fatal "Installer path not provided. Set PF_INSTALLER_SRC or PF_SERIAL_INSTALLER_PATH."
[[ -f "$PF_INSTALLER_SRC" ]] || fatal "Installer file not found at $PF_INSTALLER_SRC"

PF_VM_NAME="${PF_VM_NAME:?PF_VM_NAME must be set}"

# Ensure config ISO exists
CFG_ISO="/opt/homelab/pfsense/config/pfSense-config.iso"
[[ -f "$CFG_ISO" ]] || fatal "Config ISO not found at $CFG_ISO; run pf.config first"

# Attach disks to VM (idempotent)
if ! sudo virsh domblklist "$PF_VM_NAME" | awk '{print $1}' | grep -q sdz; then
  sudo virsh attach-disk "$PF_VM_NAME" "$CFG_ISO" sdz --type cdrom --mode readonly --config || true
fi

# Prepare installer media (supports .gz img)
MEDIA_PATH="$PF_INSTALLER_SRC"
if [[ "$MEDIA_PATH" == *.gz ]]; then
  TMP_DIR="$(sudo mktemp -d)"
  sudo gzip -t "$MEDIA_PATH"
  sudo sh -c "gunzip -c '$MEDIA_PATH' > '$TMP_DIR/installer.img'"
  MEDIA_PATH="$TMP_DIR/installer.img"
fi

# Attach installer as vda if not present
if ! sudo virsh domblklist "$PF_VM_NAME" | awk '{print $1}' | grep -q vdb; then
  sudo virsh attach-disk "$PF_VM_NAME" "$MEDIA_PATH" vdb --config || true
fi

echo "[OK] ZTP media attached for $PF_VM_NAME"
