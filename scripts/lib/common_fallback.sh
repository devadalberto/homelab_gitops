# shellcheck shell=bash
# Fallback helper definitions used when scripts/lib/common.sh is unavailable.
# These helpers intentionally mirror the public interface of common.sh but
# provide a reduced implementation so that callers can continue executing with
# graceful degradation.

if [[ -n ${_HOMELAB_COMMON_FALLBACK_SH_SOURCED:-} ]]; then
  return 0
fi
readonly _HOMELAB_COMMON_FALLBACK_SH_SOURCED=1

: "${LOG_LEVEL:=info}"

_homelab_fallback_ts() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

_homelab_fallback_should_log() {
  local desired current
  case "${1,,}" in
  trace) desired=0 ;;
  debug) desired=1 ;;
  info) desired=2 ;;
  warn | warning) desired=3 ;;
  error) desired=4 ;;
  fatal | crit | critical) desired=5 ;;
  *) desired=2 ;;
  esac
  case "${LOG_LEVEL,,}" in
  trace) current=0 ;;
  debug) current=1 ;;
  info) current=2 ;;
  warn | warning) current=3 ;;
  error) current=4 ;;
  fatal | crit | critical) current=5 ;;
  *) current=2 ;;
  esac
  [[ $desired -ge $current ]]
}

_homelab_fallback_log() {
  local level=${1,,}
  shift || true
  if _homelab_fallback_should_log "$level"; then
    printf '%s [%5s] %s\n' "$(_homelab_fallback_ts)" "${level^^}" "$*" >&2
  fi
}

