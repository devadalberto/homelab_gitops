#!/usr/bin/env bash
set -euo pipefail

ASSUME_YES=false
VERBOSE=false
ALLOW_UFW=false
DELETE_PREVIOUS=false
PREFLIGHT_ONLY=false
ENV_FILE="./.env"
STATE_DIR="${HOME}/.homelab"
STATE_PATH="${STATE_DIR}/state.json"
export STATE_DIR
export STATE_PATH
NEED_MINIKUBE_RESTART=0
NEED_SYSCTL_RELOAD=0
NETWORK_CHANGED=0

METALLB_POOL_START="${METALLB_POOL_START:-}"
METALLB_POOL_END="${METALLB_POOL_END:-}"
TRAEFIK_LOCAL_IP="${TRAEFIK_LOCAL_IP:-}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

timestamp() {
  date -u +"%Y-%m-%d %H:%M:%S"
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

log_info() {
  log "INFO  $*"
}

log_warn() {
  log "WARN  $*"
}

log_error() {
  log "ERROR $*"
}

log_debug() {
  if [[ "${VERBOSE}" == "true" ]]; then
    log "DEBUG $*"
  fi
}

usage() {
  cat <<'USAGE'
Usage: preflight_and_bootstrap.sh [--env-file PATH] [--assume-yes] [--allow-ufw] [--verbose]
                                      [--delete-previous-environment] [--preflight-only]

Runs homelab preflight checks, adapts networking, and bootstraps the Minikube stack.
Use --preflight-only to run host checks without invoking the bootstrap script.
USAGE
}

maybe_sudo() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
  else
    if command -v sudo >/dev/null 2>&1; then
      sudo "$@"
    else
      log_error "sudo is required for $*"
      exit 1
    fi
  fi
}

require_command() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    log_info "Loading environment from ${ENV_FILE}"
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
  else
    log_warn "Environment file ${ENV_FILE} not found; continuing with defaults"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        ENV_FILE="$2"
        shift 2
        ;;
      --assume-yes)
        ASSUME_YES=true
        shift
        ;;
      --allow-ufw)
        ALLOW_UFW=true
        shift
        ;;
      --verbose)
        VERBOSE=true
        shift
        ;;
      --delete-previous-environment)
        DELETE_PREVIOUS=true
        shift
        ;;
      --preflight-only)
        PREFLIGHT_ONLY=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

classify_interface() {
  local iface=$1
  if [[ $iface == wl* || $iface == wifi* || $iface == wlp* || $iface == ath* ]]; then
    echo "wifi"
    return
  fi
  if command -v iw >/dev/null 2>&1; then
    if iw dev 2>/dev/null | grep -E "^\s*Interface ${iface}$" >/dev/null 2>&1; then
      echo "wifi"
      return
    fi
  fi
  if command -v iwconfig >/dev/null 2>&1; then
    if iwconfig "$iface" 2>&1 | grep -vi "no wireless extensions" | grep -q .; then
      echo "wifi"
      return
    fi
  fi
  echo "wired"
}

load_previous_state() {
  if [[ -f "${STATE_PATH}" ]]; then
    if ! eval "$(python3 <<'PY'
import json, os, shlex, sys
path = os.environ.get('STATE_PATH')
try:
    with open(path, 'r', encoding='utf-8') as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
for key in ('iface', 'cidr', 'addr', 'gw', 'mtu'):
    value = data.get(key)
    if value is not None:
        print(f'PREV_{key.upper()}={shlex.quote(str(value))}')
pool = data.get('metallb_pool') or {}
if pool.get('start'):
    print(f'PREV_METALLB_START={shlex.quote(str(pool.get("start")))}')
if pool.get('end'):
    print(f'PREV_METALLB_END={shlex.quote(str(pool.get("end")))}')
if data.get('traefik_ip'):
    print(f'PREV_TRAEFIK_IP={shlex.quote(str(data.get("traefik_ip")))}')
PY
)"; then
      log_warn "Unable to parse previous state file"
    fi
  fi
}

