#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()   { printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()   { log "[ERROR] $*"; exit 1; }
info()  { log "[INFO] $*"; }
ok()    { log "[OK] $*"; }
warn()  { log "[WARN] $*"; }

usage() {
  cat <<'USAGE' >&2
Usage: scripts/pf-vm-install.sh [options]
  --env-file FILE          Source FILE for environment variables.
  --installer PATH         Path to the Netgate installer image (.img or .img.gz).
  --installer-src PATH     Alias for --installer.
  --installer-dest PATH    Destination path for the expanded installer image.
  --wan-bridge NAME        Bridge device for the WAN NIC.
  --lan-bridge NAME        Bridge device for the LAN NIC.
  --bridge NAME            Backwards compatible alias for --lan-bridge.
  --vm-name NAME           Name of the libvirt domain to create or update.
  --qcow2-path PATH        Destination path for the VM qcow2 disk.
  --qcow2-size-gb SIZE     Size (in GB) for the qcow2 disk when created.
  --osinfo ID              virt-install osinfo identifier (default freebsd14.2).
  -h, --help               Show this help text.
USAGE
}

ENV_FILE="${ENV_FILE:-}"
ENV_LOADED=false

PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
PF_INSTALLER_DEST="${PF_INSTALLER_DEST:-/var/lib/libvirt/images/netgate-installer-amd64.img}"
PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_OSINFO="${PF_OSINFO:-freebsd14.2}"
PF_QCOW2_PATH="${PF_QCOW2_PATH:-/var/lib/libvirt/images/pfsense-uranus.qcow2}"
PF_QCOW2_SIZE_GB="${PF_QCOW2_SIZE_GB:-20}"
PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-}"

load_env_file() {
  local file="$1"
  [[ -n "${file}" ]] || return 0
  [[ -f "${file}" ]] || die "Environment file '${file}' not found"
  info "Loading environment from ${file}"
  # shellcheck disable=SC1090
  source "${file}"
  ENV_LOADED=true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file|-e)
      ENV_FILE="${2:-}"
      shift 2 || die "Missing value for --env-file"
      load_env_file "${ENV_FILE}"
      ;;
    --installer|--installer-src)
      PF_INSTALLER_SRC="${2:-}"
      shift 2 || die "Missing value for --installer"
      ;;
    --installer-dest)
      PF_INSTALLER_DEST="${2:-}"
      shift 2 || die "Missing value for --installer-dest"
      ;;
    --wan-bridge)
      PF_WAN_BRIDGE="${2:-}"
      shift 2 || die "Missing value for --wan-bridge"
      ;;
    --lan-bridge|--bridge)
      PF_LAN_BRIDGE="${2:-}"
      shift 2 || die "Missing value for --lan-bridge"
      ;;
    --vm-name)
      PF_VM_NAME="${2:-}"
      shift 2 || die "Missing value for --vm-name"
      ;;
    --qcow2-path)
      PF_QCOW2_PATH="${2:-}"
      shift 2 || die "Missing value for --qcow2-path"
      ;;
    --qcow2-size-gb)
      PF_QCOW2_SIZE_GB="${2:-}"
      shift 2 || die "Missing value for --qcow2-size-gb"
      ;;
    --osinfo)
      PF_OSINFO="${2:-}"
      shift 2 || die "Missing value for --osinfo"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "${ENV_FILE}" && -n "${PF_ENV_FILE:-}" ]]; then
  ENV_FILE="${PF_ENV_FILE}"
fi

if [[ "${ENV_LOADED}" != true && -n "${ENV_FILE}" ]]; then
  load_env_file "${ENV_FILE}"
fi

PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-br0}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-${PF_WAN_BRIDGE}}"

[[ -n "${PF_VM_NAME}" ]] || die "PF_VM_NAME is empty"
[[ -n "${PF_INSTALLER_DEST}" ]] || die "PF_INSTALLER_DEST is empty"
[[ -n "${PF_QCOW2_PATH}" ]] || die "PF_QCOW2_PATH is empty"
[[ "${PF_QCOW2_SIZE_GB}" =~ ^[0-9]+$ ]] || die "PF_QCOW2_SIZE_GB must be an integer"

