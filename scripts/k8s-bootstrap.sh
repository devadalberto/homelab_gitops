#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/k8s-up.sh" "$@"

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

ENV_FILE=""
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'USAGE'
Usage: k8s-bootstrap.sh [options]

Placeholder for the Kubernetes bootstrap workflow.

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

main() {
  parse_args "$@"
  load_environment

  print_heading "Kubernetes bootstrap"
  printf 'Repository root: %s\n' "${REPO_ROOT}"
  printf 'This script currently provides placeholder logging only.\n'
  printf 'Add cluster provisioning steps here when ready.\n'

  info "Kubernetes bootstrap stub invoked."
  info "Environment file: ${HOMELAB_ENV_FILE:-<none>}"
  info "Repository root: ${REPO_ROOT}"
}

main "$@"
