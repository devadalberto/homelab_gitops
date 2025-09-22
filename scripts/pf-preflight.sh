#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pf-preflight.sh [OPTIONS]

Validate pfSense virtualization prerequisites and LAN addressing
before running the bootstrap workflow.

Options:
  -e, --env-file FILE       Source environment variables from FILE.
                            Defaults to $REPO_ROOT/.env when present.
      --skip-ip-validation  Skip LAN/IP validation performed via Python.
  -h, --help               Display this help message and exit.
USAGE
}

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
}

die() {
  log FAIL "$*" >&2
  exit 1
}

warn() {
  log WARN "$*" >&2
}

info() {
  log INFO "$*"
}

ok() {
  log OK "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_ENV_FILE="${REPO_ROOT}/.env"

REQUESTED_ENV_FILE=""
SKIP_IP_VALIDATION="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env-file)
      if [[ $# -lt 2 ]]; then
        die "Missing value for $1"
      fi
      REQUESTED_ENV_FILE="$2"
      shift 2
      ;;
    --skip-ip-validation)
      SKIP_IP_VALIDATION="true"
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
      die "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "${REQUESTED_ENV_FILE}" ]]; then
  if [[ -n "${ENV_FILE:-}" ]]; then
    REQUESTED_ENV_FILE="${ENV_FILE}"
  elif [[ -f "${DEFAULT_ENV_FILE}" ]]; then
    REQUESTED_ENV_FILE="${DEFAULT_ENV_FILE}"
  fi
fi

if [[ -n "${REQUESTED_ENV_FILE}" ]]; then
  if [[ ! -f "${REQUESTED_ENV_FILE}" ]]; then
    die "Environment file '${REQUESTED_ENV_FILE}' not found"
  fi
  info "Loading environment from ${REQUESTED_ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source "${REQUESTED_ENV_FILE}"
  set +a
else
  info "No environment file provided; using existing environment"
fi

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Required command '${cmd}' is not available"
  fi
}

BASE_DEPS=(awk grep sed)
info "Checking base command dependencies"
for dep in "${BASE_DEPS[@]}"; do
  require_cmd "$dep"
  info " - ${dep} available"
done

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_BRIDGE_INTERFACE="${PF_BRIDGE_INTERFACE:-br0}"
PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
LAN_CIDR="${LAN_CIDR:-}"
TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP:-}"
LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE:-}"
METALLB_POOL_START="${METALLB_POOL_START:-}"
METALLB_POOL_END="${METALLB_POOL_END:-}"

check_pf_domain() {
  if ! command -v virsh >/dev/null 2>&1; then
    warn "virsh command not found; skipping pfSense domain validation"
    return
  fi

  info "Validating pfSense domain '${PF_VM_NAME}'"
  if ! virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; then
    die "pfSense domain '${PF_VM_NAME}' does not exist. Run 'make up' to create it."
  fi

  local domain_state
  domain_state="$(virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)"
  if [[ "${domain_state}" != "running" ]]; then
    warn "pfSense domain '${PF_VM_NAME}' not running (state=${domain_state}); attempting to start"
    if virsh start "${PF_VM_NAME}" >/dev/null 2>&1; then
      sleep 2
      domain_state="$(virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)"
    fi
    if [[ "${domain_state}" != "running" ]]; then
      die "pfSense domain '${PF_VM_NAME}' is not running after attempted start"
    fi
  fi
  ok "pfSense domain '${PF_VM_NAME}' is running"
}

check_pf_installer() {
  if [[ -z "${PF_INSTALLER_SRC}" ]]; then
    warn "PF_INSTALLER_SRC not defined; skipping installer validation"
    return
  fi

  if [[ -f "${PF_INSTALLER_SRC}" ]]; then
    ok "Found pfSense installer at ${PF_INSTALLER_SRC}"
    return
  fi

  if [[ "${PF_INSTALLER_SRC}" == *.gz ]] && [[ -f "${PF_INSTALLER_SRC%.gz}" ]]; then
    ok "Found extracted pfSense installer at ${PF_INSTALLER_SRC%.gz}"
    return
  fi

  warn "PF_INSTALLER_SRC '${PF_INSTALLER_SRC}' does not exist"
}

