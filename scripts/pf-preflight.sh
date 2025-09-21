#!/usr/bin/env bash
set -euo pipefail

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
}

die() {
  log FAIL "$*" >&2
  exit 78
}

warn() {
  log WARN "$*" >&2
}

ok() {
  log OK "$*"
}

info() {
  log INFO "$*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_ENV_FILE="${REPO_ROOT}/.env"

ARG_ENV_FILE="${1:-}"
REQUESTED_ENV_FILE="${ARG_ENV_FILE:-${ENV_FILE:-}}"
if [[ -z "${REQUESTED_ENV_FILE}" && -f "${DEFAULT_ENV_FILE}" ]]; then
  REQUESTED_ENV_FILE="${DEFAULT_ENV_FILE}"
fi

if [[ -n "${REQUESTED_ENV_FILE}" ]]; then
  if [[ -f "${REQUESTED_ENV_FILE}" ]]; then
    info "Sourcing environment from ${REQUESTED_ENV_FILE}"
    # shellcheck disable=SC1090
    source "${REQUESTED_ENV_FILE}"
  else
    warn "Environment file '${REQUESTED_ENV_FILE}' not found; continuing without it."
  fi
else
  warn "No environment file provided; continuing with current shell environment."
fi

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
LAN_CIDR="${LAN_CIDR:-}"
TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP:-}"
LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE:-}"
METALLB_POOL_START="${METALLB_POOL_START:-}"
METALLB_POOL_END="${METALLB_POOL_END:-}"

info "Checking base dependencies"
BASE_DEPS=(awk grep sed)
for dep in "${BASE_DEPS[@]}"; do
  if ! command -v "${dep}" >/dev/null 2>&1; then
    die "Missing dependency: ${dep}"
  fi
  info " - ${dep} available"
done

if command -v virsh >/dev/null 2>&1; then
  info "Validating pfSense domain '${PF_VM_NAME}'"
  if ! virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; then
    die "pfSense domain ${PF_VM_NAME} does not exist yet. Run 'make up' to create it."
  fi
  DOMAIN_STATE="$(virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)"
  if [[ "${DOMAIN_STATE}" != "running" ]]; then
    warn "pfSense domain ${PF_VM_NAME} is not running (state=${DOMAIN_STATE}). Attempting start..."
    if virsh start "${PF_VM_NAME}" >/dev/null 2>&1; then
      sleep 1
      DOMAIN_STATE="$(virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)"
    fi
    if [[ "${DOMAIN_STATE}" != "running" ]]; then
      die "pfSense domain ${PF_VM_NAME} is not running after start."
    fi
  fi
  ok "pfSense domain ${PF_VM_NAME} is running."
else
  warn "Skipping pfSense domain validation because 'virsh' is not available."
fi

if [[ -n "${PF_INSTALLER_SRC}" ]]; then
  if [[ -f "${PF_INSTALLER_SRC}" ]]; then
    ok "pfSense installer found at ${PF_INSTALLER_SRC}."
  elif [[ "${PF_INSTALLER_SRC}" == *.gz && -f "${PF_INSTALLER_SRC%.gz}" ]]; then
    ok "Using expanded installer ${PF_INSTALLER_SRC%.gz}"
  else
    warn "PF_INSTALLER_SRC points to '${PF_INSTALLER_SRC}', not found."
  fi
fi

if [[ -z "${LAN_CIDR}" ]]; then
  warn "LAN_CIDR not provided; skipping network validation."
else
  if command -v python3 >/dev/null 2>&1; then
    info "Validating IP addresses against ${LAN_CIDR}"
    if LAN_CIDR="${LAN_CIDR}" \
       TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP}" \
       LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE}" \
       METALLB_POOL_START="${METALLB_POOL_START}" \
       METALLB_POOL_END="${METALLB_POOL_END}" \
       python3 - <<'PY'
import ipaddress
import os

cidr = os.environ.get("LAN_CIDR", "")
try:
    network = ipaddress.ip_network(cidr, strict=False)
except Exception as exc:  # pragma: no cover - defensive
    print(f"LAN_CIDR {cidr!r} is invalid: {exc}")
    raise SystemExit(1)

errors = []

def validate_single(name: str) -> None:
    value = os.environ.get(name, "").strip()
    if not value:
        return
    try:
        ip = ipaddress.ip_address(value)
    except Exception as exc:
        errors.append(f"{name} {value!r} is invalid: {exc}")
        return
    if ip not in network:
        errors.append(f"{name} {value} not in LAN_CIDR {cidr}")

for key in ("TRAEFIK_LOCAL_IP", "METALLB_POOL_START", "METALLB_POOL_END"):
    validate_single(key)

range_value = os.environ.get("LABZ_METALLB_RANGE", "").strip()
if range_value:
    try:
        start_raw, end_raw = [segment.strip() for segment in range_value.split("-", 1)]
        start_ip = ipaddress.ip_address(start_raw)
        end_ip = ipaddress.ip_address(end_raw)
        if start_ip not in network or end_ip not in network:
            errors.append(
                f"LABZ_METALLB_RANGE {range_value} not inside {cidr}"
            )
    except ValueError:
        errors.append(
            f"LABZ_METALLB_RANGE '{range_value}' is malformed; expected 'start-end'"
        )
    except Exception as exc:  # pragma: no cover - defensive
        errors.append(f"LABZ_METALLB_RANGE {range_value!r} invalid: {exc}")

if errors:
    print("\n".join(errors))
    raise SystemExit(1)
PY
    then
      ok "LAN/MetalLB/Traefik IPs validated within ${LAN_CIDR}."
    else
      die "IP/CIDR validation failed."
    fi
  else
    warn "python3 not available; skipping network validation."
  fi
fi

if command -v ip >/dev/null 2>&1; then
  if ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -qx "br0"; then
    ok "Found UP br0."
  else
    warn "br0 not UP; pfSense NIC fallback may use another bridge."
  fi
else
  warn "Skipping bridge validation because 'ip' command is unavailable."
fi

ok "Preflight complete. pfSense is OK; proceed with bootstrap."
exit 0
