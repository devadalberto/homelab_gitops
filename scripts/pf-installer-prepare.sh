#!/usr/bin/env bash
set -euo pipefail

log() { printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "[ERROR] $*"; exit 1; }
info() { log "[INFO] $*"; }
warn() { log "[WARN] $*"; }

usage() {
  cat <<'USAGE' >&2
Usage: pf-installer-prepare.sh [OPTIONS]

Stage the pfSense serial installer for virt-install/libvirt consumption.

Options:
  --env-file PATH  Source PATH for environment variables before processing.
  --source PATH    Override the installer source (defaults to PF_INSTALLER_SRC
                   or legacy PF_SERIAL_INSTALLER_PATH/PF_ISO_PATH).
  --dest PATH      Override the expanded image destination (defaults to
                   PF_INSTALLER_DEST or /var/lib/libvirt/images/... when
                   decompressing archives).
  -h, --help       Show this help text.
USAGE
}

ENV_FILE=""
OVERRIDE_SOURCE=""
OVERRIDE_DEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="${2:-}"
      shift 2 || die "--env-file requires a path"
      ;;
    --source)
      OVERRIDE_SOURCE="${2:-}"
      shift 2 || die "--source requires a path"
      ;;
    --dest)
      OVERRIDE_DEST="${2:-}"
      shift 2 || die "--dest requires a path"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -n ${ENV_FILE} ]]; then
  if [[ ! -f ${ENV_FILE} ]]; then
    die "Environment file ${ENV_FILE} not found"
  fi
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

abspath() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

INSTALLER_SRC="${OVERRIDE_SOURCE:-${PF_INSTALLER_SRC:-}}"
if [[ -z ${INSTALLER_SRC} && -n ${PF_SERIAL_INSTALLER_PATH:-} ]]; then
  INSTALLER_SRC="${PF_SERIAL_INSTALLER_PATH}"
fi
if [[ -z ${INSTALLER_SRC} && -n ${PF_ISO_PATH:-} ]]; then
  INSTALLER_SRC="${PF_ISO_PATH}"
fi

if [[ -z ${INSTALLER_SRC} ]]; then
  die "PF_INSTALLER_SRC (or PF_SERIAL_INSTALLER_PATH/PF_ISO_PATH) must be set"
fi

if [[ ! -f ${INSTALLER_SRC} ]]; then
  die "Installer source ${INSTALLER_SRC} does not exist"
fi

INSTALLER_SRC_ABS="$(abspath "${INSTALLER_SRC}")"

DEST_HINT="${OVERRIDE_DEST:-${PF_INSTALLER_DEST:-}}"
DEFAULT_DEST="/var/lib/libvirt/images/netgate-installer-amd64.img"

final_path=""

copy_if_needed() {
  local src="$1" dest="$2"
  local label="$3"
  local dest_dir
  dest_dir="$(dirname "${dest}")"
  install -d "${dest_dir}"
  if [[ -f ${dest} ]] && cmp -s "${src}" "${dest}"; then
    info "${label} already staged at ${dest}"
    return 0
  fi
  info "Staging ${label} to ${dest}"
  install -m 0644 "${src}" "${dest}"
}

prepare_gzip() {
  local src="$1"
  local dest="$2"
  if [[ -z ${dest} ]]; then
    dest="${src%.gz}"
  fi
  dest="$(abspath "${dest}")"
  gzip -t "${src}" || die "Installer archive ${src} failed gzip -t"
  local dest_dir="$(dirname "${dest}")"
  install -d "${dest_dir}"
  if [[ -f ${dest} && "${dest}" -nt "${src}" && -s ${dest} ]]; then
    info "Installer archive already expanded at ${dest}"
    final_path="${dest}"
    return 0
  fi
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  trap 'rm -f "${tmp}"' RETURN
  info "Expanding ${src} to ${dest}"
  gunzip -c "${src}" >"${tmp}"
  install -m 0644 "${tmp}" "${dest}"
  rm -f "${tmp}"
  trap - RETURN
  final_path="${dest}"
}

prepare_plain() {
  local src="$1"
  local dest="$2"
  if [[ -z ${dest} ]]; then
    dest="${src}"
  fi
  dest="$(abspath "${dest}")"
  if [[ "${dest}" == "${src}" ]]; then
    final_path="${dest}"
    return 0
  fi
  copy_if_needed "${src}" "${dest}" "installer"
  final_path="${dest}"
}

case "${INSTALLER_SRC_ABS}" in
  *.img.gz)
    prepare_gzip "${INSTALLER_SRC_ABS}" "${DEST_HINT:-${DEFAULT_DEST}}"
    ;;
  *.img)
    prepare_plain "${INSTALLER_SRC_ABS}" "${DEST_HINT}" ;;
  *.iso.gz)
    prepare_gzip "${INSTALLER_SRC_ABS}" "${DEST_HINT:-${DEFAULT_DEST%.img}.iso}"
    ;;
  *.iso)
    prepare_plain "${INSTALLER_SRC_ABS}" "${DEST_HINT}" ;;
  *)
    die "Unsupported installer type for ${INSTALLER_SRC_ABS} (expect .img/.img.gz or .iso/.iso.gz)"
    ;;
esac

if [[ -z ${final_path} ]]; then
  die "Failed to prepare installer media"
fi

if [[ ! -f ${final_path} ]]; then
  die "Prepared installer ${final_path} does not exist"
fi

if [[ ! -s ${final_path} ]]; then
  die "Prepared installer ${final_path} is empty"
fi

if command -v qemu-img >/dev/null 2>&1; then
  if ! qemu-img info "${final_path}" >/dev/null 2>&1; then
    warn "qemu-img could not inspect ${final_path}; verify the installer manually"
  fi
fi

printf '%s\n' "${final_path}"
