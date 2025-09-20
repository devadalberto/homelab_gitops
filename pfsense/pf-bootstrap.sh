#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${REPO_ROOT}/scripts/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
else
  FALLBACK_LIB="${REPO_ROOT}/scripts/lib/common_fallback.sh"
  if [[ -f "${FALLBACK_LIB}" ]]; then
    # shellcheck source=scripts/lib/common_fallback.sh
    source "${FALLBACK_LIB}"
  else
    echo "Unable to locate scripts/lib/common.sh or fallback helpers" >&2
    exit 70
  fi
fi

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78
readonly EX_NOTREADY=4

ORIGINAL_ARGS=("$@")

DRY_RUN=false
ENV_FILE=""
INSTALL_PATH_OVERRIDE=""
HEADLESS=${PF_HEADLESS:-true}

WORK_ROOT_DEFAULT="/opt/homelab"
IMAGES_DIR_DEFAULT="/var/lib/libvirt/images"
LAN_NET_NAME_DEFAULT="pfsense-lan"
LAN_BRIDGE_DEFAULT="virbr-lan"
ISO_CMD=""

PF_WORK=""
CONFIG_DIR=""
CONFIG_LATEST=""
CONFIG_LEGACY=""
CONFIG_ISO_PATH=""
INSTALL_MEDIA_PATH=""
VM_DISK_PATH=""

usage() {
  cat <<'USAGE'
Usage: pf-bootstrap.sh [OPTIONS]

Prepare the pfSense VM, ensuring the configuration ISO is available and the
installer media is staged for virt-install.

Options:
  --installation-path PATH   Override the pfSense installer archive (.iso[.gz] or .img[.gz]).
  --env-file PATH            Load environment overrides from PATH.
  --headless                 Force serial/headless install (default).
  --no-headless              Enable the legacy VNC console.
  --dry-run                  Log actions without modifying the system.
  -h, --help                 Show this help message.

Exit codes:
  0  Success.
  4  Environment not ready (e.g., VM running when media swap requested).
  64 Usage error (invalid CLI arguments).
  69 Missing required dependencies (install xorriso/genisoimage/mkisofs, gzip, virt-install).
  70 Runtime failure (command execution or libvirt configuration).
  78 Configuration error (missing environment variables or installer media).
USAGE
}

format_command() {
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -z ${formatted} ]]; then
      formatted=$(printf '%q' "$arg")
    else
      formatted+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s' "$formatted"
}

run_cmd() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "$@")"
    return 0
  fi
  log_debug "Executing: $(format_command "$@")"
  "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --installation-path)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--installation-path requires a path argument"
        fi
        INSTALL_PATH_OVERRIDE="$2"
        shift 2
        ;;
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--env-file requires a path argument"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --headless)
        HEADLESS=true
        shift
        ;;
      --no-headless)
        HEADLESS=false
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit ${EX_OK}
        ;;
      --)
        shift
        break
        ;;
      -* )
        usage
        die ${EX_USAGE} "Unknown option: $1"
        ;;
      * )
        usage
        die ${EX_USAGE} "Unexpected positional argument: $1"
        ;;
    esac
  done
}

