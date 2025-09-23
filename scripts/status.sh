#!/usr/bin/env bash
set -euo pipefail

ENV_FILE_OVERRIDE=""
if [[ "${1:-}" == "--env-file" ]]; then
  ENV_FILE_OVERRIDE="${2:-./.env}"
  shift 2
fi

if [[ $# -gt 0 ]]; then
  printf 'Usage: %s [--env-file PATH]\n' "${0##*/}" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

declare -a env_args=()
if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
  if [[ -f ${ENV_FILE_OVERRIDE} ]]; then
    env_args=("--env-file" "${ENV_FILE_OVERRIDE}")
  else
    printf '[WARN] Environment file not found: %s\n' "${ENV_FILE_OVERRIDE}" >&2
  fi
fi

preflight_cmd=("${REPO_ROOT}/scripts/preflight_and_bootstrap.sh")
apps_cmd=("${REPO_ROOT}/scripts/uranus_homelab_apps.sh")
if (( ${#env_args[@]} > 0 )); then
  preflight_cmd+=("${env_args[@]}")
  apps_cmd+=("${env_args[@]}")
fi
preflight_cmd+=("--context-preflight")
apps_cmd+=("--context-preflight")

printf '=== Host and MetalLB context ===\n'
"${preflight_cmd[@]}"

printf '\n=== Application context ===\n'
"${apps_cmd[@]}"
