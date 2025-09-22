#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

ENV_FILE=""
CLEAN_REMOVED=false
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'USAGE'
Usage: clean.sh [options]

Remove generated pfSense configuration media and cached assets.

Options:
  -e, --env-file <path>   Load environment variables from the given file.
  -h, --help              Show this help message and exit.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--env-file)
        if [[ $# -lt 2 ]]; then
          usage >&2
          die ${EX_USAGE:-64} "--env-file requires a path argument"
        fi
        ENV_FILE="$2"
        shift 2
        ;;
      --env-file=*)
        ENV_FILE="${1#*=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die ${EX_USAGE:-64} "Unknown argument: $1"
        ;;
    esac
  done
}

print_heading() {
  local title=$1
  printf '\n%s\n' "${title}"
  printf '%s\n' "$(printf '%*s' "${#title}" '' | tr ' ' '-')"
}

load_environment() {
  local -a args=()
  if [[ -n ${ENV_FILE} ]]; then
    args+=("--env-file" "${ENV_FILE}")
  fi
  if ! load_env "${args[@]}"; then
    if [[ -n ${ENV_FILE} ]]; then
      warn "Environment file not found: ${ENV_FILE}"
    else
      warn "No environment file located; continuing with current shell values."
    fi
  fi
}

remove_matches() {
  local pattern=$1
  local -a matches=()
  while IFS= read -r match; do
    matches+=("${match}")
  done < <(compgen -G "${pattern}" 2>/dev/null || true)

  if (( ${#matches[@]} == 0 )); then
    return 1
  fi

  local match type
  for match in "${matches[@]}"; do
    if [[ -d ${match} && ! -L ${match} ]]; then
      type="directory"
    else
      type="file"
    fi
    printf '  Removing %s %s\n' "${type}" "${match}"
    rm -rf -- "${match}"
    CLEAN_REMOVED=true
  done

  return 0
}

clean_config_dir() {
  local dir=$1
  if [[ -z ${dir} ]]; then
    return
  fi
  dir="${dir%/}"
  printf '\nDirectory: %s\n' "${dir}"

  local -a patterns=(
    "${dir}/config.xml"
    "${dir}/pfSense-config.iso"
    "${dir}/pfSense-config-latest.iso"
    "${dir}/pfSense-config-*.iso"
    "${dir}/pfSense-ecl-usb.img"
    "${dir}/pfSense-ecl-usb-*.img"
    "${dir}/backups"
  )

  local removed_any=false
  local pattern
  for pattern in "${patterns[@]}"; do
    if remove_matches "${pattern}"; then
      removed_any=true
    fi
  done

  if [[ ${removed_any} == false ]]; then
    if [[ -e ${dir} ]]; then
      printf '  (no matching artifacts found)\n'
    else
      printf '  (path does not exist)\n'
    fi
  fi
}

main() {
  parse_args "$@"
  load_environment

  local -a target_dirs=("${HOMELAB_PFSENSE_CONFIG_DIR}")
  if [[ -n ${WORK_ROOT:-} ]]; then
    target_dirs+=("${WORK_ROOT%/}/pfsense/config")
  fi

  homelab_maybe_reexec_for_privileged_paths HOMELAB_CLEAN_ESCALATED "${target_dirs[@]}"

  print_heading "pfSense artifact cleanup"

  declare -A seen_dirs=()
  local dir
  for dir in "${target_dirs[@]}"; do
    [[ -z ${dir} ]] && continue
    dir="${dir%/}"
    if [[ -z ${dir} || -n ${seen_dirs[${dir}]:-} ]]; then
      continue
    fi
    seen_dirs["${dir}"]=1
    clean_config_dir "${dir}"
  done

  if [[ ${CLEAN_REMOVED} == false ]]; then
    printf '\nNothing to remove. pfSense artifacts already absent.\n'
  else
    printf '\npfSense artifacts removed successfully.\n'
  fi
}

main "$@"
