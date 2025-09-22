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
  log_trace() { :; }
  log_debug() { printf '[DEBUG] %s\n' "$*" >&2; }
  log_info() { printf '[ INFO] %s\n' "$*" >&2; }
  log_warn() { printf '[ WARN] %s\n' "$*" >&2; }
  log_error() { printf '[ERROR] %s\n' "$*" >&2; }
  die() {
    local status=1
    if [[ $# -gt 0 && $1 =~ ^[0-9]+$ ]]; then
      status=$1
      shift
    fi
    if [[ $# -gt 0 ]]; then
      log_error "$*"
    fi
    exit "${status}"
  }
  load_env() {
    if [[ $# -ne 1 ]]; then
      log_error "Usage: load_env <env-file>"
      return 64
    fi
    local env_file=$1
    if [[ ! -f ${env_file} ]]; then
      log_error "Environment file not found: ${env_file}"
      return 1
    fi
    local prev_state
    prev_state=$(set +o)
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    eval "${prev_state}"
  }
  need() {
    local missing=()
    local cmd
    for cmd in "$@"; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        missing+=("$cmd")
      fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      log_error "Missing required commands: ${missing[*]}"
      return 127
    fi
  }
fi

readonly EX_USAGE=64
readonly EX_CONFIG=78
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70

usage() {
  cat <<'USAGE'
Usage: net-calc.sh [OPTIONS]

Validate or derive MetalLB pool addresses for a LAN.

Options:
  -e, --env-file FILE       Source environment variables from FILE.
      --lan-cidr CIDR       Override the LAN CIDR to evaluate.
      --lan-addr IP         Provide a host IP within the LAN for heuristics.
      --start IP            Candidate MetalLB pool start address to validate.
      --end IP              Candidate MetalLB pool end address to validate.
      --skip-availability   Do not probe candidate ranges for activity.
  -h, --help                Show this help message and exit.
USAGE
}

ENV_FILE=""
LAN_CIDR_OVERRIDE=""
LAN_ADDR_OVERRIDE=""
START_OVERRIDE=""
END_OVERRIDE=""
CHECK_AVAILABILITY=true

while [[ $# -gt 0 ]]; do
  case "$1" in
  -e | --env-file)
    if [[ $# -lt 2 ]]; then
      die ${EX_USAGE} "Missing value for $1"
    fi
    ENV_FILE="$2"
    shift 2
    ;;
  --lan-cidr)
    if [[ $# -lt 2 ]]; then
      die ${EX_USAGE} "Missing value for $1"
    fi
    LAN_CIDR_OVERRIDE="$2"
    shift 2
    ;;
  --lan-addr)
    if [[ $# -lt 2 ]]; then
      die ${EX_USAGE} "Missing value for $1"
    fi
    LAN_ADDR_OVERRIDE="$2"
    shift 2
    ;;
  --start)
    if [[ $# -lt 2 ]]; then
      die ${EX_USAGE} "Missing value for $1"
    fi
    START_OVERRIDE="$2"
    shift 2
    ;;
  --end)
    if [[ $# -lt 2 ]]; then
      die ${EX_USAGE} "Missing value for $1"
    fi
    END_OVERRIDE="$2"
    shift 2
    ;;
  --skip-availability | --no-availability)
    CHECK_AVAILABILITY=false
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  *)
    die ${EX_USAGE} "Unknown option: $1"
    ;;
  esac
done

if [[ $# -gt 0 ]]; then
  die ${EX_USAGE} "Unexpected positional arguments: $*"
fi

if [[ -n ${ENV_FILE} ]]; then
  load_env "${ENV_FILE}" || die ${EX_CONFIG} "Failed to load ${ENV_FILE}"
fi

if ! need python3 >/dev/null 2>&1; then
  die ${EX_UNAVAILABLE} "python3 is required to evaluate network ranges"
fi

LAN_CIDR="${LAN_CIDR_OVERRIDE:-${LAN_CIDR:-${NETWORK_CIDR:-}}}"
if [[ -z ${LAN_CIDR} ]]; then
  die ${EX_USAGE} "LAN CIDR must be provided via --lan-cidr or LAN_CIDR/NETWORK_CIDR"
fi

LAN_ADDR="${LAN_ADDR_OVERRIDE:-${LAN_ADDR:-${NETWORK_ADDR:-}}}"
if [[ -n ${LAN_ADDR} ]]; then
  log_debug "Using LAN address ${LAN_ADDR} for pool heuristics"
fi

if [[ -n ${START_OVERRIDE} ]]; then
  METALLB_POOL_START="${START_OVERRIDE}"
fi
if [[ -n ${END_OVERRIDE} ]]; then
  METALLB_POOL_END="${END_OVERRIDE}"
fi

START_INPUT="${METALLB_POOL_START:-}"
END_INPUT="${METALLB_POOL_END:-}"

NETCALC_CHECK="1"
if [[ ${CHECK_AVAILABILITY} == false ]]; then
  NETCALC_CHECK="0"
fi

calc_output=$(
  NETCALC_LAN_CIDR="${LAN_CIDR}" \
    NETCALC_LAN_ADDR="${LAN_ADDR}" \
    NETCALC_START="${START_INPUT}" \
    NETCALC_END="${END_INPUT}" \
    NETCALC_CHECK_AVAILABILITY="${NETCALC_CHECK}" \
    python3 <<'PY'
import ipaddress
import os
import shutil
import subprocess
import sys

cidr = os.environ.get("NETCALC_LAN_CIDR", "").strip()
if not cidr:
    print("LAN CIDR must be provided", file=sys.stderr)
    sys.exit(64)
try:
    network = ipaddress.ip_network(cidr, strict=False)
except ValueError as exc:
    print(f"Invalid LAN CIDR '{cidr}': {exc}", file=sys.stderr)
    sys.exit(64)
if network.version != 4:
    print(f"LAN CIDR '{cidr}' must be IPv4", file=sys.stderr)
    sys.exit(64)

start_raw = os.environ.get("NETCALC_START", "").strip()
end_raw = os.environ.get("NETCALC_END", "").strip()
addr_raw = os.environ.get("NETCALC_LAN_ADDR", "").strip()
check_availability = os.environ.get("NETCALC_CHECK_AVAILABILITY", "1").lower() not in {"0", "false", "no"}

def parse_ipv4(value):
    if not value:
        return None
    try:
        ip = ipaddress.ip_address(value)
    except ValueError:
        return None
    if ip.version != 4:
        return None
    return ip

def is_reserved(ip):
    if ip is None:
        return False
    if network.prefixlen <= 30:
        return ip == network.network_address or ip == network.broadcast_address
    return False

start_ip = parse_ipv4(start_raw)
end_ip = parse_ipv4(end_raw)

if not start_raw and not end_raw:
    reason = "missing_both"
elif not start_raw:
    reason = "missing_start"
elif not end_raw:
    reason = "missing_end"
elif start_ip is None:
    reason = "invalid_start"
elif end_ip is None:
    reason = "invalid_end"
elif start_ip not in network or end_ip not in network:
    reason = "outside_cidr"
elif is_reserved(start_ip):
    reason = "start_reserved"
elif is_reserved(end_ip):
    reason = "end_reserved"
elif end_ip < start_ip:
    reason = "reversed"
else:
    reason = "valid"

if reason == "valid":
    print(f"METALLB_POOL_START={start_ip}")
    print(f"METALLB_POOL_END={end_ip}")
    print(f"LABZ_METALLB_RANGE={start_ip}-{end_ip}")
    print("NETCALC_SOURCE=provided")
    print("NETCALC_REASON=valid")
    print("NETCALC_FALLBACK=0")
    print("NETCALC_CONFLICTS=")
    print("NETCALC_WARNINGS=")
    print(f"NETCALC_ORIGINAL_START={start_raw}")
    print(f"NETCALC_ORIGINAL_END={end_raw}")
    sys.exit(0)

def first_host(net):
    if net.prefixlen == 32:
        return net.network_address
    if net.prefixlen == 31:
        return net.network_address
    return net.network_address + 1

def last_host(net):
    if net.prefixlen == 32:
        return net.broadcast_address
    if net.prefixlen == 31:
        return net.broadcast_address
    return net.broadcast_address - 1

first = first_host(network)
last = last_host(network)
if first is None or last is None or int(last) < int(first):
    print(f"LAN CIDR '{cidr}' does not provide usable host addresses", file=sys.stderr)
    sys.exit(65)

candidates = []

if addr_raw:
    try:
        addr_ip = ipaddress.ip_address(addr_raw)
    except ValueError:
        addr_ip = None
    else:
        if addr_ip.version == 4:
            base24 = ipaddress.ip_network(f"{addr_ip}/24", strict=False)
            preferred = []
            for suffix in range(240, 251):
                candidate = base24.network_address + suffix
                if candidate in network and not is_reserved(candidate):
                    preferred.append(candidate)
            if len(preferred) == 11 and preferred[-1] in network:
                candidates.append((preferred[0], preferred[-1]))

try:
    subnets = list(network.subnets(new_prefix=29))
except ValueError:
    subnets = []
for subnet in reversed(subnets):
    hosts = [ip for ip in subnet.hosts() if not is_reserved(ip)]
    if not hosts:
        continue
    start_candidate = hosts[0]
    end_candidate = hosts[-1]
    if int(end_candidate) >= int(start_candidate):
        candidates.append((start_candidate, end_candidate))

candidates.append((first, last))
unique = []
seen = set()
for start_candidate, end_candidate in candidates:
    key = (int(start_candidate), int(end_candidate))
    if key in seen:
        continue
    seen.add(key)
    if int(end_candidate) < int(start_candidate):
        continue
    unique.append((start_candidate, end_candidate))

candidates = unique
if not candidates:
    print(f"Unable to derive MetalLB candidates inside '{cidr}'", file=sys.stderr)
    sys.exit(65)

warnings = set()
if check_availability:
    ping_cmd = shutil.which("ping")
    ip_cmd = shutil.which("ip")
    if ping_cmd is None:
        warnings.add("missing_ping")
    if ip_cmd is None:
        warnings.add("missing_ip")
else:
    ping_cmd = None
    ip_cmd = None

availability_checked = False

def ping_host(ip_str):
    global availability_checked
    if ping_cmd is None:
        return False
    try:
        result = subprocess.run(
            [ping_cmd, "-c", "1", "-W", "1", ip_str],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except Exception:
        warnings.add("ping_exec_error")
        availability_checked = True
        return False
    availability_checked = True
    return result.returncode == 0

def neigh_host(ip_str):
    global availability_checked
    if ip_cmd is None:
        return False
    try:
        result = subprocess.run(
            [ip_cmd, "neigh", "show", "to", ip_str],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except Exception:
        warnings.add("ip_cmd_failed")
        availability_checked = True
        return False
    availability_checked = True
    return ip_str in result.stdout

def range_available(start_ip, end_ip):
    if not check_availability:
        return True
    current = int(start_ip)
    end_int = int(end_ip)
    while current <= end_int:
        ip_str = str(ipaddress.IPv4Address(current))
        if ping_host(ip_str):
            return False
        if neigh_host(ip_str):
            return False
        current += 1
    return True

conflicts = []
selected = None
for start_candidate, end_candidate in candidates:
    if range_available(start_candidate, end_candidate):
        selected = (start_candidate, end_candidate)
        break
    conflicts.append((start_candidate, end_candidate))

fallback = False
if selected is None:
    selected = candidates[0]
    fallback = True

if check_availability and not availability_checked:
    warnings.add("no_availability_checks")

selected_start, selected_end = selected

conflict_str = "".join([])
if conflicts:
    conflict_str = ";".join(f"{start}-{end}" for start, end in conflicts)

warning_str = "".join([])
if warnings:
    warning_str = ",".join(sorted(warnings))

print(f"METALLB_POOL_START={selected_start}")
print(f"METALLB_POOL_END={selected_end}")
print(f"LABZ_METALLB_RANGE={selected_start}-{selected_end}")
print("NETCALC_SOURCE=calculated")
print(f"NETCALC_REASON={reason}")
print(f"NETCALC_FALLBACK={1 if fallback else 0}")
print(f"NETCALC_CONFLICTS={conflict_str}")
print(f"NETCALC_WARNINGS={warning_str}")
print(f"NETCALC_ORIGINAL_START={start_raw}")
print(f"NETCALC_ORIGINAL_END={end_raw}")
PY
)
calc_status=$?
if [[ ${calc_status} -ne 0 ]]; then
  die ${calc_status} "Failed to evaluate MetalLB pool for ${LAN_CIDR}"
fi

METALLB_POOL_START=""
METALLB_POOL_END=""
LABZ_METALLB_RANGE=""
NETCALC_SOURCE="calculated"
NETCALC_REASON=""
NETCALC_FALLBACK=0
NETCALC_WARNINGS=""
NETCALC_CONFLICTS=""
NETCALC_ORIGINAL_START=""
NETCALC_ORIGINAL_END=""

while IFS='=' read -r key value; do
  case "${key}" in
  METALLB_POOL_START) METALLB_POOL_START="${value}" ;;
  METALLB_POOL_END) METALLB_POOL_END="${value}" ;;
  LABZ_METALLB_RANGE) LABZ_METALLB_RANGE="${value}" ;;
  NETCALC_SOURCE) NETCALC_SOURCE="${value}" ;;
  NETCALC_REASON) NETCALC_REASON="${value}" ;;
  NETCALC_FALLBACK) NETCALC_FALLBACK="${value}" ;;
  NETCALC_WARNINGS) NETCALC_WARNINGS="${value}" ;;
  NETCALC_CONFLICTS) NETCALC_CONFLICTS="${value}" ;;
  NETCALC_ORIGINAL_START) NETCALC_ORIGINAL_START="${value}" ;;
  NETCALC_ORIGINAL_END) NETCALC_ORIGINAL_END="${value}" ;;
  "") ;;
  *) log_debug "Ignoring unknown output key ${key}" ;;
  esac
done <<<"${calc_output}"

if [[ -z ${METALLB_POOL_START} || -z ${METALLB_POOL_END} ]]; then
  die ${EX_SOFTWARE} "MetalLB calculation failed to return start/end addresses"
fi

if [[ -z ${LABZ_METALLB_RANGE} ]]; then
  LABZ_METALLB_RANGE="${METALLB_POOL_START}-${METALLB_POOL_END}"
fi

range_display="${METALLB_POOL_START}-${METALLB_POOL_END}"

if [[ ${NETCALC_SOURCE} == "provided" ]]; then
  log_info "MetalLB pool ${range_display} is valid within ${LAN_CIDR}"
else
  case "${NETCALC_REASON}" in
  missing_both)
    log_info "MetalLB pool undefined; selected ${range_display} within ${LAN_CIDR}"
    ;;
  missing_start)
    log_info "METALLB_POOL_START missing; selected ${range_display}"
    ;;
  missing_end)
    log_info "METALLB_POOL_END missing; selected ${range_display}"
    ;;
  invalid_start)
    log_warn "METALLB_POOL_START (${NETCALC_ORIGINAL_START}) is invalid; using ${range_display}"
    ;;
  invalid_end)
    log_warn "METALLB_POOL_END (${NETCALC_ORIGINAL_END}) is invalid; using ${range_display}"
    ;;
  outside_cidr)
    log_warn "Provided MetalLB pool ${NETCALC_ORIGINAL_START}-${NETCALC_ORIGINAL_END} is outside ${LAN_CIDR}; using ${range_display}"
    ;;
  start_reserved)
    log_warn "MetalLB start ${NETCALC_ORIGINAL_START} is reserved; using ${range_display}"
    ;;
  end_reserved)
    log_warn "MetalLB end ${NETCALC_ORIGINAL_END} is reserved; using ${range_display}"
    ;;
  reversed)
    log_warn "MetalLB pool start/end reversed; using ${range_display}"
    ;;
  *)
    log_info "Selected MetalLB pool ${range_display} within ${LAN_CIDR}"
    ;;
  esac
  if [[ ${NETCALC_FALLBACK} == "1" ]]; then
    log_warn "All MetalLB candidates were busy; falling back to ${range_display}"
  else
    log_debug "MetalLB pool derived from available candidate"
  fi
