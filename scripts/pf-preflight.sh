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

BASE_DEPS=(awk grep sed ip)
info "Checking base command dependencies"
for dep in "${BASE_DEPS[@]}"; do
  require_cmd "$dep"
  info " - ${dep} available"
done

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_SERIAL_INSTALLER_PATH="${PF_SERIAL_INSTALLER_PATH:-}"
PF_WAN_BRIDGE="${PF_WAN_BRIDGE:-}"
PF_LAN_BRIDGE="${PF_LAN_BRIDGE:-}"
LAN_CIDR="${LAN_CIDR:-}"
LAN_GW_IP="${LAN_GW_IP:-}"
LAN_DHCP_FROM="${LAN_DHCP_FROM:-}"
LAN_DHCP_TO="${LAN_DHCP_TO:-}"
TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP:-}"
LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE:-}"
METALLB_POOL_START="${METALLB_POOL_START:-}"
METALLB_POOL_END="${METALLB_POOL_END:-}"
LEGACY_PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
LEGACY_PF_BRIDGE_INTERFACE="${PF_BRIDGE_INTERFACE:-}"
LEGACY_DHCP_FROM="${DHCP_FROM:-}"
LEGACY_DHCP_TO="${DHCP_TO:-}"

if [[ -n "${REQUESTED_ENV_FILE}" ]]; then
  ENV_SOURCE_LABEL="${REQUESTED_ENV_FILE}"
else
  ENV_SOURCE_LABEL="your environment"
fi

enumerate_bridges() {
  if ! command -v ip >/dev/null 2>&1; then
    printf '  (ip command not available to enumerate bridges)\n'
    return 0
  fi

  local output
  output="$(ip -br link show type bridge 2>/dev/null || true)"
  if [[ -z "${output//[[:space:]]/}" ]]; then
    printf '  (no Linux bridge devices detected)\n'
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    printf '  - %s\n' "${line}"
  done <<< "${output}"
}

require_env_var() {
  local var_name="$1"
  local message="$2"
  local value="${!var_name:-}"

  if [[ -z "${value}" ]]; then
    if [[ -n "${message}" ]]; then
      die "${message}"
    fi
    die "${var_name} is required. Update ${ENV_SOURCE_LABEL} to define it."
  fi
}

ensure_required_environment() {
  info "Validating required environment variables"

  if [[ -z "${PF_SERIAL_INSTALLER_PATH}" ]]; then
    local installer_msg
    installer_msg=$'PF_SERIAL_INSTALLER_PATH is required but empty.\nSet PF_SERIAL_INSTALLER_PATH in '
    installer_msg+="${ENV_SOURCE_LABEL}"
    installer_msg+=$' to the absolute path of the Netgate serial installer (.img or .img.gz).'
    if [[ -n "${LEGACY_PF_INSTALLER_SRC}" ]]; then
      installer_msg+=$' Legacy PF_INSTALLER_SRC is set; rename it to PF_SERIAL_INSTALLER_PATH.'
    fi
    die "${installer_msg}"
  fi

  require_env_var "PF_WAN_BRIDGE" "PF_WAN_BRIDGE is required. Update ${ENV_SOURCE_LABEL} so the WAN bridge is explicit."

  if [[ -z "${PF_LAN_BRIDGE}" ]]; then
    local lan_msg
    lan_msg=$'PF_LAN_BRIDGE is required but empty.\nDefine PF_LAN_BRIDGE in '
    lan_msg+="${ENV_SOURCE_LABEL}"
    lan_msg+=$' so pfSense can attach to the correct LAN bridge.'
    if [[ -n "${LEGACY_PF_BRIDGE_INTERFACE}" ]]; then
      lan_msg+=$' Legacy PF_BRIDGE_INTERFACE is set; rename it to PF_LAN_BRIDGE.'
    fi

    local bridges
    bridges="$(enumerate_bridges)"
    if [[ -n "${bridges}" ]]; then
      lan_msg+=$'\nAvailable bridge devices:\n'
      lan_msg+="${bridges%$'\n'}"
    fi

    die "${lan_msg}"
  fi

  require_env_var "LAN_CIDR" "LAN_CIDR must be defined in ${ENV_SOURCE_LABEL} (e.g., 10.10.0.0/24)."
  require_env_var "LAN_GW_IP" "LAN_GW_IP must be defined in ${ENV_SOURCE_LABEL}."

  if [[ -z "${LAN_DHCP_FROM}" ]]; then
    local dhcp_from_msg
    dhcp_from_msg=$'LAN_DHCP_FROM is required but empty.\nSet LAN_DHCP_FROM in '
    dhcp_from_msg+="${ENV_SOURCE_LABEL}"
    dhcp_from_msg+=$' to the start of the pfSense DHCP scope.'
    if [[ -n "${LEGACY_DHCP_FROM}" ]]; then
      dhcp_from_msg+=$' Legacy DHCP_FROM is set; rename it to LAN_DHCP_FROM.'
    fi
    die "${dhcp_from_msg}"
  fi

  if [[ -z "${LAN_DHCP_TO}" ]]; then
    local dhcp_to_msg
    dhcp_to_msg=$'LAN_DHCP_TO is required but empty.\nSet LAN_DHCP_TO in '
    dhcp_to_msg+="${ENV_SOURCE_LABEL}"
    dhcp_to_msg+=$' to the end of the pfSense DHCP scope.'
    if [[ -n "${LEGACY_DHCP_TO}" ]]; then
      dhcp_to_msg+=$' Legacy DHCP_TO is set; rename it to LAN_DHCP_TO.'
    fi
    die "${dhcp_to_msg}"
  fi
}

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
  local installer="${PF_SERIAL_INSTALLER_PATH}"
  info "Validating pfSense serial installer path"

  if [[ ! -f "${installer}" ]]; then
    die "PF_SERIAL_INSTALLER_PATH '${installer}' does not exist. Download the Netgate serial installer and update ${ENV_SOURCE_LABEL}."
  fi

  case "${installer}" in
    *.img|*.img.gz)
      ;;
    *)
      die "PF_SERIAL_INSTALLER_PATH '${installer}' must point to a .img or .img.gz archive"
      ;;
  esac

  ok "Found pfSense serial installer at ${installer}"
}

