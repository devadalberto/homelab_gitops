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

export XDG_CACHE_HOME=/root/.cache

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
need sudo; need virsh; need virt-install; need qemu-img; need gzip; need install; need ip; need awk; need grep; need sed; need ls

# -------- pick bridge --------
detect_bridge() {
  if [[ -n "${PF_LAN_BRIDGE}" ]]; then
    echo "${PF_LAN_BRIDGE}"; return 0
  fi
  local bridges cand
  bridges="$(ip -br link 2>/dev/null || true)"

  if printf '%s\n' "${bridges}" | awk '$1=="br0" && $2 ~ /UP/ {exit 0} END {exit 1}'; then
    echo "br0"
    return 0
  fi

  cand="$(
    printf '%s\n' "${bridges}" \
      | awk '$1!="br0" && $1 ~ /^br/ && $2 ~ /UP/ {print $1}' \
      | grep -Ev '^br-[0-9a-f]{12}$' \
      | head -n1 || true
  )"
  if [[ -n "${cand}" ]]; then
    echo "${cand}"
    return 0
  fi

  cand="$(
    printf '%s\n' "${bridges}" \
      | awk '$1 ~ /^virbr/ && $2 ~ /UP/ {print $1}' \
      | head -n1 || true
  )"
  if [[ -n "${cand}" ]]; then
    echo "${cand}"
    return 0
  fi

  if printf '%s\n' "${bridges}" | awk '$1=="br0" {exit 0} END {exit 1}'; then
    echo "br0"
    return 0
  fi

  die "No suitable UP bridge found. Bring up br0 or set PF_LAN_BRIDGE."
}
BRIDGE="$(detect_bridge)"
ok "Using bridge: ${BRIDGE}"

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

# -------- skip if domain exists --------
if sudo virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; then
  ok "Domain ${PF_VM_NAME} already exists; skipping create"
  exit 0
fi

# -------- osinfo handling --------
OSINFO_ARG="--osinfo ${PF_OSINFO}"
if ! virt-install --osinfo list | awk '{print $1}' | grep -qx "${PF_OSINFO}"; then
  warn "OSINFO ${PF_OSINFO} not present; using detect=on,require=off"
  OSINFO_ARG="--osinfo detect=on,require=off"
fi

# -------- create VM --------
info "Creating domain ${PF_VM_NAME} (serial-only, virtio, bridge=${BRIDGE})"
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
  --network "bridge=${BRIDGE},model=virtio"
set +x

ok "Domain ${PF_VM_NAME} created. Finish install over serial, then detach installer:"
echo "  sudo virsh detach-disk ${PF_VM_NAME} ${PF_INSTALLER_DEST} --config --persistent || true"
echo "  sudo virsh start ${PF_VM_NAME} || true"
echo "  sudo virsh console ${PF_VM_NAME}"
