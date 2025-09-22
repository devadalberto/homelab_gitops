#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

ENV_FILE=""
VM_NAME=""

usage() {
  cat <<'USAGE'
Usage: status.sh [options]

Summarise the homelab environment, pfSense artifacts, and libvirt wiring.

Options:
  -e, --env-file <path>   Load environment variables from the given file.
  -n, --vm-name <name>    Override the pfSense libvirt domain to inspect.
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
      -n|--vm-name)
        if [[ $# -lt 2 ]]; then
          usage >&2
          die ${EX_USAGE:-64} "--vm-name requires a value"
        fi
        VM_NAME="$2"
        shift 2
        ;;
      --vm-name=*)
        VM_NAME="${1#*=}"
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

run_and_capture() {
  local description=$1
  shift
  printf '  %s\n' "${description}"
  if [[ $# -eq 0 ]]; then
    printf '    (no command provided)\n'
    return
  fi

  local previous_opts
  previous_opts=$(set +o)
  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  eval "${previous_opts}"

  if [[ ${status} -eq 0 ]]; then
    if [[ -z ${output} ]]; then
      printf '    (no output)\n'
    else
      printf '%s\n' "${output}" | sed 's/^/    /'
    fi
  else
    printf '    command failed (exit code %d)\n' "${status}"
    if [[ -n ${output} ]]; then
      printf '%s\n' "${output}" | sed 's/^/      /'
    fi
  fi
}

list_config_artifacts() {
  local config_dir=$1
  print_heading "pfSense config artifacts"
  printf '  Directory: %s\n' "${config_dir}"

  if [[ -z ${config_dir} ]]; then
    printf '  (configuration directory not set)\n'
    return
  fi

  if [[ ! -d ${config_dir} ]]; then
    printf '  (directory not found)\n'
    return
  fi

  local -a entries=()
  while IFS= read -r -d '' entry; do
    entries+=("${entry}")
  done < <(find "${config_dir}" -maxdepth 1 -mindepth 1 -print0 2>/dev/null | sort -z)

  if (( ${#entries[@]} == 0 )); then
    printf '  (no artifacts present)\n'
    return
  fi

  local entry name type
  for entry in "${entries[@]}"; do
    name="${entry#"${config_dir}/"}"
    if [[ -h ${entry} ]]; then
      type="link"
    elif [[ -d ${entry} ]]; then
      type="dir"
    else
      type="file"
    fi
    printf '  %-6s %s\n' "${type}" "${name}"
  done
}

inspect_domain() {
  local domain=$1
  print_heading "libvirt domain overview"

  if [[ -z ${domain} ]]; then
    printf '  Domain: <unset>\n'
    printf '  Skipping virsh inspection because no domain name is available.\n'
    return
  fi

  printf '  Domain: %s\n' "${domain}"

  if ! command -v virsh >/dev/null 2>&1; then
    printf '  virsh command not available; skipping domblklist/domiflist.\n'
    return
  fi

  run_and_capture "virsh domblklist ${domain}" virsh domblklist "${domain}"
  run_and_capture "virsh domiflist ${domain}" virsh domiflist "${domain}"
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

main() {
  parse_args "$@"
  load_environment

  if [[ -z ${VM_NAME} && -n ${PF_VM_NAME:-} ]]; then
    VM_NAME=${PF_VM_NAME}
  fi
  if [[ -z ${VM_NAME} ]]; then
    VM_NAME="pfsense-uranus"
  fi

  print_heading "Homelab status summary"
  dump_effective_env --header "Environment configuration" PF_VM_NAME
  list_config_artifacts "${HOMELAB_PFSENSE_CONFIG_DIR}" 
  inspect_domain "${VM_NAME}"
}

main "$@"
