#!/usr/bin/env bash
set -euo pipefail

readonly EX_USAGE=64
readonly EX_SOFTWARE=70

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/common-env.sh
source "${SCRIPT_DIR}/common-env.sh"

print_heading() {
  local title=$1
  printf '\n%s\n' "${title}"
  printf '%s\n' "$(printf '%*s' "${#title}" '' | tr ' ' '-')"
}

print_status() {
  local code=$1
  local label=$2
  local detail=${3:-}
  if [[ -n ${detail} ]]; then
    printf '  [%-4s] %-24s %s\n' "${code}" "${label}" "${detail}"
  else
    printf '  [%-4s] %s\n' "${code}" "${label}"
  fi
}

usage() {
  cat <<'USAGE'
Usage: doctor.sh [options]

Options:
  --env-file PATH  Load environment variables from PATH before running checks.
  -h, --help       Show this help message and exit.
USAGE
}

ENV_FILE=""
ACTIVE_ENV_FILE=""

declare -a REQUIRED_CMDS=(
  bash
  curl
  git
  gzip
  jq
  make
  python3
  tar
)

declare -A OPTIONAL_GROUPS=(
  [virtualization]="virsh virt-install virt-viewer qemu-img"
  [kubernetes]="kubectl helm minikube"
  [secrets]="sops age"
)

declare -a missing_required=()

die() {
  printf '%s\n' "$*" >&2
  exit ${EX_USAGE}
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage
        die "--env-file requires a path"
      fi
      ENV_FILE=$2
      shift 2
      ;;
    --env-file=*)
      ENV_FILE="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown argument: $1"
      ;;
    esac
  done
}

doctor_require_cmd() {
  local cmd=$1
  if command -v "${cmd}" >/dev/null 2>&1; then
    print_status OK "${cmd}" "$(command -v "${cmd}")"
    return 0
  fi
  print_status FAIL "${cmd}" "not found"
  missing_required+=("${cmd}")
  return 1
}

check_required_commands() {
  print_heading "Required tooling"
  local cmd
  for cmd in "${REQUIRED_CMDS[@]}"; do
    doctor_require_cmd "${cmd}"
  done
}

check_optional_groups() {
  local group
  for group in "${!OPTIONAL_GROUPS[@]}"; do
    print_heading "${group^} tooling"
    local -a found=()
    local -a missing=()
    local cmd
    # shellcheck disable=SC2206
    local cmds=( ${OPTIONAL_GROUPS[${group}]} )
    for cmd in "${cmds[@]}"; do
      if command -v "${cmd}" >/dev/null 2>&1; then
        found+=("${cmd}")
      else
        missing+=("${cmd}")
      fi
    done
    if (( ${#missing[@]} == 0 )); then
      print_status OK "${group}" "${found[*]}"
    elif (( ${#found[@]} == 0 )); then
      print_status WARN "${group}" "missing: ${missing[*]}"
    else
      print_status WARN "${group}" "have: ${found[*]} / missing: ${missing[*]}"
    fi
  done
}

ENV_VARS_TO_REPORT=(
  ENV_FILE
  LABZ_DOMAIN
  LABZ_TRAEFIK_HOST
  LABZ_NEXTCLOUD_HOST
  LABZ_JELLYFIN_HOST
  LABZ_MINIKUBE_PROFILE
  LABZ_MINIKUBE_DRIVER
  LABZ_MINIKUBE_CPUS
  LABZ_MINIKUBE_MEMORY
  PF_WAN_BRIDGE
  PF_LAN_BRIDGE
  PF_SERIAL_INSTALLER_PATH
  PF_INSTALLER_SRC
  PF_INSTALLER_DEST
  LABZ_METALLB_RANGE
  METALLB_POOL_START
  METALLB_POOL_END
  TRAEFIK_LOCAL_IP
  WORK_ROOT
  PG_BACKUP_HOSTPATH
)

dump_effective_env() {
  print_heading "Effective environment"
  if [[ -n ${ACTIVE_ENV_FILE} ]]; then
    printf '  %-24s %s\n' "Environment file" "${ACTIVE_ENV_FILE}"
  else
    printf '  %-24s %s\n' "Environment file" "(none)"
  fi

  local var
  for var in "${ENV_VARS_TO_REPORT[@]}"; do
    local value="<unset>"
    if [[ -n ${!var-} ]]; then
      value=${!var}
    fi
    printf '  %-24s %s\n' "${var}" "${value}"
  done
}

ISO_TOOL=""

detect_iso_tool() {
  local -a iso_candidates=(
    "xorriso -as mkisofs"
    "xorrisofs"
    "genisoimage"
    "mkisofs"
  )
  local candidate
  for candidate in "${iso_candidates[@]}"; do
    local binary=${candidate%% *}
    if command -v "${binary}" >/dev/null 2>&1; then
      ISO_TOOL="${candidate}"
      return 0
    fi
  done
  return 1
}

check_iso_tool() {
  print_heading "ISO tooling"
  if detect_iso_tool; then
    print_status OK "ISO tool" "${ISO_TOOL}"
  else
    print_status FAIL "ISO tool" "install xorriso, genisoimage, or mkisofs"
    missing_required+=("iso_tool")
  fi
}

load_environment() {
  local -a args=()

  if [[ -n ${ENV_FILE} ]]; then
    if [[ ! -f ${ENV_FILE} ]]; then
      printf 'homelab doctor: env file not found: %s\n' "${ENV_FILE}" >&2
      exit ${EX_USAGE}
    fi
    args+=(--env-file "${ENV_FILE}")
  else
    args+=(--silent)
  fi

  if ! load_env "${args[@]}"; then
    if [[ -n ${ENV_FILE} ]]; then
      printf 'homelab doctor: failed to load env file: %s\n' "${ENV_FILE}" >&2
      exit ${EX_USAGE}
    fi
  fi

  ACTIVE_ENV_FILE="${HOMELAB_ENV_FILE:-}"
}

main() {
  parse_args "$@"
  load_environment
  dump_effective_env
  check_required_commands
  check_iso_tool
  check_optional_groups

  if (( ${#missing_required[@]} > 0 )); then
    printf '\nDoctor detected issues with required tooling: %s\n' "${missing_required[*]}"
    exit 1
  fi

  printf '\nDoctor OK\n'
}

main "$@"