export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

need sudo
need virsh
need virt-install
need qemu-img
need gzip
need gunzip
need install
need ip
need awk
need grep
need sed
need cmp
need mktemp

ensure_bridge() {
  local label="$1" bridge="$2"
  [[ -n "${bridge}" ]] || die "${label} bridge name is empty"
  info "Ensuring ${label} bridge '${bridge}' exists"
  "${SCRIPT_DIR}/net-ensure-bridge.sh" "${bridge}"
}

ensure_bridge "WAN" "${PF_WAN_BRIDGE}"
ensure_bridge "LAN" "${PF_LAN_BRIDGE}"

locate_installer() {
  local explicit="${PF_INSTALLER_SRC:-}"
  if [[ -n "${explicit}" ]]; then
    if [[ -f "${explicit}" ]]; then
      echo "${explicit}"
      return 0
    fi
    if [[ "${explicit}" == *.gz && -f "${explicit%.gz}" ]]; then
      echo "${explicit%.gz}"
      return 0
    fi
    if [[ "${explicit}" != *.gz && -f "${explicit}.gz" ]]; then
      echo "${explicit}.gz"
      return 0
    fi
    warn "Installer '${explicit}' not found; falling back to search"
  fi

  local -a names=(
    "netgate-installer-amd64-serial.img.gz"
    "netgate-installer-amd64.img.gz"
    "netgate-installer-amd64-serial.img"
    "netgate-installer-amd64.img"
  )
  local -a dirs=(
    "$HOME/downloads"
    "/opt/homelab/pfsense"
    "/var/lib/libvirt/images"
  )

  local d n
  for d in "${dirs[@]}"; do
    for n in "${names[@]}"; do
      if [[ -f "${d}/${n}" ]]; then
        echo "${d}/${n}"
        return 0
      fi
    done
  done

  local any=""
  for d in "${dirs[@]}"; do
    if any=$(ls -1t "${d}"/netgate*amd64*.img* 2>/dev/null | head -n1); then
      if [[ -n "${any}" ]]; then
        echo "${any}"
        return 0
      fi
    fi
  done

  die "Installer image not found. Place a Netgate installer under one of: ${dirs[*]} or set PF_INSTALLER_SRC."
}

sync_file() {
  local src="$1" dest="$2" label="$3"
  sudo install -d "$(dirname "${dest}")"
  if sudo test -f "${dest}" && sudo cmp -s "${src}" "${dest}"; then
    ok "${label} '${dest}' already up to date"
  else
    info "Writing ${label} to ${dest}"
    sudo install -m 0644 "${src}" "${dest}"
  fi
}

prepare_installer() {
  local src dest tmp
  src="$(locate_installer)"
  dest="${PF_INSTALLER_DEST}"
  PF_INSTALLER_SRC="${src}"
  info "Using installer source: ${PF_INSTALLER_SRC}"
  if [[ "${src}" == *.gz ]]; then
    tmp="$(mktemp)"
    gunzip -c "${src}" > "${tmp}"
    sync_file "${tmp}" "${dest}" "Installer"
    rm -f "${tmp}"
  else
    sync_file "${src}" "${dest}" "Installer"
  fi
  sudo chmod 0644 "${dest}"
  sudo test -s "${dest}" || die "Expanded installer '${dest}' is empty"
}

prepare_installer

ensure_qcow2() {
  local path="$1" size_gb="$2"
  sudo install -d "$(dirname "${path}")"
  if sudo test -f "${path}"; then
    ok "Reusing qcow2 disk at ${path}"
  else
    info "Creating qcow2 disk ${path} (${size_gb}G)"
    sudo qemu-img create -f qcow2 "${path}" "${size_gb}G" >/dev/null
  fi
}

ensure_qcow2 "${PF_QCOW2_PATH}" "${PF_QCOW2_SIZE_GB}"

domain_exists() {
  local domain="$1"
  sudo virsh dominfo "${domain}" >/dev/null 2>&1
}

