#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export BOOT_STATE="/root/.uranus_bootstrap_state"

# shellcheck disable=SC1091
[[ -f "$DIR/.env" ]] && source "$DIR/.env" || source "$DIR/.env.example"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

# 1) Host prep (skip docker if docker-ce present)
"$DIR/scripts/host-prep.sh"

# 2) br0 (or skip if macvtap)
if [[ "${WAN_MODE:-br0}" == "br0" ]]; then
  if [[ ! -f "$BOOT_STATE" ]]; then
    log "Configuring br0 bridge on ${WAN_NIC} ... system will reboot once"
    "$DIR/scripts/net-bridge.sh" "${WAN_NIC}"
    exit 0
  fi
fi

# 3) pfSense VM + config.xml
make -C "$DIR" pfSense

# 4) Kubernetes core + data + awx + observability + apps + flux
make -C "$DIR" all
