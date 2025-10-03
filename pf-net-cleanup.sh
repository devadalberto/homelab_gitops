#!/usr/bin/env bash
# pf-net-cleanup.sh — Uranus homelab networking + pfSense housekeeping (FINAL)
# - Backs up current netplans (timestamped)
# - Disables cloud-init networking (prevents overwrites)
# - Normalizes odd filenames (handles comma case safely)
# - Replaces with clean bridges ONLY:
#     br0 (WAN): eno1 enslaved, static 192.168.88.12/24, gw 192.168.88.1
#     pfsense-lan (LAN): pure bridge, static 10.10.0.2/24, no gateway
# - Removes/cleans up br1 if present (runtime)
# - Applies netplan (non-interactive) and verifies
# - pfSense VM: autostart enable + detach installer disk (if attached)
# - Prints final status and verification
#
# Run:  bash pf-net-cleanup.sh
# Safe to re-run: idempotent where possible.

set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() {
  echo "[FATAL] $*" >&2
  exit 1
}

# --- Sanity checks ---
command -v netplan >/dev/null || die "netplan not found"
command -v virsh >/dev/null || die "virsh (libvirt) not found"
ip link show eno1 >/dev/null 2>&1 || die "Interface eno1 not found. Adjust WAN_IF in this script."

# --- Vars (hardcoded for this one-time run) ---
WAN_IF="eno1"
WAN_BR="br0"
WAN_IP_CIDR="192.168.88.12/24"
WAN_GW="192.168.88.1"

LAN_BR="pfsense-lan"
LAN_IP_CIDR="10.10.0.2/24"

SEARCH_DOMAIN="home.arpa"
DNS1="1.1.1.1"
DNS2="9.9.9.9"

PF_VM="pfsense-uranus"
PF_INSTALLER_IMG="/opt/homelab/pfsense/installer.img"

# --- Ensure directories exist ---
sudo mkdir -p /etc/netplan
sudo mkdir -p /etc/cloud/cloud.cfg.d
sudo mkdir -p /root/netplan-backups

BACKUP_DIR="/root/netplan-backups/netplan_$(date +%F_%H-%M-%S)"

