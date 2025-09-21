#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

TMP_FILES=()
cleanup_tmp_files() {
  local path
  for path in "${TMP_FILES[@]:-}"; do
    [[ -n ${path} && -f ${path} ]] || continue
    rm -f -- "${path}" 2>/dev/null || true
  done
}
trap cleanup_tmp_files EXIT

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [--env-file PATH]

Bootstrap a pfSense VM installer environment and launch virt-install.

Options:
  --env-file PATH  Source environment overrides from PATH.
  -h, --help       Show this help message.
USAGE
}

parse_args() {
  ENV_FILE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          log_error "--env-file requires a path argument"
          usage
          exit 64
        fi
        ENV_FILE="$2"
        shift 2
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
        log_error "Unknown argument: $1"
        usage
        exit 64
        ;;
    esac
  done

}

source_env_file() {
  if [[ -z ${ENV_FILE:-} ]]; then
    return
  fi
  if [[ ! -f ${ENV_FILE} ]]; then
    log_error "Environment file '${ENV_FILE}' not found."
    exit 1
  fi
  log_info "Loading environment from ${ENV_FILE}"
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
}

require_env() {
  local var_name=$1
  local value="${!var_name:-}"
  if [[ -z ${value} ]]; then
    log_error "Required environment variable '${var_name}' is not set."
    exit 1
  fi
}

require_positive_integer() {
  local var_name=$1
  local value="${!var_name:-}"
  if [[ ! ${value} =~ ^[0-9]+$ ]] || (( value <= 0 )); then
    log_error "Environment variable '${var_name}' must be a positive integer."
    exit 1
  fi
}

check_dependencies() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

ensure_bridge_exists() {
  local bridge=$1
  if ip link show "${bridge}" >/dev/null 2>&1; then
    return
  fi
  log_error "Bridge '${bridge}' not found."
  exit 1
}