collect_network_context() {
  require_command ip python3
  local json
  if ! json=$(python3 <<'PY'
import ipaddress
import json
import subprocess
import sys

def run(cmd):
    return subprocess.check_output(cmd, text=True)

routes = run(["ip", "route", "show", "default"]).strip().splitlines()
if not routes:
    sys.exit(1)
parts = routes[0].split()
iface = ''
gw = ''
if 'dev' in parts:
    iface = parts[parts.index('dev') + 1]
if 'via' in parts:
    gw = parts[parts.index('via') + 1]
if not iface:
    sys.exit(1)
addr_data = json.loads(run(["ip", "-j", "addr", "show", "dev", iface]))
addr = None
prefix = None
for entry in addr_data:
    for info in entry.get('addr_info', []):
        if info.get('family') == 'inet':
            addr = info.get('local')
            prefix = info.get('prefixlen')
            break
    if addr:
        break
if addr is None or prefix is None:
    sys.exit(1)
network = ipaddress.ip_network(f"{addr}/{prefix}", strict=False)
link_data = json.loads(run(["ip", "-j", "link", "show", "dev", iface]))
mtu = link_data[0].get('mtu')
print(json.dumps({
    'iface': iface,
    'gw': gw,
    'addr': addr,
    'prefix': prefix,
    'cidr': str(network),
    'mtu': mtu,
}, separators=(',', ':')))
PY
); then
    log_error "Unable to determine active network context"
    exit 1
  fi
  NETWORK_IFACE=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["iface"])' <<<"${json}")
  NETWORK_GW=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("gw", ""))' <<<"${json}")
  NETWORK_ADDR=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["addr"])' <<<"${json}")
  NETWORK_PREFIX=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["prefix"])' <<<"${json}")
  NETWORK_CIDR=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data["cidr"])' <<<"${json}")
  NETWORK_MTU=$(python3 -c 'import json,sys; data=json.load(sys.stdin); print(data.get("mtu", ""))' <<<"${json}")
  NETWORK_CLASS=$(classify_interface "${NETWORK_IFACE}")
  log_info "Active network: iface=${NETWORK_IFACE} (${NETWORK_CLASS}), addr=${NETWORK_ADDR}/${NETWORK_PREFIX}, gw=${NETWORK_GW}, mtu=${NETWORK_MTU}"
  export NETWORK_IFACE NETWORK_GW NETWORK_ADDR NETWORK_PREFIX NETWORK_CIDR NETWORK_MTU NETWORK_CLASS
}

compare_fingerprint() {
  if [[ -n "${PREV_IFACE:-}" && ( "${PREV_IFACE}" != "${NETWORK_IFACE}" || "${PREV_ADDR:-}" != "${NETWORK_ADDR}" || "${PREV_CIDR:-}" != "${NETWORK_CIDR}" || "${PREV_GW:-}" != "${NETWORK_GW}" || "${PREV_MTU:-}" != "${NETWORK_MTU}" ) ]]; then
    NETWORK_CHANGED=1
    log_warn "Network fingerprint changed since last run"
    log_warn "Previous: iface=${PREV_IFACE:-?}, addr=${PREV_ADDR:-?}, gw=${PREV_GW:-?}, mtu=${PREV_MTU:-?}"
    log_warn "Current : iface=${NETWORK_IFACE}, addr=${NETWORK_ADDR}, gw=${NETWORK_GW}, mtu=${NETWORK_MTU}"
    if [[ "${ASSUME_YES}" != "true" ]]; then
      printf '[%s] WARN  %s' "$(timestamp)" "Continue with new network context? [Y/n]: "
      read -r reply
      if [[ ! ${reply} =~ ^([Yy]|)$ ]]; then
        log_error "Aborting due to network change"
        exit 1
      fi
    else
      log_info "--assume-yes supplied; continuing despite network change"
    fi
  fi
}

ip_in_cidr() {
  local ip=$1
  local cidr=$2
  python3 - "$ip" "$cidr" <<'PY'
import ipaddress
import sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    net = ipaddress.ip_network(sys.argv[2], strict=False)
    if ip in net and ip != net.network_address and ip != net.broadcast_address:
        print('1')
    else:
        print('0')
except Exception:
    print('0')
PY
}

ip_between() {
  local ip=$1
  local start=$2
  local end=$3
  python3 - "$ip" "$start" "$end" <<'PY'
import ipaddress
import sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
    start = ipaddress.ip_address(sys.argv[2])
    end = ipaddress.ip_address(sys.argv[3])
    print('1' if start <= ip <= end else '0')
except Exception:
    print('0')
PY
}

