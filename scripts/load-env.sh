#!/usr/bin/env bash
set -euo pipefail

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "scripts/load-env.sh is a helper library and must be sourced." >&2
  exit 64
fi

if [[ -n ${_HOMELAB_LOAD_ENV_SH_SOURCED:-} ]]; then
  return 0
fi
readonly _HOMELAB_LOAD_ENV_SH_SOURCED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
elif [[ -f "${SCRIPT_DIR}/lib/common_fallback.sh" ]]; then
  # shellcheck source=scripts/lib/common_fallback.sh
  source "${SCRIPT_DIR}/lib/common_fallback.sh"
else
  echo "Unable to locate scripts/lib/common.sh or fallback helpers" >&2
  return 70
fi

HOMELAB_ENV_FILE=""

homelab_load_env() {
  local override=${1:-${ENV_FILE:-}}
  local -a candidates=()
  if [[ -n ${override} ]]; then
    candidates=("${override}")
  else
    candidates=(
      "${REPO_ROOT}/.env"
      "${REPO_ROOT}/.env.example"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f ${candidate} ]]; then
      log_debug "Loading environment from ${candidate}"
      load_env "${candidate}" || die 78 "Failed to load environment from ${candidate}"
      HOMELAB_ENV_FILE="${candidate}"
      export HOMELAB_ENV_FILE
      return 0
    fi
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    die 78 "Environment file is required"
  fi

  local joined=""
  local item
  for item in "${candidates[@]}"; do
    if [[ -z ${joined} ]]; then
      joined="${item}"
    else
      joined+="; ${item}"
    fi
  done
  die 78 "Unable to locate environment file (checked: ${joined})"
}