load_environment() {
  local candidates=()
  if [[ -n ${ENV_FILE} ]]; then
    candidates=("${ENV_FILE}")
  else
    candidates=(
      "${REPO_ROOT}/.env"
      "${REPO_ROOT}/.env.example"
      "/opt/homelab/.env"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load environment from ${candidate}"
      return
    fi
  done

  log_warn "No environment file found; relying on existing shell variables."
}

check_dependencies() {
  local missing=()

  if need xorriso &>/dev/null; then
    ISO_CMD="$(command -v xorriso)"
  elif need genisoimage &>/dev/null; then
    ISO_CMD="$(command -v genisoimage)"
  elif need mkisofs &>/dev/null; then
    ISO_CMD="$(command -v mkisofs)"
  else
    missing+=("xorriso|genisoimage|mkisofs")
  fi

  if ! need gzip &>/dev/null; then
    missing+=(gzip)
  fi

  if ! need virt-install &>/dev/null; then
    missing+=(virt-install)
  fi

  if (( ${#missing[@]} > 0 )); then
    log_error "Missing required dependencies: ${missing[*]}"
    log_info "Install them via: sudo apt-get install xorriso genisoimage mkisofs gzip virt-install"
    die 3
  fi
}

init_defaults() {
  : "${WORK_ROOT:=${WORK_ROOT_DEFAULT}}"
  : "${IMAGES_DIR:=${IMAGES_DIR_DEFAULT}}"
  : "${LAN_NET_NAME:=${LAN_NET_NAME_DEFAULT}}"
  : "${LAN_BRIDGE:=${LAN_BRIDGE_DEFAULT}}"
  : "${VM_NAME:=pfsense-uranus}"
  : "${VCPUS:=2}"
  : "${RAM_MB:=4096}"
  : "${DISK_SIZE_GB:=20}"
  : "${WAN_MODE:=br0}"
  : "${WAN_NIC:=eth0}"

  PF_WORK="${WORK_ROOT}/pfsense"
  CONFIG_DIR="${PF_WORK}/config"
  CONFIG_LATEST="${CONFIG_DIR}/pfSense-config-latest.iso"
  CONFIG_LEGACY="${CONFIG_DIR}/pfSense-config.iso"
  : "${PF_INSTALLER_DIR:=${PF_WORK}/installers}"
}

validate_headless() {
  case "${HEADLESS}" in
    true|false) ;;
    *)
      die ${EX_USAGE} "HEADLESS must be 'true' or 'false' (got '${HEADLESS}')"
      ;;
  esac
}

find_installer_in_dir() {
  local dir=$1
  [[ -d ${dir} ]] || return 1

  local patterns=(
    "*serial*.img.gz"
    "*serial*.iso.gz"
    "*serial*.img"
    "*serial*.iso"
    "*.img.gz"
    "*.iso.gz"
    "*.img"
    "*.iso"
  )

  local pattern
  local best=""
  local file
  shopt -s nullglob
  for pattern in "${patterns[@]}"; do
    for file in "${dir}"/${pattern}; do
      if [[ -z ${best} || ${file} -nt ${best} ]]; then
        best=${file}
      fi
    done
    if [[ -n ${best} ]]; then
      break
    fi
  done
  shopt -u nullglob

  [[ -n ${best} ]] && printf '%s\n' "${best}" && return 0
  return 1
}

is_installer_file() {
  local path=$1
  [[ -f ${path} ]] || return 1
  case "${path}" in
    *.iso|*.iso.gz|*.img|*.img.gz) return 0 ;;
    *) return 1 ;;
  esac
}

