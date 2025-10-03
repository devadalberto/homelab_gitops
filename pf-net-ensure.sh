#!/usr/bin/env bash
# Ensures pfSense bridges exist WITHOUT touching the host's SSH path (eno1/br0).
# Safe defaults: LAN=pfsense-lan, WAN=br0 for Option A (routed-on-a-stick). Idempotent.
# Optional flags:
#   --snapshot     : save current net state and netplan to ./net-snapshot-YYYYmmddHHMMSS.txt
#   --temp-lan-ip  : assign a temporary test IP (CIDR) to LAN bridge; cleans up on exit
#   --env-file F   : alternate env file path (default ./.env)

set -euo pipefail

ENV_FILE="./.env"
SNAPSHOT=false
TEMP_LAN_CIDR=""

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die() {
  err "$*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage: pf-net-ensure.sh [--snapshot] [--temp-lan-ip CIDR] [--env-file PATH]

Ensures PF_LAN_BRIDGE and PF_WAN_BRIDGE exist and are UP, without altering host NICs.
Never touches eno1 or br0. No netplan edits.

Options:
  --snapshot           Save a timestamped snapshot of netplan and live net state to ./net-snapshot-*.txt
  --temp-lan-ip CIDR   Temporarily add this IP/CIDR to PF_LAN_BRIDGE (e.g., 10.10.0.10/24). Removed on exit.
  --env-file PATH      Read variables from PATH instead of ./.env
  -h, --help           Show this help.

Recognized .env keys (with safe defaults):
  PF_VM_NAME                default: pfsense-uranus
  PF_LAN_BRIDGE             default: pfsense-lan
  PF_WAN_BRIDGE             default: br0   (Option A)
EOF
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
  --snapshot)
    SNAPSHOT=true
    shift
    ;;
  --temp-lan-ip)
    TEMP_LAN_CIDR="${2:-}"
    [[ -n "$TEMP_LAN_CIDR" ]] || die "--temp-lan-ip requires CIDR"
    shift 2
    ;;
  --env-file)
    ENV_FILE="${2:-}"
    [[ -n "$ENV_FILE" ]] || die "--env-file requires path"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "Unknown argument: $1" ;;
  esac
done

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }
for c in ip awk grep sed tee; do require_cmd "$c"; done

[[ -f "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"

# Load .env (accept KEY=VALUE lines; ignore comments/blank)
set -a
# shellcheck disable=SC1090
. <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sed 's/\r$//') || true
set +a

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-pfsense-lan}"
PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-br0}"

log "Using .env: $ENV_FILE"
log "PF_VM_NAME=$PF_VM_NAME"
log "PF_LAN_BRIDGE=$PF_LAN_BRIDGE"
log "PF_WAN_BRIDGE=$PF_WAN_BRIDGE"

# Detect current SSH path (interface that owns the default route)
ACTIVE_IF="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
log "Active route interface: ${ACTIVE_IF:-unknown}"

# Guard: never touch SSH uplink bridge or its lower iface
if [[ "${ACTIVE_IF:-}" == "br0" || "${ACTIVE_IF:-}" == "eno1" ]]; then
  log "Guard: SSH path via ${ACTIVE_IF:-unknown}. We will NOT modify br0 or eno1."
fi

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

ensure_bridge() {
  local br="$1"
  if ip link show "$br" >/dev/null 2>&1; then
    log "Bridge exists: $br"
  else
    log "Creating bridge: $br"
    ip link add name "$br" type bridge
  fi
  ip link set "$br" up
  log "Bridge up: $br"
}

cleanup() {
  if [[ -n "$TEMP_LAN_CIDR" ]]; then
    ip addr del "$TEMP_LAN_CIDR" dev "$PF_LAN_BRIDGE" >/dev/null 2>&1 || true
    log "Removed temporary IP $TEMP_LAN_CIDR from $PF_LAN_BRIDGE"
  fi
}
trap cleanup EXIT

# Optional snapshot
if "$SNAPSHOT"; then
  TS="$(date +%Y%m%d%H%M%S)"
  OUT="net-snapshot-${TS}.txt"
  {
    echo "=== DATE ==="
    date -u
    echo
    echo "=== /etc/netplan (if present) ==="
    if [ -d /etc/netplan ]; then
      find /etc/netplan -maxdepth 1 -type f -print -exec sh -c 'echo "--- {} ---"; sed -n "1,200p" "{}"' \; 2>/dev/null
    else
      echo "(no /etc/netplan dir)"
    fi
    echo
    echo "=== ip a ==="
    ip a
    echo
    echo "=== ip r ==="
    ip r
    echo
    echo "=== brctl show (if present) ==="
    if command -v brctl >/dev/null 2>&1; then brctl show; else echo "(no brctl)"; fi
  } >"$OUT"
  log "Wrote snapshot: $OUT"
fi

# Ensure bridges (safe: we will NOT touch br0 enslaving or its slaves)
ensure_bridge "$PF_LAN_BRIDGE"
ensure_bridge "$PF_WAN_BRIDGE"

# Optional temporary LAN IP for quick tests
if [[ -n "$TEMP_LAN_CIDR" ]]; then
  if ip addr add "$TEMP_LAN_CIDR" dev "$PF_LAN_BRIDGE" >/dev/null 2>&1; then
    log "Added temporary $TEMP_LAN_CIDR to $PF_LAN_BRIDGE (will be removed on exit)"
  else
    err "Could not add $TEMP_LAN_CIDR to $PF_LAN_BRIDGE"
  fi
fi

# Final summary
log "Final bridge state:"
ip -brief addr show "$PF_LAN_BRIDGE" || true
ip -brief addr show "$PF_WAN_BRIDGE" || true

log "Done. SSH path left untouched."
