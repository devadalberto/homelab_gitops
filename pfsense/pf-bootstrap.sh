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

ORIGINAL_ARGS=("$@")

ENV_FILE=""
ENV_SOURCE_USED=""
INSTALLATION_PATH_OVERRIDE=""
HEADLESS=${PF_HEADLESS:-true}
DRY_RUN=false

WORK_ROOT_DEFAULT="/opt/homelab"
DEFAULT_RAM_MB=4096
DEFAULT_VCPUS=2

PF_WORK=""
CONFIG_DIR=""
CONFIG_ISO_PATH=""
INSTALL_MEDIA_PATH=""

usage() {
  cat <<'USAGE'
Usage: pf-bootstrap.sh [OPTIONS]

Ensure the pfSense libvirt domain exists, refresh the configuration ISO, and
optionally stage installer media.

Options:
  --env-file PATH         Load environment overrides from PATH.
  --installation-path PATH
                          Use PATH as the pfSense installer archive (.img[.gz] or
                          .iso[.gz]).
  --headless              Configure the VM for a serial-only console (default).
  --no-headless           Enable a VNC console alongside the serial port.
  --dry-run               Log planned actions without making changes.
  -h, --help              Show this help message.
USAGE
}

format_command() {
  if [[ $# -eq 0 ]]; then
    printf ''
    return 0
  fi
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
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--env-file requires a path argument"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --installation-path)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--installation-path requires a path argument"
        fi
        INSTALLATION_PATH_OVERRIDE="$2"
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
      -*)
        usage
        die ${EX_USAGE} "Unknown option: $1"
        ;;
      *)
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
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load environment from ${candidate}"
      ENV_SOURCE_USED="${candidate}"
      return
    fi
  done

  log_warn "No environment file found; relying on existing shell variables."
  ENV_SOURCE_USED=""
}

init_defaults() {
  : "${WORK_ROOT:=${WORK_ROOT_DEFAULT}}"
  : "${PF_VM_NAME:=pfsense-uranus}"
  : "${PF_QCOW2_PATH:=/var/lib/libvirt/images/${PF_VM_NAME}.qcow2}"
  : "${PF_QCOW2_SIZE_GB:=20}"
  : "${PF_INSTALLER_DEST:=/var/lib/libvirt/images/netgate-installer-amd64.img}"
  : "${PF_OSINFO:=freebsd14.2}"
  : "${PF_VCPUS:=${DEFAULT_VCPUS}}"
  : "${PF_RAM_MB:=${DEFAULT_RAM_MB}}"
  : "${PF_INSTALLER_DIR:=${WORK_ROOT}/pfsense/installers}"

  PF_WORK="${WORK_ROOT}/pfsense"
  CONFIG_DIR="${PF_WORK}/config"
}

check_dependencies() {
  local required=(virsh virt-install qemu-img gzip install awk grep sed ip)
  if ! need "${required[@]}"; then
    die ${EX_UNAVAILABLE} "Install required commands: ${required[*]}"
  fi
}

enforce_headless_valid() {
  case "${HEADLESS}" in
    true|false) ;;
    *)
      die ${EX_USAGE} "HEADLESS must be 'true' or 'false' (got '${HEADLESS}')"
      ;;
  esac
}

ensure_work_directories() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would ensure directories exist: ${PF_WORK} ${CONFIG_DIR} ${PF_INSTALLER_DIR}"
    return
  fi
  run_cmd mkdir -p "${PF_WORK}" "${CONFIG_DIR}" "${PF_INSTALLER_DIR}"
}

resolve_existing_path() {
  local candidate=$1
  if [[ -z ${candidate} ]]; then
    return 1
  fi
  local paths=("${candidate}")
  if [[ ${candidate} == *.gz ]]; then
    paths+=("${candidate%.gz}")
  else
    paths+=("${candidate}.gz")
  fi
  local path
  for path in "${paths[@]}"; do
    if [[ -n ${path} && -f ${path} ]]; then
      printf '%s\n' "${path}"
      return 0
    fi
  done
  return 1
}