discover_installer_path() {
  local candidate
  if [[ -n ${INSTALL_PATH_OVERRIDE} ]]; then
    if is_installer_file "${INSTALL_PATH_OVERRIDE}"; then
      printf '%s\n' "${INSTALL_PATH_OVERRIDE}"
      return 0
    fi
    die ${EX_CONFIG} "Installer not found or invalid: ${INSTALL_PATH_OVERRIDE}"
  fi

  if [[ -n ${PF_SERIAL_INSTALLER_PATH:-} ]]; then
    if is_installer_file "${PF_SERIAL_INSTALLER_PATH}"; then
      printf '%s\n' "${PF_SERIAL_INSTALLER_PATH}"
      return 0
    fi
  fi

  if [[ -n ${PF_ISO_PATH:-} ]]; then
    if is_installer_file "${PF_ISO_PATH}"; then
      printf '%s\n' "${PF_ISO_PATH}"
      return 0
    fi
  fi

  local search_dirs=()
  if [[ -n ${PF_INSTALLER_DIR:-} ]]; then
    search_dirs+=("${PF_INSTALLER_DIR}")
  fi

  local defaults=(
    "${PF_WORK}/installers"
    "${PF_WORK}"
    "${WORK_ROOT}/pfsense"
    "${HOME:-}/Downloads"
  )

  local dir
  for dir in "${defaults[@]}"; do
    local skip=0
    local existing
    for existing in "${search_dirs[@]}"; do
      if [[ ${dir} == "${existing}" ]]; then
        skip=1
        break
      fi
    done
    (( skip == 0 )) && search_dirs+=("${dir}")
  done

  for dir in "${search_dirs[@]}"; do
    candidate=$(find_installer_in_dir "${dir}") || continue
    if [[ -n ${candidate} ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

stage_installer_media() {
  local source=$1
  if [[ -z ${source} || ! -f ${source} ]]; then
    die ${EX_CONFIG} "Installer not found at ${source}"
  fi

  if [[ ${source} == *.gz ]]; then
    local dest_base
    if [[ ${source} == *.img.gz ]]; then
      dest_base="${PF_WORK}/pfsense-installer.img"
    else
      dest_base="${PF_WORK}/pfsense-installer.iso"
    fi
    log_info "Staging pfSense installer from ${source} to ${dest_base}"
    INSTALL_MEDIA_PATH="${dest_base}"
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] gzip -dc '${source}' > '${dest_base}'"
      return
    fi
    run_cmd mkdir -p "${PF_WORK}"
    local tmp_dest
    tmp_dest=$(mktemp -p "${PF_WORK}" "$(basename "${dest_base}").XXXXXX")
    log_debug "Extracting ${source} to ${tmp_dest}"
    if ! gzip -dc "${source}" > "${tmp_dest}"; then
      rm -f "${tmp_dest}"
      die ${EX_SOFTWARE} "Failed to extract installer from ${source}"
    fi
    run_cmd mv "${tmp_dest}" "${dest_base}"
  else
    INSTALL_MEDIA_PATH="${source}"
  fi
}

ensure_config_assets() {
  local generator="${SCRIPT_DIR}/pf-config-gen.sh"

  if [[ -f ${CONFIG_LATEST} ]]; then
    CONFIG_ISO_PATH="${CONFIG_LATEST}"
    log_info "Using pfSense config ISO at ${CONFIG_LATEST}"
    return
  fi

  if [[ -f ${CONFIG_LEGACY} ]]; then
    log_warn "Detected legacy config ISO name (${CONFIG_LEGACY}). It will be used, but run pf-config-gen.sh to refresh."
    CONFIG_ISO_PATH="${CONFIG_LEGACY}"
    return
  fi

  log_info "pfSense config ISO not found; invoking ${generator}"
  local args=()
  if [[ ${DRY_RUN} == true ]]; then
    args+=(--dry-run)
  fi
  run_cmd "${generator}" "${args[@]}"

  if [[ ${DRY_RUN} == true ]]; then
    CONFIG_ISO_PATH="${CONFIG_LATEST}"
    log_info "[DRY-RUN] Would consume the ISO from ${CONFIG_ISO_PATH}"
    return
  fi

  if [[ -f ${CONFIG_LATEST} ]]; then
    CONFIG_ISO_PATH="${CONFIG_LATEST}"
  elif [[ -f ${CONFIG_LEGACY} ]]; then
    log_warn "pfSense config ISO generation completed without creating ${CONFIG_LATEST}; falling back to legacy name."
    CONFIG_ISO_PATH="${CONFIG_LEGACY}"
  else
    die ${EX_SOFTWARE} "pfSense config ISO missing after regeneration"
  fi
}

ensure_directories() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would ensure directories exist: ${PF_WORK} ${CONFIG_DIR} ${IMAGES_DIR} ${PF_INSTALLER_DIR}"
    return
  fi
  run_cmd mkdir -p "${PF_WORK}" "${CONFIG_DIR}" "${IMAGES_DIR}" "${PF_INSTALLER_DIR}"
}

ensure_libvirt_network() {
  if virsh net-info "${LAN_NET_NAME}" &>/dev/null; then
    log_info "Libvirt network '${LAN_NET_NAME}' exists."
    return
  fi

  local net_xml="${PF_WORK}/${LAN_NET_NAME}.xml"
  log_info "Defining libvirt network ${LAN_NET_NAME}"

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would write network definition to ${net_xml}"
    log_info "[DRY-RUN] virsh net-define ${net_xml}"
    log_info "[DRY-RUN] virsh net-autostart ${LAN_NET_NAME}"
    log_info "[DRY-RUN] virsh net-start ${LAN_NET_NAME}"
    return
  fi

  cat >"${net_xml}" <<EOF
<network>
  <name>${LAN_NET_NAME}</name>
  <bridge name='${LAN_BRIDGE}' stp='on' delay='0'/>
  <forward mode='bridge'/>
</network>
EOF
  run_cmd virsh net-define "${net_xml}"
  run_cmd virsh net-autostart "${LAN_NET_NAME}"
  run_cmd virsh net-start "${LAN_NET_NAME}"
}

ensure_vm_disk() {
  VM_DISK_PATH="${IMAGES_DIR}/${VM_NAME}.qcow2"
  if [[ -f ${VM_DISK_PATH} ]]; then
    log_info "VM disk already present at ${VM_DISK_PATH}"
    return
  fi

  log_info "Creating VM disk at ${VM_DISK_PATH} (${DISK_SIZE_GB}G)"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] qemu-img create -f qcow2 ${VM_DISK_PATH} ${DISK_SIZE_GB}G"
    return
  fi

  run_cmd qemu-img create -f qcow2 "${VM_DISK_PATH}" "${DISK_SIZE_GB}G"
}

