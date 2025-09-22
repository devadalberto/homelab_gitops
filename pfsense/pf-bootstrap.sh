#!/usr/bin/env bash
set -euo pipefail

log()  { printf "%s %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { log "[FATAL] $*"; exit 78; }
info() { log "[INFO] $*"; }
warn() { log "[WARN] $*"; }
ok()   { log "[OK] $*"; }

ENV_FILE=""
INSTALLATION_PATH=""
HEADLESS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file|-e) ENV_FILE="${2:-}"; shift 2;;
    --installation-path) INSTALLATION_PATH="${2:-}"; shift 2;;
    --headless) HEADLESS=1; shift;;
    *) shift;;
  esac
done

if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  info "Loading environment from ${ENV_FILE}"
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"

CFG_DIR="/opt/homelab/pfsense/config"
CFG_ISO="${CFG_DIR}/pfSense-config-latest.iso"
if [[ ! -f "${CFG_ISO}" ]]; then
  newest="$(ls -1t "${CFG_DIR}"/pfSense-config-*.iso 2>/dev/null | head -n1 || true)"
  [[ -n "${newest}" ]] || die "Config ISO not found under ${CFG_DIR}. Run pf-config-gen.sh first."
  CFG_ISO="${newest}"
  info "Using newest config ISO: ${CFG_ISO}"
else
  info "Using pfSense config ISO at ${CFG_ISO}"
fi

domain_exists() { sudo virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; }

PF_INSTALLER_DIRS=("$HOME/downloads" "/opt/homelab/pfsense" "/var/lib/libvirt/images")
PF_INSTALLER_NAMES=("netgate-installer-amd64-serial.img.gz" "netgate-installer-amd64.img.gz" "netgate-installer-amd64-serial.img" "netgate-installer-amd64.img")

locate_installer() {
  local explicit="${INSTALLATION_PATH:-${PF_SERIAL_INSTALLER_PATH:-}}"
  if [[ -n "${explicit}" ]]; then
    [[ -f "${explicit}" ]] && { echo "${explicit}"; return 0; }
    [[ "${explicit}" == *.gz && -f "${explicit%.gz}" ]] && { echo "${explicit%.gz}"; return 0; }
    [[ "${explicit}" != *.gz && -f "${explicit}.gz" ]] && { echo "${explicit}.gz"; return 0; }
    warn "Explicit installer '${explicit}' not found; falling back to autodiscovery."
  fi
  local d n
  for d in "${PF_INSTALLER_DIRS[@]}"; do
    for n in "${PF_INSTALLER_NAMES[@]}"; do
      [[ -f "${d}/${n}" ]] && { echo "${d}/${n}"; return 0; }
    done
  done
  local any=""
  any="$(ls -1t "${PF_INSTALLER_DIRS[@]/%//netgate*amd64*.img*}" 2>/dev/null | head -n1 || true)"
  [[ -n "${any}" ]] || return 1
  echo "${any}"
}

REQUIRE_INSTALLER=0
if ! domain_exists; then
  REQUIRE_INSTALLER=1
fi

if [[ "${REQUIRE_INSTALLER}" -eq 1 ]]; then
  if INSTALLER_FOUND="$(locate_installer)"; then
    ok "Installer located: ${INSTALLER_FOUND}"
  else
    die "Installer required to bootstrap a new domain, but none found. Set PF_SERIAL_INSTALLER_PATH or provide --installation-path."
  fi
else
  if INSTALLER_FOUND="$(locate_installer)"; then
    ok "Optional installer available: ${INSTALLER_FOUND}"
  else
    warn "No installer found. Proceeding without it because domain exists."
  fi
fi

if domain_exists; then
  info "Ensuring config ISO is attached to ${PF_VM_NAME}"
  sudo virsh attach-disk "${PF_VM_NAME}" "${CFG_ISO}" sdz --type cdrom --mode readonly --config --persistent 2>/dev/null || true
else
  warn "Domain ${PF_VM_NAME} does not exist yet. Create the VM first (make up calls pf-vm-install)."
  exit 0
fi

ok "pfSense bootstrap complete."
exit 0