discover_installer_in_dir() {
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
  local file
  local best=""
  shopt -s nullglob
  for pattern in "${patterns[@]}"; do
    for file in "${dir}"/${pattern}; do
      [[ -f ${file} ]] || continue
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

discover_installer_path() {
  local candidate
  if [[ -n ${INSTALLATION_PATH_OVERRIDE} ]]; then
    candidate=$(resolve_existing_path "${INSTALLATION_PATH_OVERRIDE}")
    if [[ -n ${candidate} ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    die ${EX_CONFIG} "Installer not found or invalid: ${INSTALLATION_PATH_OVERRIDE}"
  fi

  local env_var
  for env_var in PF_INSTALLER_SRC PF_SERIAL_INSTALLER_PATH PF_ISO_PATH; do
    if candidate=$(resolve_existing_path "${!env_var:-}"); then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  local search_dirs=()
  if [[ -n ${PF_INSTALLER_DIR:-} ]]; then
    search_dirs+=("${PF_INSTALLER_DIR}")
  fi
  search_dirs+=(
    "${PF_WORK}/installers"
    "${PF_WORK}"
    "${WORK_ROOT}/pfsense"
    "${HOME:-}/Downloads"
    "/var/lib/libvirt/images"
  )

  local dir
  for dir in "${search_dirs[@]}"; do
    candidate=$(discover_installer_in_dir "${dir}") || continue
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
    local dest="${PF_INSTALLER_DEST}"
    if [[ -z ${dest} ]]; then
      dest="${PF_INSTALLER_DIR}/$(basename "${source%.gz}")"
    fi
    log_info "Expanding pfSense installer archive ${source} -> ${dest}"
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] Would extract ${source} to ${dest}"
      INSTALL_MEDIA_PATH="${dest}"
      return
    fi
    run_cmd mkdir -p "$(dirname "${dest}")"
    local tmp_dest
    tmp_dest=$(mktemp -p "$(dirname "${dest}")" "$(basename "${dest}").XXXXXX")
    if ! gzip -dc "${source}" > "${tmp_dest}"; then
      rm -f "${tmp_dest}" || true
      die ${EX_SOFTWARE} "Failed to extract installer from ${source}"
    fi
    run_cmd mv "${tmp_dest}" "${dest}"
    INSTALL_MEDIA_PATH="${dest}"
    return
  fi

  if [[ -n ${PF_INSTALLER_DEST} && ${source} != "${PF_INSTALLER_DEST}" ]]; then
    log_info "Copying installer ${source} -> ${PF_INSTALLER_DEST}"
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] install -D -m 0644 '${source}' '${PF_INSTALLER_DEST}'"
      INSTALL_MEDIA_PATH="${PF_INSTALLER_DEST}"
      return
    fi
    run_cmd install -D -m 0644 "${source}" "${PF_INSTALLER_DEST}"
    INSTALL_MEDIA_PATH="${PF_INSTALLER_DEST}"
  else
    INSTALL_MEDIA_PATH="${source}"
  fi
}

ensure_qcow2_disk() {
  if [[ -f ${PF_QCOW2_PATH} ]]; then
    log_info "Reusing existing disk ${PF_QCOW2_PATH}"
    return
  fi

  log_info "Creating qcow2 disk ${PF_QCOW2_PATH} (${PF_QCOW2_SIZE_GB}G)"
  run_cmd mkdir -p "$(dirname "${PF_QCOW2_PATH}")"
  run_cmd qemu-img create -f qcow2 "${PF_QCOW2_PATH}" "${PF_QCOW2_SIZE_GB}G"
}

detect_bridge() {
  if [[ -n ${PF_LAN_BRIDGE:-} ]]; then
    printf '%s\n' "${PF_LAN_BRIDGE}"
    return 0
  fi

  if ! command -v ip >/dev/null 2>&1; then
    die ${EX_CONFIG} "ip command not available; set PF_LAN_BRIDGE explicitly"
  fi

  local candidate
  candidate=$(ip -br link 2>/dev/null \
    | awk '$2=="UP"{print $1}' \
    | grep -E '^(br|virbr|br0)' \
    | grep -Ev '^br-[0-9a-f]{12}$' \
    | head -n1 || true)

  if [[ -z ${candidate} ]] && ip -br link 2>/dev/null | awk '{print $1}' | grep -qx "br0"; then
    candidate="br0"
  fi

  if [[ -z ${candidate} ]]; then
    die ${EX_CONFIG} "Unable to detect LAN bridge; set PF_LAN_BRIDGE"
  fi

  log_info "Auto-detected LAN bridge ${candidate}"
  printf '%s\n' "${candidate}"
}

select_console_args() {
  local -n graphics_ref=$1
  local -n console_ref=$2
  graphics_ref=()
  console_ref=()
  if [[ ${HEADLESS} == true ]]; then
    graphics_ref=(--graphics none)
  else
    graphics_ref=(--graphics vnc)
  fi
  console_ref=(
    --console pty,target_type=serial
    --serial pty,target_type=serial
  )
}

determine_osinfo_args() {
  OSINFO_ARGS=()
  local desired=${PF_OSINFO:-}
  if [[ -z ${desired} ]]; then
    return
  fi
  if virt-install --osinfo list 2>/dev/null | awk '{print $1}' | grep -qx "${desired}"; then
    OSINFO_ARGS=(--osinfo "${desired}")
  else
    log_warn "Requested OSINFO '${desired}' not present; falling back to detect=on,require=off"
    OSINFO_ARGS=(--osinfo detect=on,require=off)
  fi
}

installer_disk_arg() {
  local path=$1
  if [[ ${path} == *.iso ]]; then
    printf '%s\n' "path=${path},device=cdrom,bus=sata,readonly=on,boot.order=1"
  else
    printf '%s\n' "path=${path},device=disk,bus=usb,format=raw,readonly=on,boot.order=1"
  fi
}

define_vm() {
  local bridge
  bridge=$(detect_bridge)
  local graphics_args=()
  local console_args=()
  select_console_args graphics_args console_args
  determine_osinfo_args

  local install_arg
  install_arg=$(installer_disk_arg "${INSTALL_MEDIA_PATH}")

  local virt_args=(
    --connect qemu:///system
    --name "${PF_VM_NAME}"
    --memory "${PF_RAM_MB}"
    --vcpus "${PF_VCPUS}"
    --cpu host
    --boot hd,menu=on,useserial=on
    --disk "${install_arg}"
    --disk "path=${PF_QCOW2_PATH},format=qcow2,boot.order=2"
    --network "bridge=${bridge},model=virtio"
    --noautoconsole
  )

  virt_args+=("${graphics_args[@]}")
  virt_args+=("${console_args[@]}")
  virt_args+=("${OSINFO_ARGS[@]}")

  log_info "Defining pfSense VM '${PF_VM_NAME}'"
  run_cmd virt-install "${virt_args[@]}"
}

find_config_iso() {
  local candidates=()
  if [[ -n ${PF_CONFIG_ISO_PATH:-} ]]; then
    candidates+=("${PF_CONFIG_ISO_PATH}")
  fi
  candidates+=(
    "${CONFIG_DIR}/pfSense-config-latest.iso"
    "${CONFIG_DIR}/pfSense-config.iso"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -n ${candidate} && -f ${candidate} ]]; then
      CONFIG_ISO_PATH="${candidate}"
      log_info "Using pfSense config ISO at ${candidate}"
      return 0
    fi
  done

  return 1
}