log_set_level() {
  if [[ $# -ne 1 ]]; then
    echo "Usage: log_set_level <trace|debug|info|warn|error|fatal>" >&2
    return 64
  fi
  LOG_LEVEL=${1,,}
}

log_trace() { _homelab_fallback_log trace "$*"; }
log_debug() { _homelab_fallback_log debug "$*"; }
log_info() { _homelab_fallback_log info "$*"; }
log_warn() { _homelab_fallback_log warn "$*"; }
log_error() { _homelab_fallback_log error "$*"; }
log_fatal() { _homelab_fallback_log fatal "$*"; }

die() {
  local status=1
  if [[ $# -gt 0 && $1 =~ ^[0-9]+$ ]]; then
    status=$1
    shift
  fi
  if [[ $# -gt 0 ]]; then
    log_fatal "$*"
  fi
  exit "$status"
}

need() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required commands: ${missing[*]}"
    return 127
  fi
}

retry() {
  local attempts=5
  local delay=2

  if [[ $# -gt 0 && $1 =~ ^[0-9]+$ ]]; then
    attempts=$1
    shift
  fi
  if [[ $# -gt 0 && $1 =~ ^[0-9]+$ ]]; then
    delay=$1
    shift
  fi

  if [[ $# -eq 0 ]]; then
    log_error "retry: command to execute is required"
    return 64
  fi

  local try=1
  local last_status=1
  local status
  while ((try <= attempts)); do
    "$@"
    status=$?
    if ((status == 0)); then
      return 0
    fi
    last_status=$status
    if ((try < attempts)); then
      log_warn "Attempt ${try}/${attempts} failed (exit ${status}). Retrying in ${delay}s..."
      sleep "$delay"
    fi
    ((++try))
  done

  log_error "Command failed after ${attempts} attempts: $*"
  return ${last_status}
}

format_command() {
  if [[ $# -eq 0 ]]; then
    printf ''
    return 0
  fi
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -z ${formatted} ]]; then
      formatted=$(printf '%q' "$arg")
    else
      formatted+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s' "$formatted"
}

declare -A _HOMELAB_FALLBACK_TRAP_HANDLERS=()

trap_add() {
  if [[ $# -lt 1 ]]; then
    log_error "trap_add: handler is required"
    return 64
  fi
  local handler=$1
  shift || true
  if [[ $# -eq 0 ]]; then
    set -- EXIT
  fi
  local sig
  for sig in "$@"; do
    if [[ -n ${_HOMELAB_FALLBACK_TRAP_HANDLERS[$sig]:-} ]]; then
      _HOMELAB_FALLBACK_TRAP_HANDLERS[$sig]+=";${handler}"
    else
      _HOMELAB_FALLBACK_TRAP_HANDLERS[$sig]="${handler}"
    fi
    trap "${_HOMELAB_FALLBACK_TRAP_HANDLERS[$sig]}" "$sig"
  done
}

declare -a _HOMELAB_FALLBACK_PORT_FORWARD_PIDS=()
declare _HOMELAB_FALLBACK_PORT_FORWARD_TRAPS_INSTALLED=0

_homelab_fallback_port_forward_cleanup() {
  local pid
  for pid in "${_HOMELAB_FALLBACK_PORT_FORWARD_PIDS[@]}"; do
    if [[ -n ${pid} ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      log_debug "Stopping port-forward process ${pid}"
      kill "${pid}" >/dev/null 2>&1 || true
      wait "${pid}" >/dev/null 2>&1 || true
    fi
  done
}

_homelab_fallback_port_forward_register_traps() {
  if [[ ${_HOMELAB_FALLBACK_PORT_FORWARD_TRAPS_INSTALLED:-0} -eq 1 ]]; then
    return
  fi
  trap_add _homelab_fallback_port_forward_cleanup EXIT INT TERM
  _HOMELAB_FALLBACK_PORT_FORWARD_TRAPS_INSTALLED=1
}

start_port_forward() {
  local name=""
  local dry_run=false
  local startup_delay=2
  local -a success_messages=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --name)
      name=$2
      shift 2
      ;;
    --dry-run)
      dry_run=$2
      shift 2
      ;;
    --startup-delay)
      startup_delay=$2
      shift 2
      ;;
    --success-message)
      success_messages+=("$2")
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      log_error "start_port_forward: unknown option: $1"
      return 64
      ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    log_error "start_port_forward: command is required"
    return 64
  fi

  local -a cmd=("$@")
  if [[ -z ${name} ]]; then
    name=${cmd[0]}
  fi

  local formatted
  formatted=$(format_command "${cmd[@]}")

  if [[ ${dry_run} == true ]]; then
    log_info "[DRY-RUN] ${name} port-forward: ${formatted}"
    return 0
  fi

  log_debug "Launching ${name} port-forward: ${formatted}"
  "${cmd[@]}" >/dev/null 2>&1 &
  local pf_pid=$!
  sleep "${startup_delay}"

  if ! kill -0 "${pf_pid}" >/dev/null 2>&1; then
    wait "${pf_pid}" >/dev/null 2>&1 || true
    log_error "${name} port-forward failed to start"
    return 1
  fi

  _HOMELAB_FALLBACK_PORT_FORWARD_PIDS+=("${pf_pid}")
  _homelab_fallback_port_forward_register_traps

  log_info "${name} port-forward active (PID ${pf_pid})"
  local message
  for message in "${success_messages[@]}"; do
    log_info "${message}"
  done

  return 0
}

wait_for_port_forwards() {
  if [[ ${#_HOMELAB_FALLBACK_PORT_FORWARD_PIDS[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "Waiting for active port-forwards to terminate."
  local pid
  for pid in "${_HOMELAB_FALLBACK_PORT_FORWARD_PIDS[@]}"; do
    if [[ -n ${pid} ]] && kill -0 "${pid}" >/dev/null 2>&1; then
      wait "${pid}" || true
    fi
  done
}

load_env() {
  if [[ $# -ne 1 ]]; then
    log_error "Usage: load_env <env-file>"
    return 64
  fi
  local env_file=$1
  if [[ ! -f $env_file ]]; then
    log_error "Environment file not found: $env_file"
    return 1
  fi

  log_debug "Loading environment from $env_file"
  local prev_state
  prev_state=$(set +o)
  set -a
  # shellcheck disable=SC1090
  source "$env_file"
  eval "$prev_state"
}

homelab_resolve_existing_dir() {
  if [[ $# -ne 1 ]]; then
    log_error "Usage: homelab_resolve_existing_dir <path>"
    return 64
  fi

  local path=$1
  if [[ -z ${path} ]]; then
    printf '%s\n' ""
    return 0
  fi

  local dir=$path
  if [[ -d ${dir} ]]; then
    printf '%s\n' "$dir"
    return 0
  fi

  if [[ -e ${dir} ]]; then
    dir=$(dirname "$dir")
  else
    dir=$(dirname "$dir")
    while [[ $dir != '/' && ! -d $dir ]]; do
      dir=$(dirname "$dir")
    done
  fi

  printf '%s\n' "$dir"
}

homelab_maybe_reexec_for_privileged_paths() {
  if [[ $# -lt 1 ]]; then
    log_error "Usage: homelab_maybe_reexec_for_privileged_paths <guard-var> [paths...]"
    return 64
  fi

  local guard_var=$1
  shift || true

  if [[ ${DRY_RUN:-false} == true ]]; then
    return 0
  fi

  if ((EUID == 0)); then
    return 0
  fi

  local path existing escalate_target=""
  for path in "$@"; do
    [[ -z ${path} ]] && continue
    existing=$(homelab_resolve_existing_dir "$path") || return $?
    if [[ -z ${existing} ]]; then
      continue
    fi
    if [[ ${existing} == /opt/homelab* ]]; then
      escalate_target=${existing}
      break
    fi
    if [[ ! -w ${existing} ]]; then
      escalate_target=${existing}
      break
    fi
  done

  if [[ -z ${escalate_target} ]]; then
    return 0
  fi

  if [[ -n ${!guard_var-} ]]; then
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    die "${EX_UNAVAILABLE:-69}" \
      "Root privileges required to modify ${escalate_target}. Install sudo or rerun as root."
  fi

  if [[ -z ${ORIGINAL_ARGS+x} ]]; then
    die "${EX_SOFTWARE:-70}" \
      "ORIGINAL_ARGS is not defined; cannot re-execute with sudo."
  fi

  log_warn "Elevating privileges via sudo to modify ${escalate_target}. Re-executing..."
  export "${guard_var}=1"
  exec sudo -E -- "$0" "${ORIGINAL_ARGS[@]}"
}

ensure_namespace() {
  if [[ $# -ne 1 ]]; then
    log_error "Usage: ensure_namespace <namespace>"
    return 64
  fi
  need kubectl || return $?
  local namespace=$1
  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    log_info "Creating namespace $namespace"
    kubectl create namespace "$namespace"
  else
    log_debug "Namespace $namespace already exists"
  fi
}

ensure_helm_repo() {
  if [[ $# -ne 2 ]]; then
    log_error "Usage: ensure_helm_repo <name> <url>"
    return 64
  fi
  need helm || return $?
  local name=$1
  local url=$2

  if ! helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$name"; then
    log_info "Adding Helm repository $name ($url)"
    helm repo add "$name" "$url"
  else
    log_debug "Helm repository $name already present"
  fi

  log_debug "Updating Helm repository $name"
  helm repo update "$name"
}

helm_upgrade_install() {
  if [[ $# -lt 3 ]]; then
    log_error "Usage: helm_upgrade_install <release> <chart> <namespace> [args...]"
    return 64
  fi
  need helm kubectl || return $?

  local release=$1
  local chart=$2
  local namespace=$3
  shift 3

  ensure_namespace "$namespace" || return $?
  log_info "Deploying Helm release $release to namespace $namespace"
  helm upgrade --install "$release" "$chart" --namespace "$namespace" "$@"
}

k_wait_ns() {
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    log_error "Usage: k_wait_ns <namespace> [timeout]"
    return 64
  fi
  need kubectl || return $?
  local namespace=$1
  local timeout=${2:-300s}

  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    log_error "Namespace $namespace does not exist"
    return 1
  fi

  local pods
  pods=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null || true)
  if [[ -z $pods ]]; then
    log_info "No pods found in namespace $namespace"
    return 0
  fi

  log_info "Waiting for pods in namespace $namespace to become Ready"
  kubectl wait --namespace "$namespace" --for=condition=Ready pod --all --timeout="$timeout"
}

k_rollout() {
  if [[ $# -lt 2 || $# -gt 4 ]]; then
    log_error "Usage: k_rollout <kind> <name> [namespace] [timeout]"
    return 64
  fi
  need kubectl || return $?

  local kind=$1
  local name=$2
  local namespace=${3:-}
  local timeout=${4:-300s}

  log_info "Waiting for rollout of $kind/$name"
  if [[ -n $namespace ]]; then
    kubectl -n "$namespace" rollout status "$kind/$name" --timeout="$timeout"
  else
    kubectl rollout status "$kind/$name" --timeout="$timeout"
  fi
}

pvc_wait_bound() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    log_error "Usage: pvc_wait_bound <name> <namespace> [timeout]"
    return 64
  fi
  need kubectl || return $?

  local name=$1
  local namespace=$2
  local timeout=${3:-300s}

  log_info "Waiting for PVC $name in namespace $namespace to become Bound"
  kubectl wait --namespace "$namespace" --for=condition=Bound pvc/"$name" --timeout="$timeout"
}

k_diag_namespace_overview() {
  if [[ $# -ne 1 ]]; then
    log_error "Usage: k_diag_namespace_overview <namespace>"
    return 64
  fi
  need kubectl || return $?
  local namespace=$1

  log_info "Namespace overview for $namespace"
  kubectl get all -n "$namespace"
  kubectl get pvc -n "$namespace"
  kubectl get ingress -n "$namespace" 2>/dev/null || true
}

k_diag_events() {
  if [[ $# -ne 1 ]]; then
    log_error "Usage: k_diag_events <namespace>"
    return 64
  fi
  need kubectl || return $?
  local namespace=$1

  log_info "Recent events in namespace $namespace"
  kubectl get events -n "$namespace" --sort-by=.metadata.creationTimestamp
}

k_diag_resource_yaml() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    log_error "Usage: k_diag_resource_yaml <kind> <name> [namespace]"
    return 64
  fi
  need kubectl || return $?
  local kind=$1
  local name=$2
  local namespace=${3:-}

  if [[ -n $namespace ]]; then
    kubectl get "$kind" "$name" -n "$namespace" -o yaml
  else
    kubectl get "$kind" "$name" -o yaml
  fi
}

k_diag_pod_logs() {
  if [[ $# -lt 2 || $# -gt 4 ]]; then
    log_error "Usage: k_diag_pod_logs <namespace> <pod> [container] [tail_lines]"
    return 64
  fi
  need kubectl || return $?
  local namespace=$1
  local pod=$2
  local container=${3:-}
  local tail_lines=${4:-200}

  log_info "Fetching logs for pod $pod in namespace $namespace"
  if [[ -n $container ]]; then
    kubectl logs "$pod" -n "$namespace" -c "$container" --tail="$tail_lines"
  else
    kubectl logs "$pod" -n "$namespace" --tail="$tail_lines"
  fi
}