is_ip_in_use() {
  local ip=$1
  if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
    return 0
  fi
  if ip neigh show to "$ip" 2>/dev/null | grep -q "${ip}"; then
    return 0
  fi
  return 1
}

range_available() {
  local start=$1
  local end=$2
  local ips
  if ! ips=$(python3 - "$start" "$end" <<'PY'
import ipaddress
import sys
start = ipaddress.ip_address(sys.argv[1])
end = ipaddress.ip_address(sys.argv[2])
if start > end:
    sys.exit(1)
current = start
items = []
while current <= end:
    items.append(str(current))
    current += 1
print('\n'.join(items))
PY
); then
    return 1
  fi
  local ip
  while IFS= read -r ip; do
    if ! is_ip_in_use "$ip"; then
      continue
    fi
    log_debug "Address ${ip} appears active"
    return 1
  done <<<"${ips}"
  return 0
}

select_metallb_pool() {
  local candidate_lines
  candidate_lines=$(python3 <<'PY'
import ipaddress
import json
import os
addr = os.environ['NETWORK_ADDR']
cidr = os.environ['NETWORK_CIDR']
net = ipaddress.ip_network(cidr, strict=False)
addr_ip = ipaddress.ip_address(addr)
candidates = []
base24 = ipaddress.ip_network(f"{addr_ip}/24", strict=False)
pref_ips = []
for suffix in range(240, 251):
    candidate = base24.network_address + suffix
    if candidate in net and candidate != net.network_address and candidate != net.broadcast_address:
        pref_ips.append(candidate)
if len(pref_ips) == 11 and pref_ips[-1] in net:
    candidates.append((str(pref_ips[0]), str(pref_ips[-1])))
try:
    for subnet in reversed(list(net.subnets(new_prefix=29))):
        hosts = list(subnet.hosts())
        if len(hosts) >= 2:
            candidates.append((str(hosts[0]), str(hosts[-1])))
except ValueError:
    pass
hosts = list(net.hosts())
if hosts:
    candidates.append((str(hosts[0]), str(hosts[-1])))
seen = set()
unique = []
for start, end in candidates:
    key = (start, end)
    if key not in seen:
        seen.add(key)
        unique.append(f"{start},{end}")
print("\n".join(unique))
PY
)
  local selected_start=""
  local selected_end=""
  local line
  while IFS=',' read -r start end; do
    [[ -z "$start" ]] && continue
    if range_available "$start" "$end"; then
      selected_start="$start"
      selected_end="$end"
      break
    else
      log_debug "Pool ${start}-${end} in use; trying next candidate"
    fi
  done <<<"${candidate_lines}"
  if [[ -z "${selected_start}" ]]; then
    selected_start=$(head -n1 <<<"${candidate_lines}" | cut -d',' -f1)
    selected_end=$(head -n1 <<<"${candidate_lines}" | cut -d',' -f2)
    log_warn "Falling back to first candidate ${selected_start}-${selected_end} despite conflicts"
  fi
  METALLB_POOL_START="${selected_start}"
  METALLB_POOL_END="${selected_end}"
  LABZ_METALLB_RANGE="${METALLB_POOL_START}-${METALLB_POOL_END}"
  export METALLB_POOL_START METALLB_POOL_END LABZ_METALLB_RANGE
  log_info "MetalLB pool selected: ${LABZ_METALLB_RANGE}"
}

