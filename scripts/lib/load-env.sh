#!/usr/bin/env bash
set -euo pipefail

load_env() {
  if [[ $# -ne 1 ]]; then
    printf 'Usage: load_env <env-file>\n' >&2
    return 64
  fi

  local env_file="$1"
  if [[ ! -f ${env_file} ]]; then
    printf 'Environment file not found: %s\n' "${env_file}" >&2
    return 1
  fi

  printf '[INFO] Using .env: %s\n' "${env_file}"

  local previous_opts
  previous_opts=$(set +o)
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  eval "${previous_opts}"
}