fi

if [[ -n ${NETCALC_CONFLICTS} ]]; then
  IFS=';' read -r -a _netcalc_conflicts <<<"${NETCALC_CONFLICTS}"
  for conflict in "${_netcalc_conflicts[@]}"; do
    [[ -z ${conflict} ]] && continue
    log_debug "Skipped MetalLB candidate ${conflict} due to detected activity"
  done
fi

if [[ -n ${NETCALC_WARNINGS} ]]; then
  IFS=',' read -r -a _netcalc_warnings <<<"${NETCALC_WARNINGS}"
  for warning in "${_netcalc_warnings[@]}"; do
    case "${warning}" in
    missing_ping)
      log_warn "ping command not found; availability checks may be incomplete"
      ;;
    missing_ip)
      log_warn "ip command not found; neighbor table checks skipped"
      ;;
    ping_exec_error)
      log_warn "ping command failed during pool evaluation"
      ;;
    ip_cmd_failed)
      log_warn "ip neigh command failed during pool evaluation"
      ;;
    no_availability_checks)
      log_warn "Unable to verify whether candidate pools are in use"
      ;;
    "") ;;
    *)
      log_warn "MetalLB pool warning: ${warning}"
      ;;
    esac
  done
fi

printf 'METALLB_POOL_START=%s\n' "${METALLB_POOL_START}"
printf 'METALLB_POOL_END=%s\n' "${METALLB_POOL_END}"
printf 'LABZ_METALLB_RANGE=%s\n' "${LABZ_METALLB_RANGE}"
printf 'NETCALC_SOURCE=%s\n' "${NETCALC_SOURCE}"
printf 'NETCALC_REASON=%s\n' "${NETCALC_REASON}"
printf 'NETCALC_FALLBACK=%s\n' "${NETCALC_FALLBACK}"
printf 'NETCALC_WARNINGS=%s\n' "${NETCALC_WARNINGS}"
printf 'NETCALC_CONFLICTS=%s\n' "${NETCALC_CONFLICTS}"
printf 'NETCALC_ORIGINAL_START=%s\n' "${NETCALC_ORIGINAL_START}"
printf 'NETCALC_ORIGINAL_END=%s\n' "${NETCALC_ORIGINAL_END}"
