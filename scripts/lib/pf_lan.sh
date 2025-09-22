#!/usr/bin/env bash
# Helper functions for pfSense LAN bridge detection and temporary host address assignment.

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "scripts/lib/pf_lan.sh is a helper library and must be sourced, not executed." >&2
  exit 3
fi

if [[ -n ${_HOMELAB_PF_LAN_LIB_SOURCED:-} ]]; then
  return 0
fi
readonly _HOMELAB_PF_LAN_LIB_SOURCED=1

_pf_lan_ip_cmd=(ip)

pf_lan_set_ip_cmd() {
  if [[ $# -eq 0 ]]; then
    _pf_lan_ip_cmd=(ip)
  else
    _pf_lan_ip_cmd=("$@")
  fi
}

_pf_lan_function_exists() {
  declare -F "$1" >/dev/null 2>&1
}

_pf_lan_log() {
  local level=${1:-info}
  shift || true
  local func="log_${level}"
  if _pf_lan_function_exists "${func}"; then
    "${func}" "$@"
  else
    printf '%s: %s\n' "${level^^}" "$*" >&2
  fi
}

_pf_lan_log_debug() { _pf_lan_log debug "$@"; }
_pf_lan_log_info() { _pf_lan_log info "$@"; }
_pf_lan_log_warn() { _pf_lan_log warn "$@"; }

_pf_lan_exec_ip() {
  "${_pf_lan_ip_cmd[@]}" "$@"
}

pf_lan_resolve_network_bridge() {
  local network_name="$1"
  if [[ -z ${network_name} ]]; then
    return 1
  fi
  if ! command -v virsh >/dev/null 2>&1; then
    return 1
  fi

  if command -v python3 >/dev/null 2>&1; then
    local bridge_name
    local net_xml
    net_xml=$(virsh net-dumpxml "${network_name}" 2>/dev/null) || return 1
    if [[ -n ${net_xml} ]]; then
      bridge_name=$(
        PF_LAN_NET_XML="${net_xml}" python3 <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

data = os.environ.get("PF_LAN_NET_XML", "")
if not data.strip():
    sys.exit(1)
root = ET.fromstring(data)
bridge = root.find('./bridge')
if bridge is None:
    sys.exit(1)
name = bridge.get('name')
if not name:
    sys.exit(1)
sys.stdout.write(name)
PY
      ) || return 1
      if [[ -n ${bridge_name} ]]; then
        printf '%s\n' "${bridge_name}"
        return 0
      fi
    fi
  else
    local bridge_name
    bridge_name=$(virsh net-dumpxml "${network_name}" 2>/dev/null |
      sed -n "s/.*<bridge[^>]*name='\([^']*\)'.*/\1/p" | head -n1)
    if [[ -n ${bridge_name} ]]; then
      printf '%s\n' "${bridge_name}"
      return 0
    fi
  fi
  return 1
}

pf_lan_temp_addr_reset() {
  PF_LAN_TEMP_ADDR_ADDED=false
  PF_LAN_TEMP_ADDR_CIDR=""
  PF_LAN_TEMP_ADDR_DEVICE=""
}

pf_lan_temp_addr_reset

pf_lan_temp_addr_ensure() {
  local device="$1"
  local ip="$2"
  local prefix="$3"
  local network="$4"
  local skip="${5:-false}"

  pf_lan_temp_addr_reset

  if [[ ${skip} == true ]]; then
    _pf_lan_log_debug "Skipping temporary LAN address assignment for ${device} (skip requested)"
    return 0
  fi

  if [[ -z ${device} ]]; then
    _pf_lan_log_warn "Unable to determine LAN bridge; skipping temporary host address assignment"
    return 1
  fi

  if [[ -z ${ip} || -z ${prefix} ]]; then
    _pf_lan_log_warn "Temporary LAN address or prefix not provided; skipping assignment for ${device}"
    return 1
  fi

  if [[ ${#_pf_lan_ip_cmd[@]} -eq 0 ]]; then
    _pf_lan_ip_cmd=(ip)
  fi

  if ! command -v "${_pf_lan_ip_cmd[0]}" >/dev/null 2>&1; then
    _pf_lan_log_warn "ip command not available; cannot manage temporary LAN address on ${device}"
    return 1
  fi

  local cidr
  cidr="${ip}/${prefix}"

  local existing_output=""
  local -a existing_cidrs=()
  if existing_output=$(_pf_lan_exec_ip -o -4 addr show dev "${device}" 2>/dev/null); then
    mapfile -t existing_cidrs < <(printf '%s\n' "${existing_output}" | awk '{print $4}')
  fi

  local existing_display=""
  if [[ ${#existing_cidrs[@]} -gt 0 ]]; then
    existing_display=$(printf '%s, ' "${existing_cidrs[@]}")
    existing_display=${existing_display%, }
  fi

  local reason=""
  if [[ -n ${network} && ${#existing_cidrs[@]} -gt 0 ]]; then
    if command -v python3 >/dev/null 2>&1; then
      local python_output=""
      local python_status=0
      local python_tmp=""
      python_tmp=$(mktemp) || python_tmp=""
      if [[ -z ${python_tmp} ]]; then
        _pf_lan_log_warn "Unable to create temporary file for IPv4 evaluation; continuing with temporary assignment"
      else
        if python3 - "${network}" "${prefix}" "${existing_cidrs[@]}" >"${python_tmp}" <<'PY'; then
import ipaddress
import sys

lan_network = sys.argv[1]
lan_prefix = sys.argv[2]

try:
    network = ipaddress.ip_network(f"{lan_network}/{lan_prefix}", strict=False)
except ValueError:
    sys.exit(2)

cidrs = sys.argv[3:]

matched = []
off_subnet = []
invalid = []

for cidr in cidrs:
    try:
        iface = ipaddress.ip_interface(cidr)
    except ValueError:
        invalid.append(cidr)
        continue
    if iface.ip in network:
        matched.append(cidr)
    else:
        off_subnet.append(cidr)

if matched:
    sys.stdout.write(", ".join(matched))
    sys.exit(0)

combined = off_subnet + invalid
if combined:
    sys.stdout.write(", ".join(combined))
    sys.exit(10)

sys.exit(1)
PY
          python_status=0
        else
          python_status=$?
        fi
        python_output="$(<"${python_tmp}")"
        rm -f -- "${python_tmp}" || true

        if [[ ${python_status} -eq 0 ]]; then
          _pf_lan_log_debug "Bridge ${device} already has LAN IPv4 address(es): ${python_output:-${existing_display}}"
          return 0
        elif [[ ${python_status} -eq 10 ]]; then
          local offsubnet_output
          offsubnet_output=${python_output:-${existing_display}}
          reason="Existing IPv4 address(es) ${offsubnet_output} are outside ${network}/${prefix}. "
        elif [[ ${python_status} -eq 1 ]]; then
          _pf_lan_log_debug "Bridge ${device} IPv4 assignments did not include usable addresses in ${network}/${prefix}; continuing with temporary assignment"
        else
          _pf_lan_log_warn "Unable to evaluate existing IPv4 assignments on ${device} (exit ${python_status}); continuing with temporary assignment"
        fi
      fi
    else
      _pf_lan_log_debug "python3 not available; skipping IPv4 assignment evaluation for ${device}"
    fi
  fi

  if [[ -n ${reason} ]]; then
    _pf_lan_log_warn "${reason}Assigning temporary ${cidr} to ${device} for connectivity checks"
  else
    _pf_lan_log_info "Assigning temporary ${cidr} to ${device} for connectivity checks"
  fi

  if _pf_lan_exec_ip addr add "${cidr}" dev "${device}" >/dev/null 2>&1; then
    PF_LAN_TEMP_ADDR_ADDED=true
    PF_LAN_TEMP_ADDR_CIDR=${cidr}
    PF_LAN_TEMP_ADDR_DEVICE=${device}
    return 0
  fi

  _pf_lan_log_warn "Unable to assign ${cidr} to ${device}; connectivity checks may fail"
  pf_lan_temp_addr_reset
  return 1
}

pf_lan_temp_addr_cleanup() {
  if [[ ${PF_LAN_TEMP_ADDR_ADDED} != true ]]; then
    PF_LAN_TEMP_ADDR_CIDR=""
    PF_LAN_TEMP_ADDR_DEVICE=""
    return 0
  fi

  if [[ -z ${PF_LAN_TEMP_ADDR_CIDR:-} || -z ${PF_LAN_TEMP_ADDR_DEVICE:-} ]]; then
    pf_lan_temp_addr_reset
    return 0
  fi

  if [[ ${#_pf_lan_ip_cmd[@]} -eq 0 ]]; then
    _pf_lan_ip_cmd=(ip)
  fi

  if ! command -v "${_pf_lan_ip_cmd[0]}" >/dev/null 2>&1; then
    _pf_lan_log_warn "ip command not available; cannot remove temporary LAN address"
    pf_lan_temp_addr_reset
    return 1
  fi

  if _pf_lan_exec_ip addr del "${PF_LAN_TEMP_ADDR_CIDR}" dev "${PF_LAN_TEMP_ADDR_DEVICE}" >/dev/null 2>&1; then
    _pf_lan_log_debug "Removed temporary ${PF_LAN_TEMP_ADDR_CIDR} from ${PF_LAN_TEMP_ADDR_DEVICE}"
    pf_lan_temp_addr_reset
    return 0
  fi

  _pf_lan_log_warn "Failed to remove temporary IP ${PF_LAN_TEMP_ADDR_CIDR} from ${PF_LAN_TEMP_ADDR_DEVICE}"
  pf_lan_temp_addr_reset
  return 1
}