select_wan_args() {
  local -n ref=$1
  ref=()
  if [[ ${WAN_MODE} == "br0" ]]; then
    ref=(--network "bridge=br0,model=virtio")
  else
    ref=(--network "type=direct,source=${WAN_NIC},source_mode=bridge,model=virtio")
  fi
}

select_install_media_args() {
  local -n ref=$1
  if [[ ${INSTALL_MEDIA_PATH} == *.img ]]; then
    ref=(--disk "path=${INSTALL_MEDIA_PATH},device=disk,bus=usb")
  else
    ref=(--cdrom "${INSTALL_MEDIA_PATH}")
  fi
}

select_console_args() {
  local -n graphics_ref=$1
  local -n console_ref=$2
  if [[ ${HEADLESS} == true ]]; then
    graphics_ref=(--graphics none)
    console_ref=(
      --noautoconsole
      --console pty,target.type=serial
      --serial pty,target.type=serial
      --extra-args "console=ttyS0"
    )
  else
    graphics_ref=(--graphics vnc)
    console_ref=(
      --noautoconsole
      --console pty,target.type=serial
      --serial pty,target.type=serial
    )
  fi
}

select_os_variant() {
  local os_variant=""
  if command -v osinfo-query >/dev/null 2>&1 && osinfo-query os | grep -q 'freebsd13'; then
    os_variant="freebsd13.2"
  fi
  printf '%s' "${os_variant}"
}

define_vm() {
  if virsh dominfo "${VM_NAME}" &>/dev/null; then
    log_info "VM '${VM_NAME}' already defined."
    return
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would define VM ${VM_NAME} with virt-install"
    return
  fi

  local wan_args=()
  select_wan_args wan_args
  local install_args=()
  select_install_media_args install_args
  local graphics_args=()
  local console_args=()
  select_console_args graphics_args console_args
  local os_variant
  os_variant=$(select_os_variant)

  local virt_args=(
    --name "${VM_NAME}"
    --memory "${RAM_MB}"
    --vcpus "${VCPUS}"
    --cpu host
    --hvm
    --virt-type kvm
    "${graphics_args[@]}"
    "${install_args[@]}"
    --disk "path=${VM_DISK_PATH},bus=virtio,format=qcow2"
    "${wan_args[@]}"
    --network "network=${LAN_NET_NAME},model=virtio"
    "${console_args[@]}"
  )

  if [[ -n ${os_variant} ]]; then
    virt_args+=(--os-variant "${os_variant}")
  fi

  run_cmd virt-install "${virt_args[@]}"
}

