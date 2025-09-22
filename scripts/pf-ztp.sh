#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

usage() {
  cat <<'USAGE'
Usage: pf-ztp.sh [OPTIONS]

Create or refresh the pfSense libvirt domain and bootstrap media.

Options:
  --env-file PATH  Load environment variables from PATH.
  --vm-name NAME   Operate on libvirt domain NAME.
  --verbose        Enable verbose logging.
  -h, --help       Display this help message.
USAGE
}

abspath() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

ENV_FILE_OVERRIDE=""
VM_NAME_OVERRIDE=""
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        die "Missing value for --env-file"
      fi
      ENV_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --vm-name)
      if [[ $# -lt 2 ]]; then
        die "Missing value for --vm-name"
      fi
      VM_NAME_OVERRIDE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ ${VERBOSE} == true ]]; then
  log_set_level debug
fi

if ! load_env "${ENV_FILE_OVERRIDE}"; then
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    fatal ${EX_CONFIG} "Environment file '${ENV_FILE_OVERRIDE}' not found"
  fi
  info "Using existing shell environment"
fi

LIBVIRT_VM_NAME="${VM_NAME_OVERRIDE:-${PF_VM_NAME:-${VM_NAME:-pfsense-uranus}}}"
[[ -n ${LIBVIRT_VM_NAME} ]] || fatal ${EX_CONFIG} "VM name is empty"

PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-br0}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-${PF_WAN_BRIDGE}}"
[[ -n ${PF_WAN_BRIDGE} ]] || fatal ${EX_CONFIG} "PF_WAN_BRIDGE is required"
[[ -n ${PF_LAN_BRIDGE} ]] || fatal ${EX_CONFIG} "PF_LAN_BRIDGE is required"

PF_VCPUS="${PF_VCPUS:-${VCPUS:-2}}"
PF_RAM_MB="${PF_RAM_MB:-${RAM_MB:-4096}}"
PF_QCOW2_PATH="${PF_QCOW2_PATH:-/var/lib/libvirt/images/${LIBVIRT_VM_NAME}.qcow2}"
PF_QCOW2_SIZE_GB="${PF_QCOW2_SIZE_GB:-${DISK_SIZE_GB:-20}}"
PF_INSTALLER_DEST="${PF_INSTALLER_DEST:-/var/lib/libvirt/images/${LIBVIRT_VM_NAME}-installer.img}"
PF_CONFIG_ISO_PATH="${PF_CONFIG_ISO_PATH:-${HOMELAB_PFSENSE_CONFIG_DIR}/pfSense-config.iso}"
PF_OSINFO="${PF_OSINFO:-freebsd14.2}"

INSTALLER_SRC="${PF_SERIAL_INSTALLER_PATH:-${PF_INSTALLER_SRC:-}}"
if [[ -z ${INSTALLER_SRC} ]]; then
  fatal ${EX_CONFIG} "PF_SERIAL_INSTALLER_PATH or PF_INSTALLER_SRC must be defined"
fi

if [[ ! -f ${INSTALLER_SRC} ]]; then
  fatal ${EX_CONFIG} "Installer source ${INSTALLER_SRC} not found"
fi

require_cmd install virsh virt-install qemu-img gzip awk mktemp grep

if [[ ! -f ${PF_CONFIG_ISO_PATH} ]]; then
  warn "Config ISO ${PF_CONFIG_ISO_PATH} not found; pfSense will boot without overrides"
fi

ensure_qcow2() {
  local path="$1" size_gb="$2"
  if [[ -f ${path} ]]; then
    log_debug "QCOW2 disk ${path} already present"
    return
  fi
  info "Creating qcow2 disk ${path} (${size_gb}G)"
  install -d "$(dirname "${path}")"
  qemu-img create -f qcow2 "${path}" "${size_gb}G" >/dev/null
}

