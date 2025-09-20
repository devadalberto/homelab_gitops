#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PF_LAN_LIB="${REPO_ROOT}/scripts/lib/pf_lan.sh"
if [[ -f "${PF_LAN_LIB}" ]]; then
  # shellcheck source=scripts/lib/pf_lan.sh
  source "${PF_LAN_LIB}"
else
  echo "Unable to locate scripts/lib/pf_lan.sh" >&2
  exit 70
fi

VM="${1:-pfsense-uranus}"

DEFAULT_LAN_BRIDGE="virbr-lan"
LAN_ALIAS_IP="192.168.1.2"
LAN_PREFIX="24"
LAN_NETWORK="192.168.1.0"
FALLBACK_IP="192.168.1.1"

LAN_BRIDGE=""
LAN_BRIDGE_SOURCE=""

interface_exists() {
  local dev="$1"
  if [[ -z ${dev} ]]; then
    return 1
  fi
  if command -v ip >/dev/null 2>&1; then
    ip link show dev "${dev}" >/dev/null 2>&1
  else
    [[ -e "/sys/class/net/${dev}" ]]
  fi
}

detect_lan_bridge() {
  local -a candidates=()
  local -a reasons=()
  local link="${PF_LAN_LINK:-}"

  if [[ -n ${link} ]]; then
    local kind=""
    local name=""
    if [[ ${link} == *:* ]]; then
      kind=${link%%:*}
      name=${link#*:}
    else
      kind="bridge"
      name=${link}
    fi
    case ${kind} in
      network)
        local resolved=""
        if resolved=$(pf_lan_resolve_network_bridge "${name}"); then
          candidates+=("${resolved}")
          reasons+=("PF_LAN_LINK network:${name}")
        else
          printf 'WARNING: Unable to resolve PF_LAN_LINK network:%s to host bridge\n' "${name}" >&2
        fi
        ;;
      bridge|tap)
        candidates+=("${name}")
        reasons+=("PF_LAN_LINK ${kind}:${name}")
        ;;
      *)
        candidates+=("${name}")
        reasons+=("PF_LAN_LINK ${kind}:${name}")
        ;;
    esac
  fi

  if [[ -n ${PF_LAN_BRIDGE:-} ]]; then
    candidates+=("${PF_LAN_BRIDGE}")
    reasons+=("PF_LAN_BRIDGE")
  fi

  candidates+=("${DEFAULT_LAN_BRIDGE}")
  reasons+=("fallback ${DEFAULT_LAN_BRIDGE}")

  local idx
  for idx in "${!candidates[@]}"; do
    local candidate="${candidates[$idx]}"
    local reason="${reasons[$idx]}"
    if [[ -z ${candidate} ]]; then
      continue
    fi
    if interface_exists "${candidate}"; then
      LAN_BRIDGE="${candidate}"
      LAN_BRIDGE_SOURCE="${reason}"
      return 0
    fi
    if [[ ${reason} != fallback* ]]; then
      printf 'WARNING: Candidate LAN interface %s (%s) not present on host\n' "${candidate}" "${reason}" >&2
    fi
  done

  LAN_BRIDGE="${DEFAULT_LAN_BRIDGE}"
  LAN_BRIDGE_SOURCE="fallback ${DEFAULT_LAN_BRIDGE}"
  return 1
}

if [[ ${EUID:-} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    pf_lan_set_ip_cmd sudo ip
  fi
fi

cleanup_alias() {
  pf_lan_temp_addr_cleanup || true
}

trap cleanup_alias EXIT INT TERM

detect_lan_bridge || true

bridge_summary=""
if command -v ip >/dev/null 2>&1; then
  bridge_summary=$(ip -br a)
fi

echo "=== domiflist ==="; sudo virsh domiflist "$VM" || true
echo; echo "=== domblklist ==="; sudo virsh domblklist "$VM" || true
echo; echo "=== dumpxml (interfaces/disks/controllers) ==="
sudo virsh dumpxml "$VM" | sed -n 's/^[[:space:]]*//; /<interface\|<disk\|<controller/p' || true

echo; echo "=== bridges (host) ==="
if [[ -n ${bridge_summary} ]]; then
  printf '%s\n' "${bridge_summary}" | grep -E 'virbr|br0' || true
  if [[ -n ${LAN_BRIDGE} ]]; then
    if ! printf '%s\n' "${bridge_summary}" | awk -v dev="${LAN_BRIDGE}" '$1 == dev {exit 0} END {exit 1}'; then
      ip -br addr show dev "${LAN_BRIDGE}" || true
    fi
  fi
else
  echo "ip command not available; skipping bridge summary" >&2
fi
if [[ -n ${LAN_BRIDGE} ]]; then
  echo "# Selected LAN bridge: ${LAN_BRIDGE} (${LAN_BRIDGE_SOURCE})"
fi

echo; echo "=== probe 10.10.0.1 and ${FALLBACK_IP} ==="
ping -c1 -W1 10.10.0.1 || true
curl -kIs --connect-timeout 5 "https://10.10.0.1/" || true

fallback_ping_success=false
fallback_curl_success=false
pf_lan_temp_addr_ensure "${LAN_BRIDGE}" "${LAN_ALIAS_IP}" "${LAN_PREFIX}" "${LAN_NETWORK}" || true
if ping -c1 -W1 "${FALLBACK_IP}"; then
  fallback_ping_success=true
fi
if curl -kIs --connect-timeout 5 "https://${FALLBACK_IP}/"; then
  fallback_curl_success=true
fi
cleanup_alias

if [[ ${fallback_ping_success} == true ]]; then
  printf 'WARNING: pfSense responded at legacy default %s; configuration import likely failed.\n' "${FALLBACK_IP}" >&2
  if [[ ${fallback_curl_success} == true ]]; then
    printf 'WARNING: HTTPS probe to %s succeeded; USB bootstrap may not have applied.\n' "${FALLBACK_IP}" >&2
  fi
fi

tcpdump_iface="${LAN_BRIDGE:-${DEFAULT_LAN_BRIDGE}}"
echo; echo "=== brief tcpdump on ${tcpdump_iface} (arp/icmp) ==="
if interface_exists "${tcpdump_iface}"; then
  sudo timeout 8 tcpdump -nni "${tcpdump_iface}" "arp or icmp" || true
fi
