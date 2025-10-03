#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

usage() {
  cat <<'USAGE'
Usage: k8s-pv.sh [OPTIONS]

Ensure the Minikube profile has persistent volume mounts for homelab services.

Options:
  --profile NAME   Override the Minikube profile to target.
  -h, --help       Show this help message and exit.
USAGE
}

PROFILE_OVERRIDE=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --profile)
      if [[ $# -lt 2 ]]; then
        usage >&2
        die "${EX_USAGE:-64}" "--profile requires a value"
      fi
      PROFILE_OVERRIDE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE_OVERRIDE="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit "${EX_OK:-0}"
      ;;
    *)
      usage >&2
      die "${EX_USAGE:-64}" "Unknown argument: $1"
      ;;
    esac
  done
}

parse_args "$@"

profile="${PROFILE_OVERRIDE:-${LABZ_MINIKUBE_PROFILE:-labz}}"
nextcloud_src="${LABZ_MOUNT_NEXTCLOUD:-/srv/nextcloud}"
media_src="${LABZ_MOUNT_MEDIA:-/srv/media}"
backups_src="${LABZ_MOUNT_BACKUPS:-/srv/backups}"

need minikube || die "${EX_UNAVAILABLE:-69}" "minikube command is required"

log_debug "Using Minikube profile ${profile}"

find_mount_pids() {
  local profile="$1"
  local host_path="$2"
  local cluster_path="$3"
  local line pid cmd
  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    pid="${line%% *}"
    cmd="${line#* }"
    if [[ ${cmd} != *"minikube mount"* ]]; then
      continue
    fi
    if [[ ${cmd} != *"${host_path}:${cluster_path}"* ]]; then
      continue
    fi
    if [[ ${cmd} == *"--profile=${profile}"* ]] || [[ ${cmd} == *"--profile ${profile}"* ]] ||
      [[ ${cmd} == *"-p ${profile}"* ]] || [[ ${cmd} == *"-p=${profile}"* ]]; then
      printf '%s\n' "${pid}"
    fi
  done < <(pgrep -af "minikube[[:space:]]+mount" 2>/dev/null || true)
}

start_mount() {
  local name="$1"
  local host_path="$2"
  local cluster_path="$3"
  local -a existing_pids=()
  mapfile -t existing_pids < <(find_mount_pids "${profile}" "${host_path}" "${cluster_path}")
  if ((${#existing_pids[@]} > 0)); then
    log_info "Minikube mount for ${name} already running (PID(s): ${existing_pids[*]})"
    return 0
  fi

  if [[ ! -d ${host_path} ]]; then
    log_warn "Host path ${host_path} does not exist; creating"
    if ! mkdir -p "${host_path}"; then
      log_error "Failed to create host directory ${host_path}"
      return 1
    fi
  fi

  local log_dir="${HOME}/.minikube/logs"
  mkdir -p "${log_dir}"
  local log_file="${log_dir}/mount-${profile}-${name}.log"

  log_info "Starting Minikube mount for ${name}: ${host_path} -> ${cluster_path}"
  if nohup minikube mount "${host_path}:${cluster_path}" --profile "${profile}" >"${log_file}" 2>&1 & then
    local pid=$!
    disown "${pid}" 2>/dev/null || true
    sleep 1
    if ps -p "${pid}" >/dev/null 2>&1; then
      log_info "Minikube mount for ${name} active (PID ${pid}). Logs: ${log_file}"
      return 0
    fi
    log_error "Minikube mount for ${name} exited unexpectedly. Check ${log_file}"
    return 1
  else
    log_error "Failed to launch Minikube mount for ${name}"
    return 1
  fi
}

status=0

start_mount nextcloud "${nextcloud_src}" "${nextcloud_src}" || status=$?
start_mount media "${media_src}" "${media_src}" || status=$?
start_mount backups "${backups_src}" "${backups_src}" || status=$?

if ((status == 0)); then
  log_info "All Minikube persistent volume mounts are running"
else
  log_error "One or more Minikube persistent volume mounts failed"
fi

exit "${status}"