adapt_address_pools() {
  if [[ -z "${METALLB_POOL_START}" && -n "${PREV_METALLB_START:-}" ]]; then
    METALLB_POOL_START="${PREV_METALLB_START}"
  fi
  if [[ -z "${METALLB_POOL_END}" && -n "${PREV_METALLB_END:-}" ]]; then
    METALLB_POOL_END="${PREV_METALLB_END}"
  fi
  local start_ok end_ok
  if [[ -n "${METALLB_POOL_START}" ]]; then
    start_ok=$(ip_in_cidr "${METALLB_POOL_START}" "${NETWORK_CIDR}")
  else
    start_ok=0
  fi
  if [[ -n "${METALLB_POOL_END}" ]]; then
    end_ok=$(ip_in_cidr "${METALLB_POOL_END}" "${NETWORK_CIDR}")
  else
    end_ok=0
  fi
  if [[ "${start_ok}" != "1" || "${end_ok}" != "1" ]]; then
    log_warn "Existing MetalLB pool is outside current LAN; recalculating"
    select_metallb_pool
  else
    LABZ_METALLB_RANGE="${METALLB_POOL_START}-${METALLB_POOL_END}"
    export METALLB_POOL_START METALLB_POOL_END LABZ_METALLB_RANGE
    log_info "Reusing MetalLB pool ${LABZ_METALLB_RANGE}"
  fi
  if [[ -z "${TRAEFIK_LOCAL_IP}" && -n "${PREV_TRAEFIK_IP:-}" ]]; then
    TRAEFIK_LOCAL_IP="${PREV_TRAEFIK_IP}"
  fi
  if [[ -z "${TRAEFIK_LOCAL_IP}" || $(ip_in_cidr "${TRAEFIK_LOCAL_IP}" "${NETWORK_CIDR}") != 1 || $(ip_between "${TRAEFIK_LOCAL_IP}" "${METALLB_POOL_START}" "${METALLB_POOL_END}") != 1 ]]; then
    TRAEFIK_LOCAL_IP="${METALLB_POOL_START}"
    log_info "Assigning Traefik LoadBalancer IP ${TRAEFIK_LOCAL_IP}"
  else
    log_info "Keeping Traefik LoadBalancer IP ${TRAEFIK_LOCAL_IP}"
  fi
  export TRAEFIK_LOCAL_IP
}

ensure_state_dir() {
  if [[ ! -d "${STATE_DIR}" ]]; then
    mkdir -p "${STATE_DIR}"
  fi
}

write_state() {
  python3 <<'PY'
import json
import os
import sys
from datetime import datetime
state_path = os.environ['STATE_PATH']
data = {}
if os.path.exists(state_path):
    try:
        with open(state_path, 'r', encoding='utf-8') as fh:
            data = json.load(fh)
    except Exception:
        data = {}
data.update({
    'iface': os.environ['NETWORK_IFACE'],
    'cidr': os.environ['NETWORK_CIDR'],
    'addr': os.environ['NETWORK_ADDR'],
    'gw': os.environ['NETWORK_GW'],
    'mtu': int(os.environ.get('NETWORK_MTU') or 0),
    'link_type': os.environ.get('NETWORK_CLASS'),
    'ts': datetime.utcnow().replace(microsecond=0).isoformat() + 'Z',
})
data['metallb_pool'] = {
    'start': os.environ.get('METALLB_POOL_START', ''),
    'end': os.environ.get('METALLB_POOL_END', ''),
}
traefik_ip = os.environ.get('TRAEFIK_LOCAL_IP')
if traefik_ip:
    data['traefik_ip'] = traefik_ip
with open(state_path, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2)
    fh.write('\n')
PY
}

ensure_packages() {
  local packages=(conntrack socat ethtool iproute2 iptables arptables ebtables)
  local missing=()
  local pkg
  for pkg in "${packages[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing required packages: ${missing[*]}"
    maybe_sudo env DEBIAN_FRONTEND=noninteractive apt-get update
    maybe_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    NEED_MINIKUBE_RESTART=1
  else
    log_debug "All prerequisite packages already installed"
  fi
}

ensure_br_netfilter() {
  if ! lsmod | grep -q '^br_netfilter'; then
    log_info "Loading br_netfilter module"
    maybe_sudo modprobe br_netfilter || true
    NEED_MINIKUBE_RESTART=1
  else
    log_debug "br_netfilter already loaded"
  fi
  local modules_file="/etc/modules-load.d/k8s.conf"
  if [[ ! -f "${modules_file}" ]] || ! grep -q '^br_netfilter' "${modules_file}"; then
    log_info "Ensuring br_netfilter loads on boot"
    printf 'br_netfilter\n' | maybe_sudo tee "${modules_file}" >/dev/null
  fi
}

