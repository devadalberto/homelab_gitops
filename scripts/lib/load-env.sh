#!/usr/bin/env bash
# shellcheck shell=bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  echo "scripts/lib/load-env.sh is a helper library and must be sourced, not executed." >&2
  exit 64
fi

if [[ -n ${_HOMELAB_LOAD_ENV_SH_SOURCED:-} ]]; then
  return 0
fi
readonly _HOMELAB_LOAD_ENV_SH_SOURCED=1

_homelab_env_log() {
  local level=$1
  shift || true
  local func="log_${level}"
  if declare -F "${func}" >/dev/null 2>&1; then
    "${func}" "$@"
    return
  fi
  case "${level}" in
  error)
    printf '[ERROR] %s\n' "$*" >&2
    ;;
  warn)
    printf '[WARN] %s\n' "$*" >&2
    ;;
  info)
    printf '[INFO] %s\n' "$*" >&2
    ;;
  debug)
    if [[ ${HOMELAB_ENV_LOG_DEBUG:-false} == true ]]; then
      printf '[DEBUG] %s\n' "$*" >&2
    fi
    ;;
  *)
    printf '%s\n' "$*" >&2
    ;;
  esac
}

_homelab_env_source_file() {
  if [[ $# -ne 1 ]]; then
    _homelab_env_log error "Usage: _homelab_env_source_file <env-file>"
    return 64
  fi

  local env_file=$1
  if [[ ! -f ${env_file} ]]; then
    _homelab_env_log error "Environment file not found: ${env_file}"
    return 78
  fi

  local previous_opts
  previous_opts=$(set +o)
  set +u
  set -a
  # shellcheck disable=SC1090
  source "${env_file}"
  eval "${previous_opts}"
}

load_env() {
  HOMELAB_ENV_FILE=""
  HOMELAB_ENV_FILE_EXPLICIT=false

  local env_file_arg=""
  local explicit=false
  local -a remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -e | --env-file)
      if [[ $# -lt 2 ]]; then
        _homelab_env_log error "--env-file requires a path argument"
        return 64
      fi
      env_file_arg="$2"
      explicit=true
      shift 2
      continue
      ;;
    --env-file=*)
      env_file_arg="${1#*=}"
      explicit=true
      shift
      continue
      ;;
    --)
      remaining+=("$1")
      shift
      while [[ $# -gt 0 ]]; do
        remaining+=("$1")
        shift
      done
      break
      ;;
    *)
      remaining+=("$1")
      shift
      ;;
    esac
  done

  if (( ${#remaining[@]} > 0 )); then
    set -- "${remaining[@]}"
  else
    set --
  fi

  local env_file="${env_file_arg}"
  if [[ -z ${env_file} && -n ${ENV_FILE:-} ]]; then
    env_file="${ENV_FILE}"
    explicit=true
  fi

  local -a candidates=()
  if [[ -n ${env_file} ]]; then
    candidates=("${env_file}")
  else
    local repo_root="${REPO_ROOT:-}"
    if [[ -z ${repo_root} && -n ${SCRIPT_DIR:-} ]]; then
      if repo_root=$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd); then
        REPO_ROOT="${repo_root}"
      fi
    fi

    local -a roots=()
    if [[ -n ${repo_root} ]]; then
      roots+=("${repo_root}")
    fi
    if [[ -n ${PWD:-} ]]; then
      roots+=("${PWD}")
    fi
    roots+=("/opt/homelab")

    local root
    for root in "${roots[@]}"; do
      if [[ -z ${root} ]]; then
        continue
      fi
      candidates+=("${root}/.env" "${root}/.env.local" "${root}/.env.example")
    done
  fi

  local candidate
  local loaded=false
  for candidate in "${candidates[@]}"; do
    if [[ -z ${candidate} || ! -f ${candidate} ]]; then
      continue
    fi
    if ! _homelab_env_source_file "${candidate}"; then
      return $?
    fi
    HOMELAB_ENV_FILE="${candidate}"
    loaded=true
    break
  done

  if [[ ${explicit} == true ]]; then
    HOMELAB_ENV_FILE_EXPLICIT=true
  else
    HOMELAB_ENV_FILE_EXPLICIT=false
  fi

  if [[ ${loaded} == true ]]; then
    return 0
  fi

  if [[ -n ${env_file} ]]; then
    _homelab_env_log error "Environment file not found: ${env_file}"
    return 78
  fi

  return 0
}