domain_is_live() {
  local domain="$1" state=""
  if ! state="$(sudo virsh domstate "${domain}" 2>/dev/null)"; then
    return 1
  fi
  state="${state%% *}"
  case "${state}" in
    running|idle|blocked|paused) return 0 ;;
    *) return 1 ;;
  esac
}

create_domain() {
  local domain="$1"
  local -a osinfo_arg=(--osinfo "${PF_OSINFO}")
  if ! virt-install --osinfo list | awk '{print $1}' | grep -qx "${PF_OSINFO}"; then
    warn "OSINFO '${PF_OSINFO}' not available; using detect=on,require=off"
    osinfo_arg=(--osinfo detect=on,require=off)
  fi

  local -a network_args=(
    "--network" "bridge=${PF_WAN_BRIDGE},model=virtio"
    "--network" "bridge=${PF_LAN_BRIDGE},model=virtio"
  )

  info "Creating domain ${domain}"
  sudo virt-install \
    --connect qemu:///system \
    --name "${domain}" \
    --memory 4096 \
    --vcpus 2 \
    --cpu host \
    "${osinfo_arg[@]}" \
    --import \
    --boot hd,menu=on,useserial=on \
    --graphics none \
    --console pty,target_type=serial \
    --disk "path=${PF_INSTALLER_DEST},format=raw,readonly=on,boot.order=1" \
    --disk "path=${PF_QCOW2_PATH},format=qcow2,boot.order=2" \
    "${network_args[@]}"

  ok "Domain ${domain} created"
  warn "Detach installer after installation: sudo virsh detach-disk ${domain} ${PF_INSTALLER_DEST} --config"
}

attach_bridge_interface() {
  local domain="$1" bridge="$2" label="$3"
  local -a args=(
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
  info "Attaching ${label} interface on bridge '${bridge}' to ${domain}"
  "${args[@]}"
  ok "Attached ${label} bridge '${bridge}' to ${domain}"
}

count_bridge_ifaces() {
  local domain="$1" bridge="$2" output
  if ! output="$(sudo virsh domiflist "${domain}" 2>/dev/null)"; then
    echo 0
    return 0
  fi
  awk -v b="${bridge}" 'NR>2 && NF>=3 && $3==b {c++} END {print c+0}' <<<"${output}"
}

ensure_iface_on_bridge() {
  local domain="$1" bridge="$2" label="$3"
  local count
  count="$(count_bridge_ifaces "${domain}" "${bridge}")"
  count="${count:-0}"
  if (( count >= 1 )); then
    ok "${label} bridge '${bridge}' already attached to ${domain}"
    return 0
  fi
  attach_bridge_interface "${domain}" "${bridge}" "${label}"
}

ensure_two_ifaces_same_bridge() {
  local domain="$1" bridge="$2" label="$3"
  local count next
  count="$(count_bridge_ifaces "${domain}" "${bridge}")"
  count="${count:-0}"
  if (( count >= 2 )); then
    ok "${label} bridge '${bridge}' already has ${count} interfaces on ${domain}"
    return 0
  fi
  info "Ensuring ${label} bridge '${bridge}' has two interfaces (currently ${count})"
  while (( count < 2 )); do
    next=$((count + 1))
    attach_bridge_interface "${domain}" "${bridge}" "${label} #${next}"
    count=$((count + 1))
  done
}

if domain_exists "${PF_VM_NAME}"; then
  ok "Domain ${PF_VM_NAME} already exists"
else
  create_domain "${PF_VM_NAME}"
fi

ensure_iface_on_bridge "${PF_VM_NAME}" "${PF_WAN_BRIDGE}" "WAN"
ensure_iface_on_bridge "${PF_VM_NAME}" "${PF_LAN_BRIDGE}" "LAN"

if [[ "${PF_WAN_BRIDGE}" == "${PF_LAN_BRIDGE}" ]]; then
  ensure_two_ifaces_same_bridge "${PF_VM_NAME}" "${PF_WAN_BRIDGE}" "WAN/LAN"
fi

info "Current interfaces for ${PF_VM_NAME}:"
sudo virsh domiflist "${PF_VM_NAME}"

ok "pfSense VM installation helper complete"