ensure_sysctls() {
  local kube_conf="/etc/sysctl.d/99-kubernetes.conf"
  local desired=$'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n'
  if [[ ! -f "${kube_conf}" ]] || ! diff -q <(printf '%s' "${desired}") "${kube_conf}" >/dev/null 2>&1; then
    log_info "Updating ${kube_conf}"
    printf '%s' "${desired}" | maybe_sudo tee "${kube_conf}" >/dev/null
    NEED_SYSCTL_RELOAD=1
    NEED_MINIKUBE_RESTART=1
  fi
  local inotify_conf="/etc/sysctl.d/99-inotify.conf"
  if [[ ! -f "${inotify_conf}" ]] || ! grep -q 'fs.inotify.max_user_watches=524288' "${inotify_conf}"; then
    log_info "Setting inotify limits"
    printf 'fs.inotify.max_user_watches=524288\n' | maybe_sudo tee "${inotify_conf}" >/dev/null
    NEED_SYSCTL_RELOAD=1
    NEED_MINIKUBE_RESTART=1
  fi
  local fsfile_conf="/etc/sysctl.d/99-fsfilemax.conf"
  if [[ ! -f "${fsfile_conf}" ]] || ! grep -q 'fs.file-max=1048576' "${fsfile_conf}"; then
    log_info "Raising fs.file-max limit"
    printf 'fs.file-max=1048576\n' | maybe_sudo tee "${fsfile_conf}" >/dev/null
    NEED_SYSCTL_RELOAD=1
    NEED_MINIKUBE_RESTART=1
  fi
}

