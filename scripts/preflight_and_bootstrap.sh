#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
else
  FALLBACK_LIB="${SCRIPT_DIR}/lib/common_fallback.sh"
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
readonly EX_TEMPFAIL=75
readonly EX_CONFIG=78

ASSUME_YES=false
ALLOW_UFW=false
DELETE_PREVIOUS=false
PREFLIGHT_ONLY=false
CONTEXT_ONLY=false
DRY_RUN=false
ENV_FILE_OVERRIDE=""
ENV_FILE_PATH=""

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

usage() {
  cat <<'USAGE'
Usage: preflight_and_bootstrap.sh [OPTIONS]

Run host preflight checks, align MetalLB networking, and optionally execute the
bootstrap workflow for the Uranus homelab Minikube cluster.

Options:
  --env-file PATH               Load configuration overrides from PATH.
  --assume-yes                  Automatically confirm interactive prompts.
  --allow-ufw                   Keep UFW enabled and add Kubernetes rules.
  --delete-previous-environment Remove any existing Minikube profile.
  --preflight-only              Run checks and exit without bootstrapping.
  --dry-run                     Log mutating actions without executing them.
  --context-preflight           Discover environment details and exit.
  --verbose                     Increase logging verbosity to debug.
  -h, --help                    Show this help message.

Exit codes:
  0   Success.
  64  Usage error (invalid CLI arguments).
  69  Missing required dependencies.
  70  Runtime failure such as download errors.
  75  Temporary failure (retry later).
  78  Configuration error (missing environment file).
USAGE
}

format_command() {
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

write_root_file() {
  local path=$1
  shift || true
  local content=$1
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] tee ${path} <<'EOF'"
    printf '%s\n' "${content}"
    log_info "[DRY-RUN] EOF"
    return 0
  fi
  if [[ $(id -u) -eq 0 ]]; then
    printf '%s' "${content}" >"${path}"
  else
    if ! command -v sudo >/dev/null 2>&1; then
      die ${EX_UNAVAILABLE} "sudo is required to modify ${path}"
    fi
    printf '%s' "${content}" | sudo tee "${path}" >/dev/null
  fi
}

kubectl_apply_manifest() {
  local manifest=$1
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl apply -f - <<'EOF'"
    printf '%s\n' "${manifest}"
    log_info "[DRY-RUN] EOF"
    return 0
  fi
  need kubectl || return $?
  printf '%s\n' "${manifest}" | kubectl apply -f -
}

ensure_namespace_safe() {
  local namespace=$1
  if [[ ${DRY_RUN} == true ]]; then
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_debug "Namespace ${namespace} already exists"
    else
      log_info "[DRY-RUN] kubectl create namespace ${namespace}"
    fi
    return 0
  fi
  ensure_namespace "${namespace}"
}

declare -a CLEANUP_PODS=()

register_cleanup_pod() {
  CLEANUP_PODS+=("$1/$2")
}