ensure_config_iso() {
  if find_config_iso; then
    return
  fi

  if [[ ${DRY_RUN} == true ]]; then
    CONFIG_ISO_PATH="${CONFIG_DIR}/pfSense-config-latest.iso"
    log_info "[DRY-RUN] Would ensure pfSense config ISO at ${CONFIG_ISO_PATH}"
    return
  fi

  local generator="${SCRIPT_DIR}/pf-config-gen.sh"
  if [[ -x ${generator} ]]; then
    log_info "pfSense config ISO not found; invoking ${generator}"
    local args=()
    if [[ -n ${ENV_SOURCE_USED} ]]; then
      args+=(--env-file "${ENV_SOURCE_USED}")
    fi
    run_cmd "${generator}" "${args[@]}"
  else
    log_warn "pfSense config generator not executable at ${generator}"
  fi

  if find_config_iso; then
    return
  fi

  die ${EX_CONFIG} "pfSense config ISO missing. Run pf-config-gen.sh before bootstrapping."
}

domain_exists() {
  virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1
}

domain_is_running() {
  local state
  state=$(virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)
  case ${state} in
    running|paused) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_config_iso_attachment() {
  local vm_name=$1
  local iso_path=$2
  local label=${3:-pfSense config ISO}

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would ensure ${label} attached to ${vm_name} (${iso_path})"
    return
  fi

  if ! virsh dominfo "${vm_name}" >/dev/null 2>&1; then
    log_debug "VM ${vm_name} not defined; skipping ${label} attachment"
    return
  fi

  if [[ ! -f ${iso_path} ]]; then
    die ${EX_CONFIG} "${label} not found at ${iso_path}"
  fi

  local domblk_output
  domblk_output=$(virsh domblklist "${vm_name}" --details 2>/dev/null || true)

  local iso_target=""
  local first_cdrom=""
  local -A used_targets=()
  local line
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    if [[ ${line} =~ ^file[[:space:]]+cdrom[[:space:]]+([^[:space:]]+)[[:space:]]+(.+) ]]; then
      local target=${BASH_REMATCH[1]}
      local source=${BASH_REMATCH[2]}
      used_targets["${target}"]=1
      if [[ -z ${first_cdrom} ]]; then
        first_cdrom=${target}
      fi
      if [[ ${source} == "${iso_path}" ]]; then
        iso_target=${target}
        break
      fi
    elif [[ ${line} =~ ^file[[:space:]]+disk[[:space:]]+([^[:space:]]+) ]]; then
      local target=${BASH_REMATCH[1]}
      used_targets["${target}"]=1
    fi
  done < <(printf '%s\n' "${domblk_output}" | tail -n +3)

  if [[ -n ${iso_target} ]]; then
    log_info "${label} already attached to ${vm_name} (${iso_target})."
    return
  fi

  local live_args=()
  if domain_is_running "${vm_name}"; then
    live_args+=(--live)
  fi

  if [[ -n ${first_cdrom} ]]; then
    log_info "Updating ${label} on ${vm_name} target ${first_cdrom}"
    run_cmd virsh change-media "${vm_name}" "${first_cdrom}" "${iso_path}" --insert --force --config "${live_args[@]}"
    return
  fi

  local candidate_targets=(sdb sdc sdd hdb hdc)
  local attach_target=""
  local candidate
  for candidate in "${candidate_targets[@]}"; do
    if [[ -z ${used_targets[${candidate}]:-} ]]; then
      attach_target=${candidate}
      break
    fi
  done
  [[ -n ${attach_target} ]] || attach_target="sdb"

  log_info "Attaching ${label} to ${vm_name} at ${attach_target}"
  run_cmd virsh attach-disk "${vm_name}" "${iso_path}" "${attach_target}" --type cdrom --mode readonly --config "${live_args[@]}"
}