ensure_limits_conf() {
  local limits_file="/etc/security/limits.d/k8s.conf"
  if [[ -f "${limits_file}" ]]; then
    log_debug "Limits file already present"
    return
  fi
  if [[ $(id -u) -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    log_warn "Skipping ${limits_file} because root privileges are required"
    return
  fi
  log_info "Writing ${limits_file}"
  cat <<'LIMITS' | maybe_sudo tee "${limits_file}" >/dev/null
* soft nofile 1048576
* hard nofile 1048576
LIMITS
}

reload_sysctl_if_needed() {
  if [[ ${NEED_SYSCTL_RELOAD} -eq 1 ]]; then
    log_info "Reloading sysctl settings"
    maybe_sudo sysctl --system >/dev/null
  fi
}

switch_iptables_legacy() {
  local targets=(
    "iptables /usr/sbin/iptables-legacy"
    "ip6tables /usr/sbin/ip6tables-legacy"
    "arptables /usr/sbin/arptables-legacy"
    "ebtables /usr/sbin/ebtables-legacy"
  )
  local entry name path
  for entry in "${targets[@]}"; do
    name=${entry%% *}
    path=${entry##* }
    if maybe_sudo update-alternatives --set "${name}" "${path}" >/dev/null 2>&1; then
      log_info "Switched ${name} to legacy backend"
      NEED_MINIKUBE_RESTART=1
    else
      log_warn "Could not switch ${name} to legacy backend"
    fi
  done
}

handle_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi
  local status
  status=$(maybe_sudo ufw status 2>/dev/null | head -n1 || true)
  if [[ ${status} != "Status: active" ]]; then
    log_debug "UFW inactive"
    return
  fi
  if [[ "${ALLOW_UFW}" == "true" ]]; then
    log_info "Configuring active UFW for Kubernetes networking"
    maybe_sudo ufw --force default allow routed
    local iface
    for iface in docker0 cni0 flannel.1; do
      if ip link show "$iface" >/dev/null 2>&1; then
        maybe_sudo ufw --force allow in on "$iface"
        maybe_sudo ufw --force allow out on "$iface"
      fi
    done
    while IFS= read -r iface; do
      maybe_sudo ufw --force allow in on "$iface"
      maybe_sudo ufw --force allow out on "$iface"
    done < <(ip -o link show | awk -F': ' '/^\d+: br-/ {print $2}')
    log_info "UFW rules updated"
  else
    log_warn "Disabling active UFW (use --allow-ufw to keep it enabled)"
    maybe_sudo ufw --force disable
    NEED_MINIKUBE_RESTART=1
  fi
}

run_os_preflight() {
  ensure_packages
  ensure_br_netfilter
  ensure_sysctls
  ensure_limits_conf
  reload_sysctl_if_needed
  switch_iptables_legacy
  handle_ufw
}

restart_minikube_if_needed() {
  local profile="${LABZ_MINIKUBE_PROFILE:-labz}"
  local driver="${LABZ_MINIKUBE_DRIVER:-docker}"
  local cpus="${LABZ_MINIKUBE_CPUS:-4}"
  local memory="${LABZ_MINIKUBE_MEMORY:-8192}"
  local disk="${LABZ_MINIKUBE_DISK:-60g}"
  local kube_version="${LABZ_KUBERNETES_VERSION:-${KUBERNETES_VERSION:-v1.29.4}}"
  if [[ ${kube_version} != v* ]]; then
    kube_version="v${kube_version}"
  fi
  local extra_args="--kubernetes-version=${kube_version} --cni=bridge --extra-config=kubeadm.pod-network-cidr=10.244.0.0/16 --extra-config=apiserver.service-node-port-range=30000-32767"
  if [[ ${NEED_MINIKUBE_RESTART} -eq 1 ]]; then
    if [[ "${PREFLIGHT_ONLY}" == "true" ]]; then
      log_warn "System changes detected; defer Minikube restart until bootstrap runs"
      SKIP_MINIKUBE_START="false"
    else
      require_command minikube
      log_warn "System changes detected; restarting Minikube profile ${profile}"
      minikube stop -p "${profile}" >/dev/null 2>&1 || true
      minikube start \
        -p "${profile}" \
        --driver="${driver}" \
        --cpus="${cpus}" \
        --memory="${memory}" \
        --disk-size="${disk}" \
        --kubernetes-version="${kube_version}" \
        --cni=bridge \
        --extra-config=kubeadm.pod-network-cidr=10.244.0.0/16 \
        --extra-config=apiserver.service-node-port-range=30000-32767
      SKIP_MINIKUBE_START="true"
    fi
  else
    SKIP_MINIKUBE_START="false"
  fi
  export SKIP_MINIKUBE_START
  export LABZ_MINIKUBE_EXTRA_ARGS="${extra_args}"
}

run_child_scripts() {
  local args=()
  if [[ "${ASSUME_YES}" == "true" ]]; then
    args+=("--assume-yes")
  fi
  args+=("--env-file" "${ENV_FILE}")
  if [[ "${DELETE_PREVIOUS}" == "true" ]]; then
    args+=("--delete-previous-environment")
  fi
  if [[ -x "scripts/uranus_nuke_and_bootstrap.sh" ]]; then
    log_info "Executing uranus_nuke_and_bootstrap.sh"
    (cd "${REPO_ROOT}" && scripts/uranus_nuke_and_bootstrap.sh "${args[@]}")
  else
    log_warn "scripts/uranus_nuke_and_bootstrap.sh not found"
  fi
}

ensure_kubectl_context() {
  require_command kubectl
  local profile="${LABZ_MINIKUBE_PROFILE:-labz}"
  log_info "Switching kubectl context to ${profile}"
  kubectl config use-context "${profile}" >/dev/null
}

ensure_kube_proxy_mode() {
  log_info "Ensuring kube-proxy operates in iptables mode"
  local tmp
  tmp=$(mktemp)
  if ! kubectl -n kube-system get configmap kube-proxy -o json >"${tmp}" 2>/dev/null; then
    log_warn "Unable to retrieve kube-proxy ConfigMap"
    rm -f "${tmp}"
    return
  fi
  if python3 <<'PY'
import json
import os
import re
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as fh:
    data = json.load(fh)
config = data.get('data', {}).get('kube-proxy.conf', '')
if 'mode: "iptables"' in config:
    sys.exit(0)
if 'mode:' in config:
    config = re.sub(r'^mode:.*$', 'mode: "iptables"', config, flags=re.MULTILINE)
else:
    config += '\nmode: "iptables"\n'
data['data']['kube-proxy.conf'] = config
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(data, fh)
PY
"${tmp}"; then
    log_info "kube-proxy already configured for iptables"
    rm -f "${tmp}"
    return
  fi
  log_info "Patching kube-proxy ConfigMap"
  kubectl apply -f "${tmp}" >/dev/null
  rm -f "${tmp}"
  kubectl -n kube-system rollout restart daemonset/kube-proxy
  kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=5m
}

wait_for_readiness() {
  log_info "Waiting for kube-proxy DaemonSet to become ready"
  kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=5m
  log_info "Waiting for CoreDNS deployment to become available"
  kubectl -n kube-system rollout status deployment/coredns --timeout=5m
  log_info "Running API reachability probe via netshoot"
  kubectl -n kube-system delete pod netshoot-preflight --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system run netshoot-preflight \
    --image=nicolaka/netshoot:latest \
    --restart=Never \
    --command \
    -- curl -sk https://10.96.0.1:443/ -m 2 >/dev/null
  kubectl -n kube-system wait --for=condition=complete pod/netshoot-preflight --timeout=120s >/dev/null
  kubectl -n kube-system logs netshoot-preflight >/dev/null 2>&1 || true
  kubectl -n kube-system delete pod netshoot-preflight --ignore-not-found >/dev/null 2>&1 || true
}

run_core_addons() {
  local args=("--env-file" "${ENV_FILE}")
  if [[ "${ASSUME_YES}" == "true" ]]; then
    args+=("--assume-yes")
  fi
  if [[ -x "scripts/uranus_homelab_one.sh" ]]; then
    log_info "Executing uranus_homelab_one.sh"
    (cd "${REPO_ROOT}" && scripts/uranus_homelab_one.sh "${args[@]}")
  else
    log_warn "scripts/uranus_homelab_one.sh not found"
  fi
}

reconcile_metallb_pool() {
  log_info "Applying MetalLB IPAddressPool ${LABZ_METALLB_RANGE}"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: labz-pool
  namespace: metallb-system
spec:
  addresses:
    - ${LABZ_METALLB_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: labz-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - labz-pool
EOF
}

restart_flux_controllers() {
  if ! kubectl get ns flux-system >/dev/null 2>&1; then
    log_debug "Flux not installed; skipping controller restart"
    return
  fi
  local controllers=(source-controller kustomize-controller)
  local ctrl
  for ctrl in "${controllers[@]}"; do
    if kubectl -n flux-system get deploy "${ctrl}" >/dev/null 2>&1; then
      log_info "Restarting Flux deployment ${ctrl}"
      kubectl -n flux-system rollout restart deploy/"${ctrl}"
      kubectl -n flux-system rollout status deploy/"${ctrl}" --timeout=5m
    fi
  done
}

final_diagnostics() {
  log_info "Final diagnostics"
  log_info "Default route overview"
  ip route show default
  log_info "Interface ${NETWORK_IFACE} details"
  ip addr show "${NETWORK_IFACE}"
  log_info "MTU for ${NETWORK_IFACE}: ${NETWORK_MTU}"
  log_info "iptables binary: $(readlink -f "$(command -v iptables)")"
  log_info "Validation: kube-proxy"
  kubectl -n kube-system get daemonset kube-proxy -o wide
  log_info "Validation: CoreDNS"
  kubectl -n kube-system get deployment coredns
  log_info "Validation: MetalLB"
  if kubectl get ns metallb-system >/dev/null 2>&1; then
    kubectl -n metallb-system get all
  else
    log_warn "MetalLB namespace missing"
  fi
  log_info "Validation: running netshoot probe"
  kubectl -n kube-system delete pod netshoot-validate --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n kube-system run netshoot-validate \
    --image=nicolaka/netshoot:latest \
    --restart=Never \
    --command \
    -- curl -sk https://10.96.0.1:443/ -m 2
  kubectl -n kube-system wait --for=condition=complete pod/netshoot-validate --timeout=120s >/dev/null
  kubectl -n kube-system logs netshoot-validate || true
  kubectl -n kube-system delete pod netshoot-validate --ignore-not-found >/dev/null 2>&1 || true
  if kubectl get ns flux-system >/dev/null 2>&1; then
    log_info "Validation: Flux resources"
    kubectl -n flux-system get gitrepositories,kustomizations
  fi
}

main() {
  parse_args "$@"
  ensure_state_dir
  load_env_file
  load_previous_state
  collect_network_context
  compare_fingerprint
  adapt_address_pools
  : "${METALLB_HELM_VERSION:=0.14.5}"
  export METALLB_HELM_VERSION
  run_os_preflight
  restart_minikube_if_needed
  if [[ "${PREFLIGHT_ONLY}" == "true" ]]; then
    write_state
    log_info "Preflight checks completed; bootstrap skipped by --preflight-only"
    return
  fi
  run_child_scripts
  ensure_kubectl_context
  ensure_kube_proxy_mode
  wait_for_readiness
  run_core_addons
  reconcile_metallb_pool
  restart_flux_controllers
  write_state
  final_diagnostics
  log_info "Preflight and bootstrap completed"
}

main "$@"
