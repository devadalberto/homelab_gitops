#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${REPO_ROOT}/scripts/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
else
  FALLBACK_LIB="${REPO_ROOT}/scripts/lib/common_fallback.sh"
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
# shellcheck disable=SC2034
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78
# shellcheck disable=SC2034
readonly EX_NOTREADY=4

# shellcheck disable=SC2034
ORIGINAL_ARGS=("$@")

DRY_RUN=false
ENV_FILE=""
OUTPUT_DIR_OVERRIDE=""
TEMPLATE_OVERRIDE=""

WORK_ROOT_DEFAULT="/opt/homelab"
ISO_LABEL="pfSense_config"

usage() {
  cat <<'USAGE'
Usage: pf-config-gen.sh [OPTIONS]

Generate the pfSense configuration ISO from templates and environment values.

Options:
  --env-file PATH        Load environment overrides from PATH.
  --output-dir PATH      Write rendered assets under PATH instead of ${WORK_ROOT}/pfsense/config.
  --template PATH        Render PATH instead of the default config.xml template.
  --dry-run              Log the actions without writing files or creating the ISO.
  -h, --help             Show this help message.

Exit codes:
  0  Success.
  4  Environment not ready for ISO regeneration (e.g., missing prerequisites).
  64 Usage error (invalid CLI arguments).
  69 Missing required dependencies (install xorriso/genisoimage/mkisofs, gzip, virt-install).
  70 Internal failure while rendering the template or packaging the ISO.
  78 Missing configuration (environment variables or templates).
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--env-file requires a path argument"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --output-dir)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--output-dir requires a path argument"
        fi
        OUTPUT_DIR_OVERRIDE="$2"
        shift 2
        ;;
      --template)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--template requires a path argument"
        fi
        TEMPLATE_OVERRIDE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit ${EX_OK}
        ;;
      --)
        shift
        break
        ;;
      -* )
        usage
        die ${EX_USAGE} "Unknown option: $1"
        ;;
      * )
        usage
        die ${EX_USAGE} "Unexpected positional argument: $1"
        ;;
    esac
  done
}

cleanup_temp_dir() {
  local dir=$1
  if [[ -z ${dir} ]]; then
    return
  fi
  if [[ -d ${dir} ]]; then
    rm -rf -- "${dir:?}"
  fi
}