main() {
  parse_args "$@"
  load_environment
  init_defaults
  enforce_headless_valid
  check_dependencies
  ensure_work_directories
  ensure_config_iso

  if domain_exists; then
    log_info "Libvirt domain '${PF_VM_NAME}' already exists; ensuring configuration media is current."
    ensure_config_iso_attachment "${PF_VM_NAME}" "${CONFIG_ISO_PATH}" "pfSense config ISO"
    log_info "pfSense VM '${PF_VM_NAME}' already defined. Nothing else to do."
    return
  fi

  local installer
  if ! installer=$(discover_installer_path); then
    log_warn "No pfSense installer detected. Provide --installation-path or set PF_INSTALLER_SRC (PF_SERIAL_INSTALLER_PATH/PF_ISO_PATH remain supported)."
    die ${EX_CONFIG} "Unable to locate pfSense installer."
  fi
  log_info "Using pfSense installer at ${installer}"
  stage_installer_media "${installer}"

  ensure_qcow2_disk
  define_vm
  ensure_config_iso_attachment "${PF_VM_NAME}" "${CONFIG_ISO_PATH}" "pfSense config ISO"

  log_info "pfSense VM '${PF_VM_NAME}' ready. Start it with 'virsh start ${PF_VM_NAME}' when you're ready to install."
}

main "$@"
