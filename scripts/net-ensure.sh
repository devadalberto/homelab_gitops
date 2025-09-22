#!/usr/bin/env bash
set -euo pipefail

# Args
if [[ "${1:-}" == "--env-file" ]]; then ENV_FILE="${2:-./.env}"; shift 2; else ENV_FILE="./.env"; fi
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

fatal(){ echo "[FATAL] $*" >&2; exit "${2:-12}"; }
need(){ local k="$1"; [[ -n "${!k:-}" ]] || fatal "$k must be set in $ENV_FILE"; }

need PF_WAN_BRIDGE
need PF_LAN_BRIDGE

command -v ip >/dev/null 2>&1 || fatal "ip(8) not found; install iproute2" 10

ensure_bridge(){
  local br="$1"
  if ! ip link show "$br" >/dev/null 2>&1; then
    if [[ "${NET_CREATE:-0}" == "1" ]]; then
      sudo ip link add name "$br" type bridge
      sudo ip link set "$br" up
      echo "[OK] Created bridge $br"
    else
      fatal "Bridge $br does not exist; run with NET_CREATE=1" 13
    fi
  else
    echo "[OK] Bridge $br exists"
  fi
}

ensure_bridge "$PF_WAN_BRIDGE"
ensure_bridge "$PF_LAN_BRIDGE"

# Optionally enslave uplink into WAN bridge if PF_WAN_LINK is defined
if [[ -n "${PF_WAN_LINK:-}" ]]; then
  if ! brctl show "$PF_WAN_BRIDGE" 2>/dev/null | grep -q "$PF_WAN_LINK"; then
    sudo ip link set "$PF_WAN_LINK" master "$PF_WAN_BRIDGE" || echo "[WARN] Could not add $PF_WAN_LINK to $PF_WAN_BRIDGE"
  fi
fi

echo "[OK] Bridges ready: WAN=$PF_WAN_BRIDGE LAN=$PF_LAN_BRIDGE"
