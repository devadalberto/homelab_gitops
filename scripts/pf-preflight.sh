#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-}"
if [[ -n "${ENV_FILE}" && -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

fail() { echo "[FAIL] $*" >&2; exit 78; }
warn() { echo "[WARN] $*" >&2; }
ok()   { echo "[OK] $*"; }

# Dependencies
for b in sudo virsh awk grep sed; do command -v "$b" >/dev/null 2>&1 || fail "Missing dependency: $b"; done

PF_VM_NAME="${PF_VM_NAME:-pfsense-uranus}"
PF_INSTALLER_SRC="${PF_INSTALLER_SRC:-}"
LAN_CIDR="${LAN_CIDR:-}"
TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP:-}"
LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE:-}"
METALLB_POOL_START="${METALLB_POOL_START:-}"
METALLB_POOL_END="${METALLB_POOL_END:-}"

# 1) pfSense domain must exist and be running
if ! sudo virsh dominfo "${PF_VM_NAME}" >/dev/null 2>&1; then
  fail "pfSense domain ${PF_VM_NAME} does not exist yet. Run 'make up' to create via pf-vm-install."
fi
STATE="$(sudo virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)"
if [[ "${STATE}" != "running" ]]; then
  warn "pfSense domain ${PF_VM_NAME} is not running (state=${STATE}). Attempting start..."
  sudo virsh start "${PF_VM_NAME}" >/dev/null 2>&1 || true
  sleep 1
  STATE="$(sudo virsh domstate "${PF_VM_NAME}" 2>/dev/null || true)"
  [[ "${STATE}" == "running" ]] || fail "pfSense domain ${PF_VM_NAME} is not running after start."
fi
ok "pfSense domain ${PF_VM_NAME} is running."

# 2) Installer policy: if domain exists, installer is optional. If PF_INSTALLER_SRC set but missing, warn not fail.
if [[ -n "${PF_INSTALLER_SRC}" && ! -f "${PF_INSTALLER_SRC}" ]]; then
  if [[ "${PF_INSTALLER_SRC}" == *.gz && -f "${PF_INSTALLER_SRC%.gz}" ]]; then
    ok "Using expanded installer ${PF_INSTALLER_SRC%.gz}"
  else
    warn "PF_INSTALLER_SRC points to '${PF_INSTALLER_SRC}', not found. Ignoring since VM exists."
  fi
fi

# 3) Network sanity: validate IPs are within LAN_CIDR (Python if available)
py="$(command -v python3 || true)"
if [[ -n "${py}" && -n "${LAN_CIDR}" ]]; then
  "$py" - <<PY || fail "IP/CIDR validation failed."
import ipaddress, os
cidr=os.environ.get("LAN_CIDR","")
ti=os.environ.get("TRAEFIK_LOCAL_IP","")
r=os.environ.get("LABZ_METALLB_RANGE","")
s=os.environ.get("METALLB_POOL_START","")
e=os.environ.get("METALLB_POOL_END","")
net=ipaddress.ip_network(cidr, strict=False)
def in_net(ip): 
    try: return ipaddress.ip_address(ip) in net
    except: return False
errs=[]
if ti and not in_net(ti): errs.append(f"TRAEFIK_LOCAL_IP {ti} not in LAN_CIDR {cidr}")
if r:
    try:
        start,end=r.split("-",1)
        if not (in_net(start) and in_net(end)):
            errs.append(f"LABZ_METALLB_RANGE {r} not inside {cidr}")
    except Exception: errs.append(f"LABZ_METALLB_RANGE malformed: {r}")
if s and not in_net(s): errs.append(f"METALLB_POOL_START {s} not in {cidr}")
if e and not in_net(e): errs.append(f"METALLB_POOL_END {e} not in {cidr}")
if errs:
    print("\n".join(errs)); raise SystemExit(1)
PY
  ok "LAN/MetalLB/Traefik IPs validated within ${LAN_CIDR}."
else
  warn "Skipping IP validation (python3 or LAN_CIDR missing)."
fi

# 4) Prefer UP br0 present
if ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -qx "br0"; then
  ok "Found UP br0."
else
  warn "br0 not UP; pfSense NIC fallback may use another bridge."
fi

ok "Preflight complete. pfSense is OK; proceed with bootstrap."
exit 0
