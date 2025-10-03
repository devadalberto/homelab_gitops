#!/usr/bin/env bash
set -euo pipefail

# Args
if [[ "${1:-}" == "--env-file" ]]; then
  ENV_FILE="${2:-./.env}"
  shift 2
else ENV_FILE="./.env"; fi

missing=()

need_cmd() { command -v "$1" >/dev/null 2>&1 || missing+=("$1"); }
need_file() { [[ -f "$1" ]] || return 1; }

echo "[INFO] Host tooling check"
for c in ip brctl virsh xorriso genisoimage mkisofs awk sed grep; do need_cmd "$c"; done || true
if ((${#missing[@]})); then
  printf '[FATAL] Missing tools: %s\n' "${missing[*]}" >&2
  echo "Install: sudo apt-get install -y xorriso genisoimage bridge-utils libvirt-clients libvirt-daemon-system" >&2
  exit 9
fi

echo "[INFO] .env keys required:"
cat <<'EOKEYS'
PF_VM_NAME=
PF_LAN_BRIDGE=
PF_WAN_BRIDGE=
LAN_CIDR=
LAN_GW_IP=
LAN_DHCP_FROM=
LAN_DHCP_TO=
# One of:
PF_INSTALLER_SRC=/home/<user>/downloads/netgate-installer-amd64.img.gz
# or legacy:
PF_SERIAL_INSTALLER_PATH=/home/<user>/downloads/netgate-installer-amd64.img.gz
EOKEYS

if [[ -f "$ENV_FILE" ]]; then
  echo "[OK] Found $ENV_FILE"
else
  echo "[WARN] $ENV_FILE not found"
fi

exit 0