validate_ips() {
  if [[ "${SKIP_IP_VALIDATION}" == "true" ]]; then
    info "Skipping IP validation due to --skip-ip-validation"
    return
  fi

  if [[ -z "${LAN_CIDR}" ]]; then
    warn "LAN_CIDR not provided; skipping IP validation"
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not available; skipping IP validation"
    return
  fi

  info "Validating LAN and service IPs against ${LAN_CIDR}"
  if LAN_CIDR="${LAN_CIDR}" \
     TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP}" \
     LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE}" \
     METALLB_POOL_START="${METALLB_POOL_START}" \
     METALLB_POOL_END="${METALLB_POOL_END}" \
     python3 - <<'PY'
import ipaddress
import os
import sys

cidr = os.environ.get("LAN_CIDR", "").strip()
if not cidr:
    print("LAN_CIDR is empty; unable to validate addresses", file=sys.stderr)
    raise SystemExit(1)

try:
    network = ipaddress.ip_network(cidr, strict=False)
except ValueError as exc:
    print(f"LAN_CIDR {cidr!r} is invalid: {exc}", file=sys.stderr)
    raise SystemExit(1)

errors = []

def validate_ip(name: str) -> None:
    value = os.environ.get(name, "").strip()
    if not value:
        return
    try:
        ip = ipaddress.ip_address(value)
    except ValueError as exc:
        errors.append(f"{name} {value!r} is invalid: {exc}")
        return
    if ip not in network:
        errors.append(f"{name} {value} not in {cidr}")

def validate_range(name: str, value: str) -> None:
    parts = [segment.strip() for segment in value.split("-", 1)]
    if len(parts) != 2:
        errors.append(f"{name} '{value}' is malformed; expected 'start-end'")
        return
    start_raw, end_raw = parts
    try:
        start_ip = ipaddress.ip_address(start_raw)
        end_ip = ipaddress.ip_address(end_raw)
    except ValueError as exc:
        errors.append(f"{name} '{value}' invalid: {exc}")
        return
    if start_ip not in network or end_ip not in network:
        errors.append(f"{name} {value} not fully inside {cidr}")
    if int(start_ip) > int(end_ip):
        errors.append(f"{name} '{value}' start is after end")

for key in ("TRAEFIK_LOCAL_IP", "METALLB_POOL_START", "METALLB_POOL_END"):
    validate_ip(key)

range_value = os.environ.get("LABZ_METALLB_RANGE", "").strip()
if range_value:
    validate_range("LABZ_METALLB_RANGE", range_value)

if errors:
    for line in errors:
        print(line, file=sys.stderr)
    raise SystemExit(1)
PY
  then
    ok "LAN and MetalLB IP ranges validated"
  else
    die "LAN/IP validation failed"
  fi
}

