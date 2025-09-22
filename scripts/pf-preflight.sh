#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--env-file" ]]; then ENV_FILE="${2:-./.env}"; shift 2; else ENV_FILE="./.env"; fi
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

fatal(){ echo "[FATAL] $*" >&2; exit "${2:-20}"; }
need(){ local k="$1"; [[ -n "${!k:-}" ]] || fatal "$k must be set in $ENV_FILE"; }

for k in PF_VM_NAME PF_LAN_BRIDGE PF_WAN_BRIDGE LAN_CIDR LAN_GW_IP LAN_DHCP_FROM LAN_DHCP_TO; do need "$k"; done

PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-${PF_SERIAL_INSTALLER_PATH:-}}"
[[ -n "${PF_INSTALLER_SRC:-}" ]] || fatal "Installer path not provided. Set PF_INSTALLER_SRC or PF_SERIAL_INSTALLER_PATH"

if [[ ! -f "$PF_INSTALLER_SRC" ]]; then
  fatal "Installer file not found at $PF_INSTALLER_SRC"
fi

echo "[OK] Preflight passed using $ENV_FILE"