load_environment() {
  local candidates=()
  if [[ -n ${ENV_FILE} ]]; then
    candidates=("${ENV_FILE}")
  else
    candidates=(
      "${REPO_ROOT}/.env"
      "${REPO_ROOT}/.env.example"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load environment from ${candidate}"
      return
    fi
  done

  log_warn "No environment file found; relying on existing shell variables."
}

check_dependencies() {
  local missing=()
  local -a iso_found=()
  local candidate

  for candidate in genisoimage mkisofs xorrisofs xorriso; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      iso_found+=("${candidate}")
    fi
  done

  if (( ${#iso_found[@]} == 0 )); then
    missing+=("genisoimage|mkisofs|xorrisofs|xorriso")
  else
    log_debug "Available ISO creation tools: ${iso_found[*]}"
  fi

  if ! need gzip &>/dev/null; then
    missing+=(gzip)
  fi

  if ! need virt-install &>/dev/null; then
    missing+=(virt-install)
  fi

  if (( ${#missing[@]} > 0 )); then
    log_error "Missing required dependencies: ${missing[*]}"
    log_info "Install them via: sudo apt-get install xorriso genisoimage mkisofs gzip virt-install"
    die 3
  fi
}

ensure_required_env() {
  local required=(
    LAB_DOMAIN_BASE
    LAB_CLUSTER_SUB
    LAN_PREFIX_LEN
    CIDR_BITS
    LAN_GW_IP
    LAN_DHCP_FROM
    LAN_DHCP_TO
    DHCP_FROM
    DHCP_TO
    METALLB_POOL_START
    TRAEFIK_LOCAL_IP
  )
  local missing=()
  local var
  for var in "${required[@]}"; do
    if [[ -z ${!var:-} ]]; then
      missing+=("${var}")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    die ${EX_CONFIG} "Missing required environment variables: ${missing[*]}"
  fi
}

generate_virtual_ips() {
  if [[ -z ${METALLB_POOL_START:-} ]]; then
    die ${EX_CONFIG} "METALLB_POOL_START must be defined to derive VIP addresses"
  fi

  local python_output
  python_output=$(python3 - "$METALLB_POOL_START" <<'PY'
import ipaddress
import sys

start = ipaddress.ip_address(sys.argv[1])
vip = {
    "VIP_APP": str(start),
    "VIP_GRAFANA": str(start + 1),
    "VIP_PROM": str(start + 2),
    "VIP_ALERT": str(start + 3),
    "VIP_AWX": str(start + 4),
}
for key, value in vip.items():
    print(f"{key}={value}")
PY
  )

  if [[ -z ${python_output} ]]; then
    die ${EX_SOFTWARE} "Failed to calculate virtual IP assignments"
  fi

  eval "${python_output}"
}

derive_lan_network_settings() {
  local python_output

  if ! python_output=$(python3 <<'PY'
import ipaddress
import os
import sys

lan_cidr = os.environ.get("LAN_CIDR", "10.10.0.0/24")
gw_ip_raw = os.environ.get("LAN_GW_IP", "10.10.0.1").strip()
dhcp_from_raw = os.environ.get("DHCP_FROM") or os.environ.get("LAN_DHCP_FROM", "")
dhcp_to_raw = os.environ.get("DHCP_TO") or os.environ.get("LAN_DHCP_TO", "")

try:
    network = ipaddress.ip_network(lan_cidr, strict=False)
except ValueError as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)

if network.version != 4:
    print("LAN_CIDR must be IPv4", file=sys.stderr)
    sys.exit(1)

hosts = list(network.hosts())
if not hosts:
    print(f"LAN_CIDR {network.with_prefixlen} does not provide usable host addresses", file=sys.stderr)
    sys.exit(1)

def parse_host(label, value, allow_empty=False):
    if not value:
        if allow_empty:
            return None
        print(f"{label} is required", file=sys.stderr)
        sys.exit(1)
    try:
        candidate = ipaddress.ip_address(value)
    except ValueError as exc:
        print(f"{label} invalid: {exc}", file=sys.stderr)
        sys.exit(1)
    if candidate.version != 4:
        print(f"{label} must be IPv4", file=sys.stderr)
        sys.exit(1)
    if candidate not in network:
        print(f"{label}={value} is not contained within {network.with_prefixlen}", file=sys.stderr)
        sys.exit(1)
    if candidate == network.network_address or candidate == network.broadcast_address:
        print(f"{label}={value} cannot equal the network or broadcast address", file=sys.stderr)
        sys.exit(1)
    return candidate

gateway = parse_host("LAN_GW_IP", gw_ip_raw)

def default_range_start():
    candidate = network.network_address + 99
    if candidate <= network.network_address:
        candidate = hosts[0]
    if candidate >= network.broadcast_address:
        candidate = hosts[-1]
    return candidate

def default_range_end():
    candidate = network.network_address + 199
    if candidate <= network.network_address:
        candidate = hosts[0]
    if candidate >= network.broadcast_address:
        candidate = hosts[-1]
    return candidate

dhcp_from = parse_host("DHCP_FROM", dhcp_from_raw, allow_empty=True)
dhcp_to = parse_host("DHCP_TO", dhcp_to_raw, allow_empty=True)

if dhcp_from is None:
    dhcp_from = default_range_start()
if dhcp_to is None:
    dhcp_to = default_range_end()

if dhcp_from > dhcp_to:
    print(f"DHCP_FROM ({dhcp_from}) cannot exceed DHCP_TO ({dhcp_to})", file=sys.stderr)
    sys.exit(1)

def emit(name, value):
    value_str = str(value)
    escaped = value_str.replace("'", "'\"'\"'")
    print(f"export {name}='{escaped}'")

emit("LAN_CIDR", network.with_prefixlen)
emit("LAN_NETWORK", network.network_address)
emit("LAN_PREFIX_LEN", network.prefixlen)
emit("CIDR_BITS", network.prefixlen)
emit("LAN_GW_IP", gateway)
emit("LAN_DHCP_FROM", dhcp_from)
emit("LAN_DHCP_TO", dhcp_to)
emit("DHCP_FROM", dhcp_from)
emit("DHCP_TO", dhcp_to)
emit("LAN_NETMASK", network.netmask)
PY
  ); then
    die ${EX_CONFIG} "Failed to derive LAN network settings from ${LAN_CIDR:-10.10.0.0/24}"
  fi

  eval "${python_output}"

  log_debug "Derived LAN network=${LAN_NETWORK}/${LAN_PREFIX_LEN} gateway=${LAN_GW_IP} DHCP=${DHCP_FROM}-${DHCP_TO}"
}

render_config_template() {
  local output_path=$1
  local template_path=$2

  if [[ ! -f ${template_path} ]]; then
    die ${EX_CONFIG} "Template not found: ${template_path}"
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would render pfSense config to ${output_path}"
    return
  fi

  local tmp_file
  tmp_file=$(mktemp "${output_path}.XXXXXX")

  python3 - "${template_path}" "${tmp_file}" <<'PY'
import os
import sys

tpl_path, out_path = sys.argv[1], sys.argv[2]
with open(tpl_path, "r", encoding="utf-8") as fp:
    tpl = fp.read()

env = os.environ
for key in [
    "LAB_DOMAIN_BASE",
    "LAB_CLUSTER_SUB",
    "LAN_PREFIX_LEN",
    "CIDR_BITS",
    "LAN_GW_IP",
    "LAN_DHCP_FROM",
    "LAN_DHCP_TO",
    "DHCP_FROM",
    "DHCP_TO",
    "METALLB_POOL_START",
    "TRAEFIK_LOCAL_IP",
    "VIP_GRAFANA",
    "VIP_PROM",
    "VIP_ALERT",
    "VIP_AWX",
]:
    tpl = tpl.replace("{{ " + key + " }}", env.get(key, ""))

with open(out_path, "w", encoding="utf-8") as fp:
    fp.write(tpl)
PY

  run_cmd mv "${tmp_file}" "${output_path}"
  run_cmd chown root:root "${output_path}"
  run_cmd chmod 0644 "${output_path}"
}

prepare_iso_root() {
  local config_path=$1
  local staging_dir

  staging_dir=$(mktemp -d)
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would stage ISO contents in ${staging_dir}"
    rmdir "${staging_dir}"
    printf '%s\n' ""
    return
  fi

  mkdir -p "${staging_dir}/conf"
  run_cmd cp "${config_path}" "${staging_dir}/config.xml"
  run_cmd cp "${config_path}" "${staging_dir}/conf/config.xml"
  printf '%s\n' "${staging_dir}"
}

mkiso() {
  local src_dir=$1
  local output_path=$2
  local -a candidates=(
    "genisoimage"
    "mkisofs"
    "xorrisofs"
    "xorriso -as mkisofs"
  )
  local candidate
  local -a cmd=()
  local attempted=0
  local status=1

  for candidate in "${candidates[@]}"; do
    IFS=' ' read -r -a cmd <<<"${candidate}"
    if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
      log_debug "ISO helper ${candidate} not available"
      continue
    fi

    attempted=1
    if run_cmd "${cmd[@]}" -quiet -V "${ISO_LABEL}" -o "${output_path}" -J -r "${src_dir}"; then
      log_debug "ISO creation succeeded with ${candidate}"
      return 0
    fi

    status=$?
    log_warn "ISO creation via ${candidate} failed with exit ${status}"
  done

  if (( attempted == 0 )); then
    log_error "None of the ISO creation tools (genisoimage, mkisofs, xorrisofs, xorriso) are available"
    return ${EX_UNAVAILABLE}
  fi

  log_error "All available ISO creation tools failed to build the ISO"
  return ${status}
}

refresh_iso_links() {
  local iso_dir=$1
  local iso_dir_abs=$2
  local iso_name=$3
  local iso_path_abs=$4

  local latest_link="${iso_dir}/pfSense-config-latest.iso"
  local legacy_link="${iso_dir}/pfSense-config.iso"
  run_cmd ln -sfn "${iso_name}" "${latest_link}"
  run_cmd ln -sfn "${iso_name}" "${legacy_link}"

  local canonical_dir="${WORK_ROOT_DEFAULT}/pfsense/config"
  local canonical_target="${iso_path_abs}"

  if [[ ${iso_dir_abs} == "${canonical_dir}" ]]; then
    canonical_target="${iso_name}"
  else
    run_cmd mkdir -p "${canonical_dir}"
  fi

  run_cmd ln -sfn "${canonical_target}" "${canonical_dir}/pfSense-config-latest.iso"
  run_cmd ln -sfn "${canonical_target}" "${canonical_dir}/pfSense-config.iso"
}

package_iso() {
  local staging_dir=$1
  local iso_dir=$2
  local timestamp=$3
  local iso_name="pfSense-config-${timestamp}.iso"
  local iso_path="${iso_dir}/${iso_name}"
  local iso_dir_abs=""
  local iso_path_abs=""
  local tmp_iso

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would package ISO at ${iso_path}"
    return
  fi

  if ! iso_dir_abs=$(cd -- "${iso_dir}" && pwd); then
    die ${EX_SOFTWARE} "Unable to resolve absolute path for ${iso_dir}"
  fi
  iso_path_abs="${iso_dir_abs}/${iso_name}"

  tmp_iso=$(mktemp "${iso_path}.XXXXXX")
  local mkiso_status=0
  if ! mkiso "${staging_dir}" "${tmp_iso}"; then
    mkiso_status=$?
    rm -f -- "${tmp_iso}"
    die ${mkiso_status} "Failed to create ISO image"
  fi

  if [[ ! -s ${tmp_iso} ]]; then
    rm -f -- "${tmp_iso}"
    die ${EX_SOFTWARE} "Generated ISO ${tmp_iso} is empty"
  fi

  run_cmd mv "${tmp_iso}" "${iso_path}"

  refresh_iso_links "${iso_dir}" "${iso_dir_abs}" "${iso_name}" "${iso_path_abs}"

  log_info "Packaged pfSense config ISO at ${iso_path}"
}

main() {
  parse_args "$@"
  load_environment

  : "${WORK_ROOT:=${WORK_ROOT_DEFAULT}}"
  derive_lan_network_settings
  local output_dir
  if [[ -n ${OUTPUT_DIR_OVERRIDE} ]]; then
    output_dir="${OUTPUT_DIR_OVERRIDE}"
  else
    output_dir="${WORK_ROOT}/pfsense/config"
  fi

  local template_path
  if [[ -n ${TEMPLATE_OVERRIDE} ]]; then
    template_path="${TEMPLATE_OVERRIDE}"
  else
    template_path="${SCRIPT_DIR}/templates/config.xml.j2"
  fi

  homelab_maybe_reexec_for_privileged_paths PF_CONFIG_GEN_SUDO_GUARD "${output_dir}" "${WORK_ROOT}"

  check_dependencies
  ensure_required_env
  generate_virtual_ips

  if [[ ${DRY_RUN} == false ]]; then
    run_cmd mkdir -p "${output_dir}"
  else
    log_info "[DRY-RUN] Would ensure ${output_dir} exists"
  fi

  local config_path="${output_dir}/config.xml"
  render_config_template "${config_path}" "${template_path}"
  log_info "Rendered pfSense config at ${config_path}"

  local staging_dir=""
  if [[ ${DRY_RUN} == false ]]; then
    staging_dir=$(prepare_iso_root "${config_path}")
    trap 'cleanup_temp_dir "${staging_dir}"' EXIT
  else
    prepare_iso_root "${config_path}" >/dev/null
  fi

  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  package_iso "${staging_dir}" "${output_dir}" "${timestamp}"

  if [[ ${DRY_RUN} == false ]]; then
    cleanup_temp_dir "${staging_dir}"
    staging_dir=""
    trap - EXIT
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "Dry-run complete. No files were modified."
  fi
}

main "$@"