detect_lan_bridge() {
  if [[ -n ${PF_LAN_BRIDGE:-} ]]; then
    log_info "Using LAN bridge from PF_LAN_BRIDGE: ${PF_LAN_BRIDGE}"
    echo "${PF_LAN_BRIDGE}"
    return
  fi

  local line name
  while IFS= read -r line; do
    [[ ${line} == *"state UP"* ]] || continue
    name=$(awk -F': ' '{print $2}' <<< "${line}")
    name=${name%%:*}
    name=${name// /}
    if [[ ${name} == docker* ]]; then
      continue
    fi
    if [[ ${name} == br-* && ${name} != br0 ]]; then
      continue
    fi
    log_info "Detected active bridge '${name}' for LAN attachment."
    echo "${name}"
    return
  done < <(ip -o link show type bridge 2>/dev/null || true)

  log_warn "Falling back to default bridge 'br0'."
  echo "br0"
}

stage_installer() {
  local src=$1
  local dest=$2
  local dest_dir
  dest_dir=$(dirname "${dest}")
  sudo install -d -m 0755 "${dest_dir}"

  if [[ ${src} == *.gz ]]; then
    local tmp_file
    tmp_file=$(mktemp)
    TMP_FILES+=("${tmp_file}")
    log_info "Decompressing installer from ${src} to ${dest}"
    gzip -cd "${src}" > "${tmp_file}"
    sudo install -m 0644 "${tmp_file}" "${dest}"
  else
    log_info "Copying installer from ${src} to ${dest}"
    sudo install -m 0644 "${src}" "${dest}"
  fi
}

ensure_qcow2_disk() {
  local qcow_path=$1
  local qcow_size_gb=$2
  local qcow_dir
  qcow_dir=$(dirname "${qcow_path}")
  sudo install -d -m 0755 "${qcow_dir}"
  if [[ -f ${qcow_path} ]]; then
    log_info "Using existing qcow2 disk at ${qcow_path}"
    return
  fi
  log_info "Creating qcow2 disk at ${qcow_path} (${qcow_size_gb}G)"
  sudo qemu-img create -f qcow2 "${qcow_path}" "${qcow_size_gb}G"
}

launch_virt_install() {
  local installer_path=$1
  local qcow_path=$2
  local lan_bridge=$3
  local wan_bridge=$4

  local virt_args=(
    --name "${PF_VM_NAME}"
    --memory "${PF_VM_MEMORY_MB}"
    --vcpus "${PF_VM_VCPUS}"
    --cpu host
    --import
    --graphics none
    --noautoconsole
    --console pty,target.type=serial
    --serial pty,target.type=serial
    --disk "path=${installer_path},device=disk,bus=usb,readonly=on,boot.order=1"
    --disk "path=${qcow_path},format=qcow2,bus=virtio,boot.order=2"
    --network "bridge=${wan_bridge},model=virtio"
    --network "bridge=${lan_bridge},model=virtio"
  )

  if [[ -n ${PF_OS_VARIANT:-} ]]; then
    virt_args+=(--os-variant "${PF_OS_VARIANT}")
  else
    virt_args+=(--osinfo detect=on,require=off)
  fi

  if [[ -n ${PF_EXTRA_VIRT_INSTALL_ARGS:-} ]]; then
    # shellcheck disable=SC2206
    virt_args+=(${PF_EXTRA_VIRT_INSTALL_ARGS})
  fi

  log_info "Launching virt-install for ${PF_VM_NAME}"
  sudo virt-install "${virt_args[@]}"

  printf '\nDetach the installer disk after installation completes:\n'
  printf '  sudo virsh detach-disk "%s" "%s" --config --persistent\n' "${PF_VM_NAME}" "${installer_path}"
}

main() {
  parse_args "$@"
  source_env_file

  check_dependencies sudo virsh virt-install qemu-img gzip install ip

  PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
  if [[ -z ${PF_INSTALLER_SRC} ]]; then
    if [[ -n ${PF_SERIAL_INSTALLER_PATH:-} ]]; then
      PF_INSTALLER_SRC="${PF_SERIAL_INSTALLER_PATH}"
    elif [[ -n ${PF_ISO_PATH:-} ]]; then
      PF_INSTALLER_SRC="${PF_ISO_PATH}"
    fi
  fi
  require_env PF_INSTALLER_SRC
  if [[ ! -f ${PF_INSTALLER_SRC} ]]; then
    log_error "Installer source '${PF_INSTALLER_SRC}' not found."
    exit 1
  fi

  PF_VM_NAME="${PF_VM_NAME:-${VM_NAME:-pfsense-uranus}}"
  require_env PF_VM_NAME

  PF_VM_MEMORY_MB="${PF_VM_MEMORY_MB:-${RAM_MB:-4096}}"
  require_positive_integer PF_VM_MEMORY_MB

  PF_VM_VCPUS="${PF_VM_VCPUS:-${VCPUS:-2}}"
  require_positive_integer PF_VM_VCPUS

  PF_QCOW2_SIZE_GB="${PF_QCOW2_SIZE_GB:-${DISK_SIZE_GB:-20}}"
  require_positive_integer PF_QCOW2_SIZE_GB

  if [[ -z ${PF_INSTALLER_DEST:-} ]]; then
    PF_INSTALLER_DEST="$(basename "${PF_INSTALLER_SRC%.gz}")"
  fi

  PF_QCOW2_PATH="${PF_QCOW2_PATH:-/var/lib/libvirt/images/${PF_VM_NAME}.qcow2}"

  local images_root="/var/lib/libvirt/images"
  local installer_path
  if [[ ${PF_INSTALLER_DEST} == /* ]]; then
    installer_path="${PF_INSTALLER_DEST}"
  else
    installer_path="${images_root}/${PF_INSTALLER_DEST}"
  fi

  stage_installer "${PF_INSTALLER_SRC}" "${installer_path}"
  ensure_qcow2_disk "${PF_QCOW2_PATH}" "${PF_QCOW2_SIZE_GB}"

  local lan_bridge
  lan_bridge=$(detect_lan_bridge)
  ensure_bridge_exists "${lan_bridge}"

  local wan_bridge="${PF_WAN_BRIDGE:-br0}"
  ensure_bridge_exists "${wan_bridge}"

  if sudo virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; then
    log_info "VM '${PF_VM_NAME}' already exists; skipping virt-install invocation."
    return
  fi

  launch_virt_install "${installer_path}" "${PF_QCOW2_PATH}" "${lan_bridge}" "${wan_bridge}"
}

main "$@"
