#!/usr/bin/env bash
set -euo pipefail

# homelab_reset_and_build.sh
# Wipe everything except OS and Docker; then rebuild homelab successfully.

# ======== CONFIG YOU CAN TWEAK ========
REPO_ROOT="$(pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"

# Homelab desired canonical bridges
PF_LAN_BRIDGE_DESIRED="pfsense-lan"
PF_WAN_BRIDGE_DESIRED="pfsense-wan"

# LAN addressing to use
LAN_CIDR_DEFAULT="10.10.0.0/24"
LAN_GW_DEFAULT="10.10.0.1"
LAN_DHCP_FROM_DEFAULT="10.10.0.100"
LAN_DHCP_TO_DEFAULT="10.10.0.200"

# pfSense serial installer path (as per your earlier messages)
DEFAULT_INSTALLER="$HOME/downloads/netgate-installer-amd64.img.gz"

# Safety: keep libvirt default network unless you really want to drop it
PRESERVE_LIBVIRT_DEFAULT_NET="1"

# You can turn this off if you accept all destructive actions without prompts
ASSUME_YES="${ASSUME_YES:-1}"

# ======== UTILS ========
log() { printf '[%(%Y-%m-%dT%H:%M:%S%z)T] %s\n' -1 "$*"; }
ok() { log "OK: $*"; }
warn() { log "WARN: $*" >&2; }
die() {
  log "FATAL: $*" >&2
  exit 1
}

confirm() {
  if [[ "${ASSUME_YES}" = "1" ]]; then return 0; fi
  read -r -p "$1 [y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"
}

# Determine if a device is likely physical (e.g., enpXsY, ethX, wlpXsY…)
is_physical_dev() {
  local dev="$1"
  # Heuristic: if it has a device directory with a vendor, assume physical
  [[ -e "/sys/class/net/${dev}/device/vendor" ]] && return 0
  return 1
}