# --- Backup current netplans (even if empty) ---
log "Backing up /etc/netplan -> $BACKUP_DIR"
sudo mkdir -p "$BACKUP_DIR"
shopt -s nullglob
NP_FILES=(/etc/netplan/*.yaml)
if ((${#NP_FILES[@]})); then
  sudo cp -a /etc/netplan/*.yaml "$BACKUP_DIR"/
else
  log "No existing netplan YAMLs to back up (directory empty)."
fi
shopt -u nullglob

# --- Disable cloud-init networking to stop future overwrites ---
log "Disabling cloud-init networking"
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg >/dev/null
echo "# disabled by /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg" | sudo tee /etc/netplan/50-cloud-init.yaml >/dev/null

# --- Normalize odd filename if present (comma variant) ---
if [ -f "/etc/netplan/99-pfsense,yaml" ]; then
  log "Renaming '/etc/netplan/99-pfsense,yaml' -> '/etc/netplan/99-pfsense.yaml'"
  sudo mv "/etc/netplan/99-pfsense,yaml" "/etc/netplan/99-pfsense.yaml"
fi

# --- Move aside existing netplans except the placeholder we just wrote ---
log "Moving aside existing netplan YAMLs (except 50-cloud-init.yaml)"
shopt -s nullglob
for f in /etc/netplan/*.yaml; do
  base="$(basename "$f")"
  if [ "$base" != "50-cloud-init.yaml" ]; then
    sudo mv "$f" "$BACKUP_DIR"/
  fi
done
shopt -u nullglob

# --- Create clean WAN bridge (br0) with eno1 enslaved and static IP ---
log "Writing /etc/netplan/60-br0-wan.yaml"
sudo tee /etc/netplan/60-br0-wan.yaml >/dev/null <<YAML
network:
  version: 2
  renderer: networkd
  ethernets:
    ${WAN_IF}:
      dhcp4: false
      dhcp6: false
  bridges:
    ${WAN_BR}:
      interfaces: [${WAN_IF}]
      dhcp4: false
      dhcp6: false
      addresses: [${WAN_IP_CIDR}]
      gateway4: ${WAN_GW}
      nameservers:
        search: [${SEARCH_DOMAIN}]
        addresses: [${DNS1}, ${DNS2}]
      parameters:
        stp: false
        forward-delay: 0
      link-local: []
YAML

# --- Create clean LAN bridge (pfsense-lan) with static IP (no gateway) ---
log "Writing /etc/netplan/70-pfsense-lan.yaml"
sudo tee /etc/netplan/70-pfsense-lan.yaml >/dev/null <<YAML
network:
  version: 2
  renderer: networkd
  bridges:
    ${LAN_BR}:
      interfaces: []
      dhcp4: false
      dhcp6: false
      addresses: [${LAN_IP_CIDR}]
      parameters:
        stp: false
        forward-delay: 0
      link-local: []
YAML

# --- Remove stray br1 device if present at runtime ---
if ip link show br1 >/dev/null 2>&1; then
  log "Deleting stray br1 bridge"
  sudo ip link set br1 down || true
  sudo ip link delete br1 type bridge || true
fi

# --- Validate & apply netplan ---
log "Validating netplan"
sudo netplan generate

log "Applying netplan via 'netplan apply'"
sudo netplan apply || warn "netplan apply returned non-zero; verifying state anyway"

# --- pfSense VM housekeeping ---
log "Ensuring pfSense VM autostart: ${PF_VM}"
if virsh dominfo "${PF_VM}" >/dev/null 2>&1; then
  sudo virsh autostart "${PF_VM}" || warn "Could not set autostart (check VM permissions)"
else
  warn "VM '${PF_VM}' not found; skipping autostart."
fi

log "Detaching installer disk if attached: ${PF_INSTALLER_IMG}"
if virsh domblklist "${PF_VM}" >/dev/null 2>&1; then
  if sudo virsh domblklist "${PF_VM}" | awk '{print $2}' | grep -qx "${PF_INSTALLER_IMG}"; then
    sudo virsh detach-disk "${PF_VM}" "${PF_INSTALLER_IMG}" --persistent || warn "detach-disk failed"
  else
    log "Installer disk not attached; nothing to do."
  fi
else
  warn "Cannot query VM block devices (VM may not exist or libvirt perms)."
fi

# --- Status outputs ---
echo
echo "=== Runtime status ==="
log "Netplan files now present:"
ls -1 /etc/netplan/ || true

log "Host addresses:"
ip -4 addr show "${WAN_BR}" || true
ip -4 addr show "${LAN_BR}" || true

log "Default route:"
ip route | awk 'NR==1{print;exit}'

echo
log "pfSense VM block devices:"
if virsh domblklist "${PF_VM}" >/dev/null 2>&1; then
  sudo virsh domblklist "${PF_VM}" || true
else
  warn "Cannot list VM block devices; VM not found?"
fi

# --- Verification tests ---
echo
log "Testing pfSense LAN reachability (10.10.0.1)"
if ping -c2 -W2 10.10.0.1 >/dev/null 2>&1; then
  log "OK: Reached 10.10.0.1"
else
  warn "Could not reach 10.10.0.1 yet. If pfSense is still booting, try again in a few seconds."
fi

log "Testing WAN reachability (1.1.1.1)"
if ping -c2 -W2 1.1.1.1 >/dev/null 2>&1; then
  log "OK: Reached 1.1.1.1"
else
  warn "Could not reach 1.1.1.1. Check upstream connectivity."
fi

echo
log "Autostart status:"
if virsh dominfo "${PF_VM}" >/dev/null 2>&1; then
  virsh dominfo "${PF_VM}" | awk -F': *' '/Autostart/{print "Autostart:",$2}'
else
  warn "Cannot query VM autostart; VM not found?"
fi

echo
log "Done."