prepare_installer_media() {
  local src="$1" dest="$2"
  local final=""
  case "${src}" in
    *.gz)
      info "Validating installer archive ${src}"
      gzip -t "${src}"
      final="${dest}"
      if [[ -z ${final} ]]; then
        final="${src%.gz}"
      fi
      final="$(abspath "${final}")"
      install -d "$(dirname "${final}")"
      if [[ -f ${final} && ${final} -nt ${src} && -s ${final} ]]; then
        info "Installer archive already expanded at ${final}"
        printf '%s' "${final}"
        return
      fi
      local tmp
      tmp="$(mktemp "${final}.XXXXXX")"
      trap 'rm -f "${tmp}"' RETURN
      info "Expanding ${src} to ${final}"
      gzip -dc "${src}" >"${tmp}"
      install -m 0644 "${tmp}" "${final}"
      rm -f "${tmp}"
      trap - RETURN
      printf '%s' "${final}"
      ;;
    *)
      final="${dest:-${src}}"
      final="$(abspath "${final}")"
      install -d "$(dirname "${final}")"
      if [[ "${final}" != "${src}" ]]; then
        info "Staging installer image to ${final}"
        install -m 0644 "${src}" "${final}"
      fi
      printf '%s' "${final}"
      ;;
  esac
}

select_osinfo() {
  local desired="$1"
  local fallback="freebsd14.0"
  local selected="${desired}"
  if command -v osinfo-query >/dev/null 2>&1; then
    local available
    available="$(osinfo-query os --fields=id 2>/dev/null | awk 'NR>2 {print $1}')"
    if [[ -n ${available} && ${selected} != "" ]]; then
      if ! grep -Fqx "${selected}" <<<"${available}"; then
        if grep -Fqx "${fallback}" <<<"${available}"; then
          warn "osinfo '${selected}' not available; using fallback '${fallback}'"
          selected="${fallback}"
        else
          warn "osinfo '${selected}' not found and fallback '${fallback}' unavailable"
        fi
      fi
    fi
  else
    warn "osinfo-query not found; using requested osinfo '${selected}'"
  fi
  printf '%s' "${selected}"
}

virsh_state() {
  local state
  state="$(virsh domstate "${LIBVIRT_VM_NAME}" 2>/dev/null || true)"
  state="${state//$'\r'/}"
  state="${state// /}"
  printf '%s' "${state,,}"
}

refresh_disk_attachment() {
  local source="$1" target="$2" type="$3" mode="$4" bus="$5"
  [[ -n ${source} ]] || return
  if [[ ! -f ${source} ]]; then
    warn "Attachment source ${source} missing; skipping ${target}"
    return
  fi
  local device="${type}"
  local existing
  existing="$(virsh domblklist "${LIBVIRT_VM_NAME}" --details 2>/dev/null | awk -v dev="${device}" -v tgt="${target}" 'NR>2 && $2==dev && $3==tgt {print $4; exit}')"
  if [[ ${existing} == "${source}" ]]; then
    log_debug "${source} already attached as ${target}"
    return
  fi
  local state
  state="$(virsh_state)"
  if [[ -n ${existing} ]]; then
    local -a detach_cmd=(virsh detach-disk "${LIBVIRT_VM_NAME}" "${existing}" --config)
    if [[ ${state} != shutoff && ${state} != pmsuspended ]]; then
      detach_cmd+=(--live)
    fi
    if "${detach_cmd[@]}" >/dev/null 2>&1; then
      info "Detached ${existing} from ${LIBVIRT_VM_NAME}"
    else
      warn "Failed to detach ${existing} from ${LIBVIRT_VM_NAME}"
    fi
  fi
  local -a attach_cmd=(virsh attach-disk "${LIBVIRT_VM_NAME}" "${source}" "${target}" --config)
  if [[ ${type} == cdrom ]]; then
    attach_cmd+=(--type cdrom)
    if [[ -n ${mode} ]]; then
      attach_cmd+=(--mode "${mode}")
    else
      attach_cmd+=(--mode readonly)
    fi
  else
    if [[ -n ${mode} ]]; then
      attach_cmd+=(--mode "${mode}")
    fi
    attach_cmd+=(--targetbus "${bus:-virtio}")
  fi
  if [[ ${state} != shutoff && ${state} != pmsuspended ]]; then
    attach_cmd+=(--live)
  fi
  if "${attach_cmd[@]}" >/dev/null 2>&1; then
    info "Attached ${source} to ${LIBVIRT_VM_NAME} as ${target}"
  else
    warn "Failed to attach ${source} to ${LIBVIRT_VM_NAME} (${target})"
  fi
}

