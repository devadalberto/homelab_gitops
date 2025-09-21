#!/usr/bin/env bash
set -euo pipefail

log()   { printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()   { log "[ERROR] $*"; exit 1; }
info()  { log "[INFO] $*"; }
ok()    { log "[OK] $*"; }
warn()  { log "[WARN] $*"; }

# -------- args & env --------
ENV_FILE=""
PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-}"
PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_OSINFO="${PF_OSINFO:-freebsd14.2}"
PF_QCOW2_PATH="${PF_QCOW2_PATH:-/var/lib/libvirt/images/pfsense-uranus.qcow2}"
PF_QCOW2_SIZE_GB="${PF_QCOW2_SIZE_GB:-20}"
PF_INSTALLER_DEST="${PF_INSTALLER_DEST:-/var/lib/libvirt/images/netgate-installer-amd64.img}"

# Simple flag parser
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file|-e) ENV_FILE="${2:-}"; shift 2;;
    --installer|--installer-src) PF_INSTALLER_SRC="${2:-}"; shift 2;;
    --bridge) PF_LAN_BRIDGE="${2:-}"; shift 2;;
    --vm-name) PF_VM_NAME="${2:-}"; shift 2;;
    *) shift;;
  esac
done

if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  info "Loading environment from ${ENV_FILE}"
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-br0}"

export XDG_CACHE_HOME=/root/.cache

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
need sudo; need virsh; need virt-install; need qemu-img; need gzip; need install; need ip; need awk; need grep; need sed; need ls

# -------- pick bridges --------
detect_lan_bridge() {
  local configured="${PF_LAN_BRIDGE:-}"
  if [[ -n "${configured}" ]]; then
    echo "${configured}"; return 0
  fi
  if ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -qx "br0"; then
    echo "br0"; return 0
  fi
  local cand=""
  cand="$(
    ip -br link 2>/dev/null \
      | awk '$2=="UP"{print $1}' \
      | grep -E '^br|^virbr' \
      | grep -Ev '^br-[0-9a-f]{12}$' \
      | head -n1 || true
  )"
  if [[ -n "${cand}" ]]; then
    echo "${cand}"; return 0
  fi
  if ip -br link 2>/dev/null | awk '{print $1}' | grep -qx "br0"; then
    echo "br0"; return 0
  fi
  die "No suitable LAN bridge found. Bring up br0 or set PF_LAN_BRIDGE."
}

require_bridge() {
  local bridge="$1" label="$2"
  if [[ -z "${bridge}" ]]; then
    die "${label} bridge is empty"
  fi
  if ! ip -br link 2>/dev/null | awk '{print $1}' | grep -Fxq "${bridge}"; then
    die "${label} bridge '${bridge}' not found. Set PF_${label}_BRIDGE or create it."
  fi
}

PF_LAN_BRIDGE="$(detect_lan_bridge)"
require_bridge "${PF_WAN_BRIDGE}" "WAN"
require_bridge "${PF_LAN_BRIDGE}" "LAN"

ok "Using WAN bridge: ${PF_WAN_BRIDGE}"
ok "Using LAN bridge: ${PF_LAN_BRIDGE}"

domain_has_bridge() {
  local domain="$1" bridge="$2"
  sudo virsh domiflist "${domain}" 2>/dev/null \
    | awk -v needle="${bridge}" 'NR>2 && NF>=3 && $3==needle {exit 0} END{exit 1}'
}

domain_is_live() {
  local domain="$1" state=""
  state="$(sudo virsh domstate "${domain}" 2>/dev/null | tr -d '\r')"
  state="${state%% *}"
  case "${state}" in
    running|idle|blocked|paused) return 0 ;;
    *) return 1 ;;
  esac
}

attach_bridge_if_missing() {
  local domain="$1" bridge="$2" label="$3"
  if domain_has_bridge "${domain}" "${bridge}"; then
    ok "${label} bridge ${bridge} already attached to ${domain}"
    return 0
  fi
  info "Attaching ${label} bridge ${bridge} to ${domain}"
  local args=(
    sudo virsh attach-interface
    --domain "${domain}"
    --type bridge
    --source "${bridge}"
    --model virtio
    --config
  )
  if domain_is_live "${domain}"; then
    args+=(--live)
  fi
  "${args[@]}"
  ok "Attached ${label} bridge ${bridge} to ${domain}"
}

verify_bridge_present() {
  local domain="$1" bridge="$2" label="$3"
  if domain_has_bridge "${domain}" "${bridge}"; then
    return 0
  fi
  die "${label} bridge '${bridge}' is not attached to ${domain}"
}