bridge_has_physical_uplink() {
  local br="$1"
  local ifdir="/sys/class/net/${br}/brif"
  [[ -d "$ifdir" ]] || return 1
  local upl
  for upl in "$ifdir"/*; do
    [[ -e "$upl" ]] || continue
    local u="$(basename "$upl")"
    if is_physical_dev "$u"; then
      return 0
    fi
  done
  return 1
}

# ======== PRECHECKS ========
log "Starting homelab full reset (preserve OS + Docker)…"
require_cmd ip
require_cmd brctl || warn "brctl not found; using 'ip link delete' fallback"
require_cmd awk
require_cmd grep
require_cmd make

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y >/dev/null 2>&1 || true
  sudo apt-get install -y libvirt-clients libvirt-daemon-system qemu-kvm virtinst xmlstarlet xorriso genisoimage >/dev/null 2>&1 || true
fi

# libvirt tools are optional but recommended (we’ll gate their usage)
if command -v virsh >/dev/null 2>&1; then
  ok "libvirt present"
else
  warn "libvirt tooling (virsh) not found; VM and libvirt network cleanup will be skipped."
fi

# Ensure we’re at the repo root (Makefile should exist)
[[ -f "${REPO_ROOT}/Makefile" ]] || die "Makefile not found in $(pwd). Run this script from your homelab_gitops repo root."

# ======== BACKUP .env ========
if [[ -f "${ENV_FILE}" ]]; then
  TS="$(date +%Y%m%d%H%M%S)"
  cp -a "${ENV_FILE}" "${ENV_FILE}.bak.${TS}"
  ok "Backed up ${ENV_FILE} -> ${ENV_FILE}.bak.${TS}"
fi

# ======== WIPE: libvirt domains (VMs) ========
if command -v virsh >/dev/null 2>&1; then
  log "Enumerating libvirt domains…"
  mapfile -t DOMAINS < <(sudo virsh list --all --name | sed '/^$/d' || true)
  if ((${#DOMAINS[@]})); then
    log "Will destroy and undefine libvirt domains: ${DOMAINS[*]}"
    if confirm "Proceed removing ALL libvirt VMs and their storage?"; then
      for d in "${DOMAINS[@]}"; do
        log "Destroying domain: $d (if running)"
        sudo virsh destroy "$d" >/dev/null 2>&1 || true
        log "Undefining domain: $d (with storage)"
        sudo virsh undefine "$d" --remove-all-storage >/dev/null 2>&1 || true
      done
      ok "All libvirt domains removed"
    else
      warn "Skipped VM removal by user choice."
    fi
  else
    ok "No libvirt domains found."
  fi
fi

# ======== WIPE: libvirt host interfaces ========
if command -v virsh >/dev/null 2>&1; then
  log "Enumerating libvirt-defined host interfaces…"
  mapfile -t IFACES < <(sudo virsh iface-list --all 2>/dev/null | awk 'NR>2 && $1!="" {print $1}' || true)
  if ((${#IFACES[@]})); then
    log "Will undefine libvirt interfaces: ${IFACES[*]}"
    for i in "${IFACES[@]}"; do
      sudo virsh iface-unbridge "$i" >/dev/null 2>&1 || true
      sudo virsh iface-destroy "$i" >/dev/null 2>&1 || true
      sudo virsh iface-undefine "$i" >/dev/null 2>&1 || true
    done
    ok "Libvirt host interfaces removed"
  else
    ok "No libvirt host interfaces found."
  fi
fi

# ======== WIPE: libvirt networks (except default if preserved) ========
if command -v virsh >/dev/null 2>&1; then
  log "Enumerating libvirt networks…"
  mapfile -t NETS < <(sudo virsh net-list --all | awk 'NR>2 && $1!="" {print $1}' || true)
  if ((${#NETS[@]})); then
    for n in "${NETS[@]}"; do
      if [[ "${PRESERVE_LIBVIRT_DEFAULT_NET}" = "1" && "${n}" == "default" ]]; then
        log "Preserving libvirt network: default"
        continue
      fi
      log "Removing libvirt network: $n"
      sudo virsh net-destroy "$n" >/dev/null 2>&1 || true
      sudo virsh net-undefine "$n" >/dev/null 2>&1 || true
    done
    ok "Libvirt networks cleaned"
  else
    ok "No libvirt networks found."
  fi
fi

# ======== WIPE: host Linux bridges (safe) ========
log "Scanning host Linux bridges…"
mapfile -t BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2}' || true)
if ((${#BRIDGES[@]})); then
  for br in "${BRIDGES[@]}"; do
    case "$br" in
    docker0 | br-*) # Docker default and per-network bridges
      log "Preserving Docker bridge: $br"
      continue
      ;;
    esac
    if bridge_has_physical_uplink "$br"; then
      log "Preserving OS bridge with physical uplink: $br"
      continue
    fi
    log "Deleting host bridge (no physical uplink, non-Docker): $br"
    sudo ip link set "$br" down || true
    if command -v brctl >/dev/null 2>&1; then
      sudo brctl delbr "$br" || true
    else
      sudo ip link delete "$br" type bridge || true
    fi
  done
  ok "Host bridges cleaned (except Docker and OS-critical)."
else
  ok "No host bridges found."
fi

# ======== CLEAN: pfSense artifacts ========
PF_BASE="/opt/homelab/pfsense"
if [[ -d "$PF_BASE" ]]; then
  log "Cleaning pfSense artifacts under $PF_BASE"
  sudo rm -rf "$PF_BASE/config/"*.iso "$PF_BASE/config/"*.img "$PF_BASE/config/config.xml" 2>/dev/null || true
  ok "pfSense artifacts removed (config, ISOs, images)."
fi

# ======== REBUILD: .env ========
log "Rewriting ${ENV_FILE} with canonical homelab values…"

PF_INSTALLER_SRC_VALUE="${PF_INSTALLER_SRC:-$DEFAULT_INSTALLER}"
[[ -f "$PF_INSTALLER_SRC_VALUE" ]] || warn "Installer not found at $PF_INSTALLER_SRC_VALUE. You must place netgate-installer-amd64.img.gz there before the pfSense ZTP stage."

cat >"${ENV_FILE}" <<EOF
# Autogenerated by homelab_reset_and_build.sh
PF_VM_NAME=pfsense-uranus
PF_LAN_BRIDGE=${PF_LAN_BRIDGE_DESIRED}
PF_WAN_BRIDGE=${PF_WAN_BRIDGE_DESIRED}

LAN_CIDR=${LAN_CIDR_DEFAULT}
LAN_GW_IP=${LAN_GW_DEFAULT}
LAN_DHCP_FROM=${LAN_DHCP_FROM_DEFAULT}
LAN_DHCP_TO=${LAN_DHCP_TO_DEFAULT}

# Serial installer image (.img.gz) for pfSense/Netgate
PF_INSTALLER_SRC=${PF_INSTALLER_SRC_VALUE}

# Optional: legacy var support for scripts that still check this key
PF_SERIAL_INSTALLER_PATH=${PF_INSTALLER_SRC_VALUE}
EOF
ok "Wrote ${ENV_FILE}"

log "Effective .env:"
grep -E '^(PF_|LAN_)' "${ENV_FILE}" || true

# ======== ENSURE: repo scripts executable ========
chmod +x "${REPO_ROOT}"/scripts/*.sh 2>/dev/null || true
chmod +x "${REPO_ROOT}"/pfsense/*.sh 2>/dev/null || true

# ======== CREATE ONLY WHAT WE NEED (bridges, etc.) ========
# Prefer to let repo's net-ensure.sh create canonical bridges
if [[ -x "${REPO_ROOT}/scripts/net-ensure.sh" ]]; then
  log "Ensuring canonical homelab bridges via scripts/net-ensure.sh…"
  sudo "${REPO_ROOT}/scripts/net-ensure.sh" --env-file "${ENV_FILE}"
  ok "Canonical bridges ensured."
else
  warn "scripts/net-ensure.sh not found; creating bridges directly."
  for br in "${PF_LAN_BRIDGE_DESIRED}" "${PF_WAN_BRIDGE_DESIRED}"; do
    if ! ip link show "$br" >/dev/null 2>&1; then
      log "Creating bridge: $br"
      sudo ip link add name "$br" type bridge
      sudo ip link set "$br" up
    else
      log "Bridge already present: $br"
    fi
  done
fi

# ======== BOOTSTRAP HOMELAB ========
log "Running full bootstrap: make up"
# Most repos expect sudo during pfSense stages; make handles sudo inside scripts.
MAKE_ENV_FILE="${ENV_FILE}"
export ENV_FILE="${MAKE_ENV_FILE}"

# Show plan line, then run
log "Using environment file ${ENV_FILE}"
make -n up || true
make up

ok "Homelab bootstrap finished."