ensure_qcow2 "${PF_QCOW2_PATH}" "${PF_QCOW2_SIZE_GB}"
INSTALLER_IMAGE_PATH="$(prepare_installer_media "${INSTALLER_SRC}" "${PF_INSTALLER_DEST}")"

DOMAIN_EXISTS=false
if virsh dominfo "${LIBVIRT_VM_NAME}" >/dev/null 2>&1; then
  DOMAIN_EXISTS=true
  info "pfSense domain ${LIBVIRT_VM_NAME} already defined"
fi

selected_osinfo="$(select_osinfo "${PF_OSINFO}")"

if [[ ${DOMAIN_EXISTS} == false ]]; then
  network_args=(
    --network "bridge=${PF_WAN_BRIDGE},model=virtio"
    --network "bridge=${PF_LAN_BRIDGE},model=virtio"
  )
  virt_args=(
    virt-install
    --connect qemu:///system
    --name "${LIBVIRT_VM_NAME}"
    --memory "${PF_RAM_MB}"
    --vcpus "${PF_VCPUS}"
    --cpu host
    --import
    --boot hd,menu=on,useserial=on
    --graphics none
    --serial pty
    --console pty,target_type=serial
    --disk "path=${INSTALLER_IMAGE_PATH},device=disk,format=raw,bus=virtio,boot.order=1,readonly=on"
    --disk "path=${PF_QCOW2_PATH},format=qcow2,device=disk,bus=virtio,boot.order=2"
    --osinfo "${selected_osinfo}"
    --noautoconsole
  )
  if [[ -f ${PF_CONFIG_ISO_PATH} ]]; then
    virt_args+=(--disk "path=${PF_CONFIG_ISO_PATH},device=cdrom,perms=ro")
  fi
  virt_args+=("${network_args[@]}")
  info "Creating pfSense VM ${LIBVIRT_VM_NAME}"
  "${virt_args[@]}"
else
  info "Refreshing media attachments for ${LIBVIRT_VM_NAME}"
fi

refresh_disk_attachment "${INSTALLER_IMAGE_PATH}" vda disk readonly virtio
refresh_disk_attachment "${PF_QCOW2_PATH}" vdb disk rw virtio
if [[ -f ${PF_CONFIG_ISO_PATH} ]]; then
  refresh_disk_attachment "${PF_CONFIG_ISO_PATH}" sdy cdrom readonly
fi

state="$(virsh_state)"
if [[ ${state} != running ]]; then
  info "Starting ${LIBVIRT_VM_NAME}"
  virsh start "${LIBVIRT_VM_NAME}" >/dev/null
else
  info "${LIBVIRT_VM_NAME} is already running"
fi

info "pfSense VM ${LIBVIRT_VM_NAME} is ready"
info "Next steps:"
info "  virsh console ${LIBVIRT_VM_NAME}"
info "  virsh detach-disk ${LIBVIRT_VM_NAME} ${INSTALLER_IMAGE_PATH} --config [--live] after install"
if [[ -f ${PF_CONFIG_ISO_PATH} ]]; then
  info "  virsh detach-disk ${LIBVIRT_VM_NAME} ${PF_CONFIG_ISO_PATH} --config [--live] after bootstrap"
fi