# -------- locate installer --------
# Accept both serial and non-serial names, .img.gz or .img, and search common dirs
locate_installer() {
  local explicit="${PF_INSTALLER_SRC:-}"
  if [[ -n "${explicit}" ]]; then
    if [[ -f "${explicit}" ]]; then echo "${explicit}"; return 0; fi
    # try toggle .gz
    if [[ "${explicit}" == *.gz && -f "${explicit%.gz}" ]]; then echo "${explicit%.gz}"; return 0; fi
    if [[ "${explicit}" != *.gz && -f "${explicit}.gz" ]]; then echo "${explicit}.gz"; return 0; fi
    warn "PF_INSTALLER_SRC points to '${explicit}', not found; falling back to auto-discovery."
  fi

  # Candidate basenames (ordered)
  local names=(
    "netgate-installer-amd64-serial.img.gz"
    "netgate-installer-amd64.img.gz"
    "netgate-installer-amd64-serial.img"
    "netgate-installer-amd64.img"
  )
  local dirs=(
    "$HOME/downloads"
    "/opt/homelab/pfsense"
    "/var/lib/libvirt/images"
  )

  # exact names first
  for d in "${dirs[@]}"; do
    for n in "${names[@]}"; do
      if [[ -f "${d}/${n}" ]]; then echo "${d}/${n}"; return 0; fi
    done
  done

  # last resort: any netgate*amd64*.img* by mtime
  local any=""
  any="$(ls -1t "$HOME"/downloads/netgate*amd64*.img* 2>/dev/null | head -n1 || true)"
  if [[ -z "${any}" ]]; then any="$(ls -1t /opt/homelab/pfsense/netgate*amd64*.img* 2>/dev/null | head -n1 || true)"; fi
  if [[ -z "${any}" ]]; then any="$(ls -1t /var/lib/libvirt/images/netgate*amd64*.img* 2>/dev/null | head -n1 || true)"; fi
  [[ -n "${any}" ]] || die "Installer not found. Place one of: ${names[*]} under: ${dirs[*]} or set PF_INSTALLER_SRC."
  echo "${any}"
}

prepare_installer() {
  local src dest
  src="$(locate_installer)"
  PF_INSTALLER_SRC="${src}"
  ok "Installer source: ${PF_INSTALLER_SRC}"
  dest="${PF_INSTALLER_DEST}"
  sudo mkdir -p "$(dirname "${dest}")"
  if [[ "${src}" == *.gz ]]; then
    info "Verifying and expanding ${src} -> ${dest}"
    gzip -t "${src}"
    gunzip -c "${src}" | sudo tee "${dest}" >/dev/null
  else
    info "Copying ${src} -> ${dest}"
    sudo install -D -m 0644 "${src}" "${dest}"
  fi
  sudo test -s "${dest}" || die "Expanded installer at ${dest} is empty"
}
prepare_installer

# -------- qcow2 --------
if ! sudo test -f "${PF_QCOW2_PATH}"; then
  info "Creating qcow2 ${PF_QCOW2_PATH} (${PF_QCOW2_SIZE_GB}G)"
  sudo qemu-img create -f qcow2 "${PF_QCOW2_PATH}" "${PF_QCOW2_SIZE_GB}G" >/dev/null
else
  ok "Reusing qcow2 ${PF_QCOW2_PATH}"
fi

# -------- ensure domain --------
if sudo virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; then
  ok "Domain ${PF_VM_NAME} already exists; ensuring bridge configuration"
else
  # -------- osinfo handling --------
  OSINFO_ARG="--osinfo ${PF_OSINFO}"
  if ! virt-install --osinfo list | awk '{print $1}' | grep -qx "${PF_OSINFO}"; then
    warn "OSINFO ${PF_OSINFO} not present; using detect=on,require=off"
    OSINFO_ARG="--osinfo detect=on,require=off"
  fi

  # -------- create VM --------
  info "Creating domain ${PF_VM_NAME} (serial-only, virtio, WAN=${PF_WAN_BRIDGE}, LAN=${PF_LAN_BRIDGE})"
  set -x
  sudo virt-install \
    --connect qemu:///system \
    --name "${PF_VM_NAME}" \
    --memory 4096 \
    --vcpus 2 \
    --cpu host \
    ${OSINFO_ARG} \
    --import \
    --boot hd,menu=on,useserial=on \
    --graphics none \
    --console pty,target_type=serial \
    --disk "path=${PF_INSTALLER_DEST},format=raw,readonly=on,boot.order=1" \
    --disk "path=${PF_QCOW2_PATH},format=qcow2,boot.order=2" \
    --network "bridge=${PF_WAN_BRIDGE},model=virtio" \
    --network "bridge=${PF_LAN_BRIDGE},model=virtio"
  set +x

  ok "Domain ${PF_VM_NAME} created. Finish install over serial, then detach installer:"
  echo "  sudo virsh detach-disk ${PF_VM_NAME} ${PF_INSTALLER_DEST} --config --persistent || true"
  echo "  sudo virsh start ${PF_VM_NAME} || true"
  echo "  sudo virsh console ${PF_VM_NAME}"
fi

attach_bridge_if_missing "${PF_VM_NAME}" "${PF_WAN_BRIDGE}" "WAN"
attach_bridge_if_missing "${PF_VM_NAME}" "${PF_LAN_BRIDGE}" "LAN"

verify_bridge_present "${PF_VM_NAME}" "${PF_WAN_BRIDGE}" "WAN"
verify_bridge_present "${PF_VM_NAME}" "${PF_LAN_BRIDGE}" "LAN"

info "Current interfaces for ${PF_VM_NAME}:"
sudo virsh domiflist "${PF_VM_NAME}"