cleanup() {
  local entry namespace name
  if [[ ${DRY_RUN} == true || ${#CLEANUP_PODS[@]} -eq 0 ]]; then
    return
  fi
  for entry in "${CLEANUP_PODS[@]}"; do
    namespace=${entry%%/*}
    name=${entry##*/}
    if command -v kubectl >/dev/null 2>&1; then
      kubectl -n "${namespace}" delete pod "${name}" --ignore-not-found >/dev/null 2>&1 || true
    fi
  done
}

trap cleanup EXIT INT TERM

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    ENV_FILE_PATH="${ENV_FILE_OVERRIDE}"
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    load_env "${ENV_FILE_OVERRIDE}" || die ${EX_CONFIG} "Failed to load ${ENV_FILE_OVERRIDE}"
    return
  fi
  local candidates=(
    "${REPO_ROOT}/.env"
    "${SCRIPT_DIR}/.env"
    "/opt/homelab/.env"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    log_debug "Checking for environment file at ${candidate}"
    if [[ -f ${candidate} ]]; then
      ENV_FILE_PATH="${candidate}"
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  ENV_FILE_PATH=""
  log_debug "No environment file present in default search locations"
}

maybe_sudo() {
  if [[ $(id -u) -eq 0 ]]; then
    run_cmd "$@"
  else
    if command -v sudo >/dev/null 2>&1; then
      run_cmd sudo "$@"
    else
      die ${EX_UNAVAILABLE} "sudo is required for $*"
    fi
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage
        die ${EX_USAGE} "--env-file requires a path argument"
      fi
      ENV_FILE_OVERRIDE="$2"
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
      log_set_level debug
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
    --dry-run)
      DRY_RUN=true
      PREFLIGHT_ONLY=true
      shift
      ;;
    --context-preflight)
      CONTEXT_ONLY=true
      shift
      ;;
    -h | --help)
      usage
      exit ${EX_OK}
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        usage
        die ${EX_USAGE} "Unexpected positional arguments: $*"
      fi
      ;;
    -*)
      usage
      die ${EX_USAGE} "Unknown option: $1"
      ;;
    *)
      usage
      die ${EX_USAGE} "Positional arguments are not supported"
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
    if ! eval "$(
      python3 <<'PY'
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
  if ! need ip python3; then
    die ${EX_UNAVAILABLE} "ip and python3 are required for network discovery"
  fi
  local json
  if ! json=$(
    python3 <<'PY'
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
    die ${EX_SOFTWARE} "Unable to determine active network context"
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
  if [[ -n "${PREV_IFACE:-}" && ("${PREV_IFACE}" != "${NETWORK_IFACE}" || "${PREV_ADDR:-}" != "${NETWORK_ADDR}" || "${PREV_CIDR:-}" != "${NETWORK_CIDR}" || "${PREV_GW:-}" != "${NETWORK_GW}" || "${PREV_MTU:-}" != "${NETWORK_MTU}") ]]; then
    NETWORK_CHANGED=1
    log_warn "Network fingerprint changed since last run"
    log_warn "Previous: iface=${PREV_IFACE:-?}, addr=${PREV_ADDR:-?}, gw=${PREV_GW:-?}, mtu=${PREV_MTU:-?}"
    log_warn "Current : iface=${NETWORK_IFACE}, addr=${NETWORK_ADDR}, gw=${NETWORK_GW}, mtu=${NETWORK_MTU}"
    if [[ "${ASSUME_YES}" != "true" ]]; then
      local prompt_ts reply
      prompt_ts=$(date +'%Y-%m-%dT%H:%M:%S%z')
      printf '%s [WARN ] %s' "${prompt_ts}" "Continue with new network context? [Y/n]: "
      read -r reply
      if [[ ! ${reply} =~ ^([Yy]|)$ ]]; then
        die ${EX_SOFTWARE} "Aborting due to network change"
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

adapt_address_pools() {
  if [[ -z "${METALLB_POOL_START}" && -n "${PREV_METALLB_START:-}" ]]; then
    METALLB_POOL_START="${PREV_METALLB_START}"
  fi
  if [[ -z "${METALLB_POOL_END}" && -n "${PREV_METALLB_END:-}" ]]; then
    METALLB_POOL_END="${PREV_METALLB_END}"
  fi
  local -a netcalc_env=("LAN_CIDR=${NETWORK_CIDR}")
  if [[ -n ${NETWORK_ADDR:-} ]]; then
    netcalc_env+=("LAN_ADDR=${NETWORK_ADDR}")
  fi
  if [[ -n ${METALLB_POOL_START:-} ]]; then
    netcalc_env+=("METALLB_POOL_START=${METALLB_POOL_START}")
  fi
  if [[ -n ${METALLB_POOL_END:-} ]]; then
    netcalc_env+=("METALLB_POOL_END=${METALLB_POOL_END}")
  fi

  local netcalc_output
  if ! netcalc_output=$(env "${netcalc_env[@]}" "${SCRIPT_DIR}/net-calc.sh"); then
    die ${EX_CONFIG} "Unable to determine a MetalLB pool for ${NETWORK_CIDR}"
  fi

  eval "${netcalc_output}"

  LABZ_METALLB_RANGE="${LABZ_METALLB_RANGE:-${METALLB_POOL_START}-${METALLB_POOL_END}}"
  export METALLB_POOL_START METALLB_POOL_END LABZ_METALLB_RANGE

  if [[ ${NETCALC_SOURCE:-calculated} == "provided" ]]; then
    log_info "MetalLB pool confirmed: ${LABZ_METALLB_RANGE}"
  else
    log_info "MetalLB pool selected: ${LABZ_METALLB_RANGE}"
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

print_context_summary() {
  log_info "Context summary"
  if [[ -n ${ENV_FILE_PATH} ]]; then
    log_info "  Environment file: ${ENV_FILE_PATH}"
  else
    log_info "  Environment file: <not found>"
  fi
  log_info "  State file: ${STATE_PATH}"
  log_info "  Network interface: ${NETWORK_IFACE} (${NETWORK_CLASS})"
  log_info "  Address: ${NETWORK_ADDR}/${NETWORK_PREFIX}"
  log_info "  Gateway: ${NETWORK_GW:-<none>}"
  log_info "  MTU: ${NETWORK_MTU:-unknown}"
  log_info "  MetalLB pool: ${METALLB_POOL_START}-${METALLB_POOL_END}"
  log_info "  Traefik IP: ${TRAEFIK_LOCAL_IP}"
}

ensure_state_dir() {
  if [[ ! -d "${STATE_DIR}" ]]; then
    run_cmd mkdir -p "${STATE_DIR}"
  fi
}

write_state() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Updating state file at ${STATE_PATH}"
    return 0
  fi
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
    write_root_file "${modules_file}" $'br_netfilter\n'
  fi
}

ensure_sysctls() {
  local kube_conf="/etc/sysctl.d/99-kubernetes.conf"
  local desired=$'net.bridge.bridge-nf-call-iptables=1\nnet.bridge.bridge-nf-call-ip6tables=1\nnet.ipv4.ip_forward=1\n'
  if [[ ! -f "${kube_conf}" ]] || ! diff -q <(printf '%s' "${desired}") "${kube_conf}" >/dev/null 2>&1; then
    log_info "Updating ${kube_conf}"
    write_root_file "${kube_conf}" "${desired}"
    NEED_SYSCTL_RELOAD=1
    NEED_MINIKUBE_RESTART=1
  fi
  local inotify_conf="/etc/sysctl.d/99-inotify.conf"
  if [[ ! -f "${inotify_conf}" ]] || ! grep -q 'fs.inotify.max_user_watches=524288' "${inotify_conf}"; then
    log_info "Setting inotify limits"
    write_root_file "${inotify_conf}" $'fs.inotify.max_user_watches=524288\n'
    NEED_SYSCTL_RELOAD=1
    NEED_MINIKUBE_RESTART=1
  fi
  local fsfile_conf="/etc/sysctl.d/99-fsfilemax.conf"
  if [[ ! -f "${fsfile_conf}" ]] || ! grep -q 'fs.file-max=1048576' "${fsfile_conf}"; then
    log_info "Raising fs.file-max limit"
    write_root_file "${fsfile_conf}" $'fs.file-max=1048576\n'
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
  write_root_file "${limits_file}" $'* soft nofile 1048576\n* hard nofile 1048576\n'
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
  local entry name path link_path before after
  local alternatives_changed=0
  for entry in "${targets[@]}"; do
    name=${entry%% *}
    path=${entry##* }
    link_path="/etc/alternatives/${name}"
    before=""
    if [[ -e "${link_path}" || -L "${link_path}" ]]; then
      before=$(readlink -f "${link_path}" 2>/dev/null || true)
    fi
    if maybe_sudo update-alternatives --set "${name}" "${path}" >/dev/null 2>&1; then
      log_info "Switched ${name} to legacy backend"
      NEED_MINIKUBE_RESTART=1
      after=""
      if [[ -e "${link_path}" || -L "${link_path}" ]]; then
        after=$(readlink -f "${link_path}" 2>/dev/null || true)
      fi
      if [[ "${after}" != "${before}" ]]; then
        alternatives_changed=1
      fi
    else
      log_warn "Could not switch ${name} to legacy backend"
    fi
  done

  if [[ ${alternatives_changed} -eq 1 ]] && command -v docker >/dev/null 2>&1; then
    log_info "iptables alternatives changed; restarting Docker to refresh legacy chains"
    if command -v systemctl >/dev/null 2>&1; then
      if maybe_sudo systemctl restart docker >/dev/null 2>&1; then
        log_info "Docker daemon restarted"
        return
      fi
      log_warn "systemctl restart docker failed; attempting service fallback"
    fi
    if maybe_sudo service docker restart >/dev/null 2>&1; then
      log_info "Docker daemon restarted via service command"
    else
      log_warn "Unable to restart Docker via service command"
    fi
  fi
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
  local kube_version="${LABZ_KUBERNETES_VERSION:-${KUBERNETES_VERSION:-v1.31.3}}"
  if [[ ${kube_version} != v* ]]; then
    kube_version="v${kube_version}"
  fi
  local extra_args="--kubernetes-version=${kube_version} --cni=bridge --extra-config=kubeadm.pod-network-cidr=10.244.0.0/16 --extra-config=apiserver.service-node-port-range=30000-32767"
  if [[ ${NEED_MINIKUBE_RESTART} -eq 1 ]]; then
    if [[ "${PREFLIGHT_ONLY}" == "true" ]]; then
      log_warn "System changes detected; defer Minikube restart until bootstrap runs"
      SKIP_MINIKUBE_START="false"
    else
      if ! need minikube; then
        die ${EX_UNAVAILABLE} "minikube is required to restart the cluster"
      fi
      log_warn "System changes detected; restarting Minikube profile ${profile}"
      run_cmd minikube stop -p "${profile}" || true
      run_cmd minikube start \
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
  if [[ -n ${ENV_FILE_PATH} ]]; then
    args+=("--env-file" "${ENV_FILE_PATH}")
  fi
  if [[ "${DELETE_PREVIOUS}" == "true" ]]; then
    args+=("--delete-previous-environment")
  fi
  if [[ ${DRY_RUN} == true ]]; then
    args+=("--dry-run")
  fi
  if [[ -x "scripts/uranus_nuke_and_bootstrap.sh" ]]; then
    log_info "Executing uranus_nuke_and_bootstrap.sh"
    (cd "${REPO_ROOT}" && scripts/uranus_nuke_and_bootstrap.sh "${args[@]}")
  else
    log_warn "scripts/uranus_nuke_and_bootstrap.sh not found"
  fi
}

ensure_kubectl_context() {
  if ! need kubectl; then
    die ${EX_UNAVAILABLE} "kubectl is required to configure the cluster context"
  fi
  local profile="${LABZ_MINIKUBE_PROFILE:-labz}"
  log_info "Switching kubectl context to ${profile}"
  run_cmd kubectl config use-context "${profile}"
}

ensure_kube_proxy_mode() {
  if ! need kubectl; then
    die ${EX_UNAVAILABLE} "kubectl is required for kube-proxy configuration"
  fi
  log_info "Ensuring kube-proxy operates in iptables mode"
  local tmp
  tmp=$(mktemp)
  if ! kubectl -n kube-system get configmap kube-proxy -o json >"${tmp}" 2>/dev/null; then
    log_warn "Unable to retrieve kube-proxy ConfigMap"
    rm -f "${tmp}"
    return
  fi
  if
    python3 <<'PY'
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
    "${tmp}"
  then
    log_info "kube-proxy already configured for iptables"
    rm -f "${tmp}"
    return
  fi
  log_info "Patching kube-proxy ConfigMap"
  run_cmd kubectl apply -f "${tmp}"
  rm -f "${tmp}"
  run_cmd kubectl -n kube-system rollout restart daemonset/kube-proxy
  retry 5 5 kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=5m
}

wait_for_readiness() {
  if ! need kubectl; then
    die ${EX_UNAVAILABLE} "kubectl is required for cluster readiness checks"
  fi
  log_info "Waiting for kube-proxy DaemonSet to become ready"
  retry 5 5 kubectl -n kube-system rollout status daemonset/kube-proxy --timeout=5m
  log_info "Waiting for CoreDNS deployment to become available"
  retry 5 5 kubectl -n kube-system rollout status deployment/coredns --timeout=5m
  log_info "Running API reachability probe via netshoot"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl netshoot connectivity probe"
    return
  fi
  kubectl -n kube-system delete pod netshoot-preflight --ignore-not-found >/dev/null 2>&1 || true
  register_cleanup_pod kube-system netshoot-preflight
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
  local args=()
  if [[ -n ${ENV_FILE_PATH} ]]; then
    args+=("--env-file" "${ENV_FILE_PATH}")
  fi
  if [[ "${ASSUME_YES}" == "true" ]]; then
    args+=("--assume-yes")
  fi
  if [[ ${DRY_RUN} == true ]]; then
    args+=("--dry-run")
  fi
  if [[ -x "scripts/uranus_homelab_one.sh" ]]; then
    log_info "Executing uranus_homelab_one.sh"
    (cd "${REPO_ROOT}" && scripts/uranus_homelab_one.sh "${args[@]}")
  else
    log_warn "scripts/uranus_homelab_one.sh not found"
  fi
}

reconcile_metallb_pool() {
  if ! need kubectl; then
    die ${EX_UNAVAILABLE} "kubectl is required to reconcile MetalLB"
  fi
  log_info "Applying MetalLB IPAddressPool ${LABZ_METALLB_RANGE}"
  ensure_namespace_safe metallb-system
  local pool_manifest advertisement
  if ! pool_manifest=$(metallb_render_ip_pool_manifest "homelab-pool" "metallb-system"); then
    die ${EX_CONFIG} "Failed to render MetalLB IPAddressPool"
  fi
  advertisement=$(
    cat <<'EOF'
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
EOF
  )
  kubectl_apply_manifest "${pool_manifest}"
  kubectl_apply_manifest "${advertisement}"
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
      run_cmd kubectl -n flux-system rollout restart deploy/"${ctrl}"
      kubectl -n flux-system rollout status deploy/"${ctrl}" --timeout=5m
    fi
  done
}

final_diagnostics() {
  if ! need kubectl; then
    die ${EX_UNAVAILABLE} "kubectl is required for final diagnostics"
  fi
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
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl netshoot validation"
  else
    kubectl -n kube-system delete pod netshoot-validate --ignore-not-found >/dev/null 2>&1 || true
    register_cleanup_pod kube-system netshoot-validate
    kubectl -n kube-system run netshoot-validate \
      --image=nicolaka/netshoot:latest \
      --restart=Never \
      --command \
      -- curl -sk https://10.96.0.1:443/ -m 2
    kubectl -n kube-system wait --for=condition=complete pod/netshoot-validate --timeout=120s >/dev/null
    kubectl -n kube-system logs netshoot-validate || true
    kubectl -n kube-system delete pod netshoot-validate --ignore-not-found >/dev/null 2>&1 || true
  fi
  if kubectl get ns flux-system >/dev/null 2>&1; then
    log_info "Validation: Flux resources"
    kubectl -n flux-system get gitrepositories,kustomizations
  fi
}

main() {
  parse_args "$@"
  ensure_state_dir
  load_environment
  load_previous_state
  collect_network_context
  compare_fingerprint
  adapt_address_pools
  print_context_summary
  : "${METALLB_HELM_VERSION:=0.14.7}"
  export METALLB_HELM_VERSION
  if [[ ${CONTEXT_ONLY} == true ]]; then
    log_info "Context preflight requested; exiting without mutating actions"
    return
  fi
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