ensure_cdrom_iso_attachment() {
  local vm_name=$1
  local iso_path=$2
  local label=${3:-ISO}

  if [[ -z ${iso_path} ]]; then
    die ${EX_CONFIG} "Missing path for ${label}."
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would ensure ${label} attached to ${vm_name} via CD-ROM (${iso_path})."
    return
  fi

  if ! virsh dominfo "${vm_name}" &>/dev/null; then
    log_debug "VM ${vm_name} not defined; skipping ${label} attachment"
    return
  fi

  local domblk_output
  domblk_output=$(virsh domblklist "${vm_name}" --details 2>/dev/null || true)

  local iso_target=""
  local -A used_targets=()
  while IFS=$'\t' read -r target source; do
    [[ -z ${target} ]] && continue
    target=${target//$'\r'/}
    source=${source//$'\r'/}
    case "${target}" in
      hd*)
        used_targets["${target}"]=1
        if [[ ${source} == "${iso_path}" ]]; then
          iso_target=${target}
        fi
        ;;
    esac
  done < <(printf '%s\n' "${domblk_output}" | awk 'NR>2 && $2 == "cdrom" {print $3 "\t" $4}')

  if [[ -n ${iso_target} ]]; then
    log_info "${label} already attached to ${vm_name} (${iso_target})."
    return
  fi

  local target=""
  local letter
  for letter in {a..z}; do
    local candidate="hd${letter}"
    if [[ -z ${used_targets[${candidate}]:-} ]]; then
      target=${candidate}
      break
    fi
  done

  if [[ -z ${target} ]]; then
    die ${EX_SOFTWARE} "Unable to locate a free CD-ROM target for ${label} on ${vm_name}."
  fi

  log_info "Attaching ${label} to ${vm_name} at ${target} (${iso_path})."
  local attach_cmd=(virsh attach-disk "${vm_name}" "${iso_path}" "${target}" --type cdrom --mode readonly --config --live)
  log_debug "Executing: $(format_command "${attach_cmd[@]}")"

  if "${attach_cmd[@]}"; then
    return
  fi

  local dom_state
  dom_state=$(virsh domstate "${vm_name}" 2>/dev/null | tr -d '\r' || true)
  if [[ ${dom_state} == "shut off" || ${dom_state} == "pmsuspended" ]]; then
    log_debug "Live attachment unavailable for ${vm_name} (${dom_state}); retrying offline."
    local attach_config_cmd=(virsh attach-disk "${vm_name}" "${iso_path}" "${target}" --type cdrom --mode readonly --config)
    log_debug "Executing: $(format_command "${attach_config_cmd[@]}")"
    if "${attach_config_cmd[@]}"; then
      return
    fi
  fi

  die ${EX_SOFTWARE} "Failed to attach ${label} (${iso_path}) to ${vm_name} at ${target}."
}

ensure_boot_media_attached() {
  ensure_cdrom_iso_attachment "${VM_NAME}" "${INSTALL_MEDIA_PATH}" "pfSense installer media"
  ensure_cdrom_iso_attachment "${VM_NAME}" "${CONFIG_ISO_PATH}" "pfSense config ISO"
}

main() {
  parse_args "$@"
  load_environment
  init_defaults
  validate_headless

  homelab_maybe_reexec_for_privileged_paths PF_BOOTSTRAP_SUDO_GUARD \
    "${WORK_ROOT}" "${PF_WORK}" "${CONFIG_DIR}" "${IMAGES_DIR}" "${PF_INSTALLER_DIR}"

  check_dependencies
  ensure_directories
  ensure_config_assets

  local installer
  if ! installer=$(discover_installer_path); then
    log_warn "No pfSense installer detected. Set PF_SERIAL_INSTALLER_PATH to the downloaded archive or rename it to match the expected netgate-installer-amd64-serial image."
    die ${EX_CONFIG} "Unable to locate pfSense installer. Provide --installation-path or set PF_SERIAL_INSTALLER_PATH/PF_ISO_PATH/PF_INSTALLER_DIR."
  fi
  log_info "Using pfSense installer at ${installer}"
  stage_installer_media "${installer}"

  ensure_libvirt_network
  ensure_vm_disk
  define_vm
  ensure_boot_media_attached

  log_info "pfSense VM ready. Use 'virt-viewer --connect qemu:///system ${VM_NAME}' to install."
}

main "$@"