validate_ips() {
  if [[ "${SKIP_IP_VALIDATION}" == "true" ]]; then
    info "Skipping IP validation due to --skip-ip-validation"
    return
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not available; skipping IP validation"
    return
  fi

  info "Validating LAN and service IPs against ${LAN_CIDR}"
  if LAN_CIDR="${LAN_CIDR}" \
     LAN_GW_IP="${LAN_GW_IP}" \
     LAN_DHCP_FROM="${LAN_DHCP_FROM}" \
     LAN_DHCP_TO="${LAN_DHCP_TO}" \
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

def _get_env(name: str) -> str:
    return os.environ.get(name, "").strip()

def validate_host(name: str, *, required: bool = False):
    value = _get_env(name)
    if not value:
        if required:
            errors.append(f"{name} is required but empty")
        return None
    try:
        ip = ipaddress.ip_address(value)
    except ValueError as exc:
        errors.append(f"{name} {value!r} is invalid: {exc}")
        return None
    if ip not in network:
        errors.append(f"{name} {value} not in {cidr}")
    return ip

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

validate_host("LAN_GW_IP", required=True)
dhcp_start = validate_host("LAN_DHCP_FROM", required=True)
dhcp_end = validate_host("LAN_DHCP_TO", required=True)
pool_start = validate_host("METALLB_POOL_START")
pool_end = validate_host("METALLB_POOL_END")

if dhcp_start and dhcp_end and int(dhcp_start) > int(dhcp_end):
    errors.append(f"LAN_DHCP_FROM ({dhcp_start}) exceeds LAN_DHCP_TO ({dhcp_end})")

if pool_start and pool_end and int(pool_start) > int(pool_end):
    errors.append(f"METALLB_POOL_START ({pool_start}) exceeds METALLB_POOL_END ({pool_end})")

validate_host("TRAEFIK_LOCAL_IP")

range_value = _get_env("LABZ_METALLB_RANGE")
if range_value:
    validate_range("LABZ_METALLB_RANGE", range_value)

if errors:
    for line in errors:
        print(line, file=sys.stderr)
    raise SystemExit(1)
PY
  then
    ok "LAN addressing and VIP ranges validated"
  else
    die "LAN/IP validation failed"
  fi
}

check_bridge() {
  local role="$1"
  local bridge="$2"

  if ! command -v ip >/dev/null 2>&1; then
    die "ip command not available; cannot validate ${role} bridge '${bridge}'"
  fi

  if ! ip -br link show "${bridge}" >/dev/null 2>&1; then
    die "${role} bridge '${bridge}' not found. Update ${ENV_SOURCE_LABEL} or create the bridge."
  fi

  local bridge_state
  bridge_state="$(ip -br link show "${bridge}" | awk '{print $2}')"
  if [[ "${bridge_state}" == "UP" ]]; then
    ok "${role} bridge ${bridge} is UP"
  else
    warn "${role} bridge ${bridge} state is ${bridge_state}"
  fi
}

info "Starting pfSense preflight checks"
ensure_required_environment
check_pf_domain
check_pf_installer
validate_ips
check_bridge "WAN" "${PF_WAN_BRIDGE}"
check_bridge "LAN" "${PF_LAN_BRIDGE}"
export VERIFIED_ENV=1
ok "VERIFIED_ENV exported"
ok "pfSense preflight checks completed successfully"
