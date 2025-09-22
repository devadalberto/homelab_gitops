#!/usr/bin/env bash
set -euo pipefail

load_env() {
  local env_file=""
  local -a remaining=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -e | --env-file)
      if [[ $# -lt 2 ]]; then
        printf 'load_env: %s requires a path argument\n' "$1" >&2
        return 64
      fi
      env_file="$2"
      shift 2
      continue
      ;;
    -e=*)
      env_file="${1#*=}"
      if [[ -z ${env_file} ]]; then
        printf 'load_env: -e requires a path argument\n' >&2
        return 64
      fi
      shift
      continue
      ;;
    --env-file=*)
      env_file="${1#*=}"
      if [[ -z ${env_file} ]]; then
        printf 'load_env: --env-file requires a path argument\n' >&2
        return 64
      fi
      shift
      continue
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        remaining+=("$1")
        shift
      done
      break
      ;;
    -*)
      remaining+=("$1")
      shift
      ;;
    *)
      if [[ -z ${env_file} && -f "$1" ]]; then
        env_file="$1"
        shift
      else
        remaining+=("$1")
        shift
      fi
      ;;
    esac
  done

  if [[ ${#remaining[@]} -gt 0 ]]; then
    set -- "${remaining[@]}"
  else
    set --
  fi
  LOAD_ENV_ARGS=("$@")

  if [[ -z ${env_file} ]]; then
    return 0
  fi

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