align_metallb_pool() {
  if [[ -z "${LAN_CIDR}" ]]; then
    warn "LAN_CIDR not provided; skipping MetalLB pool evaluation"
    return
  fi

  local helper="${REPO_ROOT}/scripts/net-calc.sh"
  if [[ ! -x "${helper}" ]]; then
    warn "MetalLB helper ${helper} not found; skipping pool evaluation"
    return
  fi

  local -a netcalc_env=("LAN_CIDR=${LAN_CIDR}")
  if [[ -n ${METALLB_POOL_START:-} ]]; then
    netcalc_env+=("METALLB_POOL_START=${METALLB_POOL_START}")
  fi
  if [[ -n ${METALLB_POOL_END:-} ]]; then
    netcalc_env+=("METALLB_POOL_END=${METALLB_POOL_END}")
  fi

  local netcalc_output
  if ! netcalc_output=$(env LOG_LEVEL=error "${netcalc_env[@]}" "${helper}"); then
    warn "MetalLB pool evaluation failed; see errors above"
    return
  fi

  eval "${netcalc_output}"

  local range="${LABZ_METALLB_RANGE:-${METALLB_POOL_START}-${METALLB_POOL_END}}"

  if [[ ${NETCALC_SOURCE:-calculated} == "provided" ]]; then
    ok "MetalLB pool ${range} is valid within ${LAN_CIDR}"
  else
    local message="MetalLB pool adjusted to ${range}; update METALLB_POOL_START/METALLB_POOL_END"
    case "${NETCALC_REASON:-}" in
      missing_both)
        message="MetalLB pool not defined; recommended ${range}"
        ;;
      missing_start)
        message="METALLB_POOL_START not set; recommended ${range}"
        ;;
      missing_end)
        message="METALLB_POOL_END not set; recommended ${range}"
        ;;
      invalid_start)
        message="METALLB_POOL_START '${NETCALC_ORIGINAL_START}' invalid; recommended ${range}"
        ;;
      invalid_end)
        message="METALLB_POOL_END '${NETCALC_ORIGINAL_END}' invalid; recommended ${range}"
        ;;
      outside_cidr)
        message="MetalLB pool ${NETCALC_ORIGINAL_START}-${NETCALC_ORIGINAL_END} outside ${LAN_CIDR}; recommended ${range}"
        ;;
      start_reserved)
        message="MetalLB start ${NETCALC_ORIGINAL_START} is reserved; recommended ${range}"
        ;;
      end_reserved)
        message="MetalLB end ${NETCALC_ORIGINAL_END} is reserved; recommended ${range}"
        ;;
      reversed)
        message="MetalLB pool start/end reversed; recommended ${range}"
        ;;
    esac
    warn "${message}"
    info "Update METALLB_POOL_START=${METALLB_POOL_START} and METALLB_POOL_END=${METALLB_POOL_END} in your environment"
  fi

  if [[ ${NETCALC_FALLBACK:-0} -eq 1 ]]; then
    warn "Unable to find unused MetalLB pool; using ${range}"
  fi

  if [[ -n ${NETCALC_WARNINGS:-} ]]; then
    IFS=',' read -r -a netcalc_warnings <<<"${NETCALC_WARNINGS}"
    for token in "${netcalc_warnings[@]}"; do
      case "${token}" in
        missing_ping)
          warn "ping command not available; pool availability checks skipped"
          ;;
        missing_ip)
          warn "ip command not available; neighbor checks skipped"
          ;;
        ping_exec_error)
          warn "ping failed while evaluating MetalLB pool"
          ;;
        ip_cmd_failed)
          warn "ip neigh failed while evaluating MetalLB pool"
          ;;
        no_availability_checks)
          warn "Unable to confirm MetalLB pool availability"
          ;;
        "")
          ;;
        *)
          warn "MetalLB helper warning: ${token}"
          ;;
      esac
    done
  fi

  METALLB_POOL_START="${METALLB_POOL_START}"
  METALLB_POOL_END="${METALLB_POOL_END}"
  LABZ_METALLB_RANGE="${range}"
}

check_bridge() {
  if ! command -v ip >/dev/null 2>&1; then
    warn "ip command not available; skipping bridge validation"
    return
  fi

  if ! ip -br link show "${PF_BRIDGE_INTERFACE}" >/dev/null 2>&1; then
    warn "Bridge ${PF_BRIDGE_INTERFACE} not found"
    return
  fi

  local bridge_state
  bridge_state="$(ip -br link show "${PF_BRIDGE_INTERFACE}" | awk '{print $2}')"
  if [[ "${bridge_state}" == "UP" ]]; then
    ok "Bridge ${PF_BRIDGE_INTERFACE} is UP"
  else
    warn "Bridge ${PF_BRIDGE_INTERFACE} state is ${bridge_state}"
  fi
}

info "Starting pfSense preflight checks"
check_pf_domain
check_pf_installer
align_metallb_pool
validate_ips
check_bridge
ok "pfSense preflight checks completed successfully"
