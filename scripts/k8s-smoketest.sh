#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78

ENV_FILE_OVERRIDE=""
ENV_FILE_PATH=""

CONTEXT_RETRY_ATTEMPTS=${K8S_SMOKETEST_CONTEXT_ATTEMPTS:-30}
CONTEXT_RETRY_DELAY=${K8S_SMOKETEST_CONTEXT_DELAY:-5}
POD_READINESS_ATTEMPTS=${K8S_SMOKETEST_POD_ATTEMPTS:-18}
POD_READINESS_DELAY=${K8S_SMOKETEST_POD_DELAY:-10}
HTTP_PROBE_TIMEOUT=${K8S_SMOKETEST_HTTP_TIMEOUT:-20}

DESIRED_CONTEXT=""

usage() {
  cat <<'USAGE'
Usage: k8s-smoketest.sh [OPTIONS]

Validate Kubernetes cluster readiness for the homelab environment.

Options:
  --env-file PATH     Load environment configuration from PATH.
  --verbose           Increase logging verbosity to debug.
  -h, --help          Show this help message and exit.
USAGE
}

require_env_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die ${EX_CONFIG} "Missing required variables: ${missing[*]}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage
        die ${EX_USAGE} "--env-file requires a path argument"
      fi
      ENV_FILE_OVERRIDE="$2"
      shift 2
      ;;
    --verbose)
      log_set_level debug
      shift
      ;;
    -h | --help)
      usage
      exit ${EX_OK}
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      die ${EX_USAGE} "Unknown option: $1"
      ;;
    *)
      usage
      die ${EX_USAGE} "Positional arguments are not supported"
      ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    usage
    die ${EX_USAGE} "Positional arguments are not supported"
  fi
}

validate_retry_config() {
  if ! [[ ${CONTEXT_RETRY_ATTEMPTS} =~ ^[0-9]+$ ]] || ((CONTEXT_RETRY_ATTEMPTS <= 0)); then
    die ${EX_USAGE} "K8S_SMOKETEST_CONTEXT_ATTEMPTS must be a positive integer"
  fi
  if ! [[ ${CONTEXT_RETRY_DELAY} =~ ^[0-9]+$ ]] || ((CONTEXT_RETRY_DELAY <= 0)); then
    die ${EX_USAGE} "K8S_SMOKETEST_CONTEXT_DELAY must be a positive integer"
  fi
  if ! [[ ${POD_READINESS_ATTEMPTS} =~ ^[0-9]+$ ]] || ((POD_READINESS_ATTEMPTS <= 0)); then
    die ${EX_USAGE} "K8S_SMOKETEST_POD_ATTEMPTS must be a positive integer"
  fi
  if ! [[ ${POD_READINESS_DELAY} =~ ^[0-9]+$ ]] || ((POD_READINESS_DELAY <= 0)); then
    die ${EX_USAGE} "K8S_SMOKETEST_POD_DELAY must be a positive integer"
  fi
  if ! [[ ${HTTP_PROBE_TIMEOUT} =~ ^[0-9]+$ ]] || ((HTTP_PROBE_TIMEOUT <= 0)); then
    die ${EX_USAGE} "K8S_SMOKETEST_HTTP_TIMEOUT must be a positive integer"
  fi
}

ensure_kubectl_context() {
  local desired=$1
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"

  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ ${current} == "${desired}" ]]; then
    log_info "kubectl already targeting context ${desired}"
    return 0
  fi

  if [[ -n ${current} ]]; then
    log_info "Switching kubectl context from ${current} to ${desired}"
  else
    log_info "Setting kubectl context to ${desired}"
  fi

  local attempt=1
  while ((attempt <= CONTEXT_RETRY_ATTEMPTS)); do
    if kubectl config use-context "${desired}" >/dev/null 2>&1; then
      log_info "kubectl context set to ${desired}"
      return 0
    fi

    if ! kubectl config get-contexts "${desired}" >/dev/null 2>&1; then
      log_warn "kubectl context ${desired} is not yet available (attempt ${attempt}/${CONTEXT_RETRY_ATTEMPTS}); waiting for cluster to finish provisioning..."
    else
      log_warn "Failed to switch kubectl context to ${desired} (attempt ${attempt}/${CONTEXT_RETRY_ATTEMPTS}); retrying in ${CONTEXT_RETRY_DELAY}s..."
    fi

    sleep "${CONTEXT_RETRY_DELAY}"
    ((attempt++))
  done

  die ${EX_UNAVAILABLE} "Unable to switch kubectl context to ${desired} after ${CONTEXT_RETRY_ATTEMPTS} attempts"
}

check_ready_nodes() {
  log_info "Validating Kubernetes nodes report Ready status"
  if ! retry 12 5 kubectl get nodes >/dev/null 2>&1; then
    die ${EX_UNAVAILABLE} "kubectl get nodes failed after repeated attempts"
  fi

  local ready_count
  ready_count=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {count++} END {print count+0}')
  if [[ -z ${ready_count} || ${ready_count} -eq 0 ]]; then
    die ${EX_SOFTWARE} "No Ready nodes detected in context ${DESIRED_CONTEXT}"
  fi
  log_info "Detected ${ready_count} Ready node(s) in context ${DESIRED_CONTEXT}"
}

check_pod_health() {
  log_info "Ensuring all pods report Ready or Succeeded"
  local attempt=1
  while ((attempt <= POD_READINESS_ATTEMPTS)); do
    local pods_json
    if ! pods_json=$(kubectl get pods -A -o json 2>/dev/null); then
      log_warn "kubectl get pods failed (attempt ${attempt}/${POD_READINESS_ATTEMPTS}); retrying in ${POD_READINESS_DELAY}s"
    else
      local analysis
      local status=0
      if analysis=$(python3 -c '
import json, sys

try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError as exc:
    print(f"JSON decode error: {exc}")
    sys.exit(2)

unready = []
for item in data.get("items", []):
    metadata = item.get("metadata") or {}
    status = item.get("status") or {}
    namespace = metadata.get("namespace", "")
    name = metadata.get("name", "")
    phase = status.get("phase", "")

    if phase in ("Succeeded", "Completed"):
        continue

    conditions = status.get("conditions") or []
    ready_condition = next((c for c in conditions if c.get("type") == "Ready"), None)
    ready = bool(ready_condition and ready_condition.get("status") == "True")

    container_statuses = status.get("containerStatuses") or []
    total_containers = len(container_statuses)
    ready_containers = sum(1 for entry in container_statuses if entry.get("ready"))

    if phase == "Running" and ready and (total_containers == 0 or ready_containers == total_containers):
        continue

    reason = status.get("reason") or ""
    message = status.get("message") or ""
    details = ", ".join(part for part in (reason, message) if part)

    if details:
        unready.append(f"{namespace}/{name} (phase={phase}, ready={ready_containers}/{total_containers}, details={details})")
    else:
        unready.append(f"{namespace}/{name} (phase={phase}, ready={ready_containers}/{total_containers})")

if unready:
    print("\n".join(unready))
    sys.exit(1)
' <<<"${pods_json}"); then
        log_info "All pods across namespaces are Ready or Succeeded"
        return 0
      else
        status=$?
      fi
      if [[ ${status} -eq 1 && -n ${analysis} ]]; then
        log_warn "Pods not yet Ready (attempt ${attempt}/${POD_READINESS_ATTEMPTS}):"
        while IFS= read -r line; do
          [[ -n ${line} ]] && log_warn "  ${line}"
        done <<<"${analysis}"
      else
        log_warn "Unable to evaluate pod readiness (attempt ${attempt}/${POD_READINESS_ATTEMPTS}); retrying in ${POD_READINESS_DELAY}s"
        if [[ -n ${analysis} ]]; then
          log_debug "Readiness evaluation error: ${analysis}"
        fi
      fi
    fi

    if ((attempt == POD_READINESS_ATTEMPTS)); then
      die ${EX_SOFTWARE} "Pods failed to become Ready after ${POD_READINESS_ATTEMPTS} attempts"
    fi

    ((attempt++))
    sleep "${POD_READINESS_DELAY}"
  done
}

ensure_service() {
  if [[ $# -ne 2 ]]; then
    die ${EX_USAGE} "ensure_service requires <namespace> and <service-name>"
  fi
  local namespace=$1
  local name=$2
  if ! kubectl -n "${namespace}" get svc "${name}" >/dev/null 2>&1; then
    die ${EX_SOFTWARE} "Service ${namespace}/${name} not found"
  fi
  log_info "Verified service ${namespace}/${name}"
}

check_services() {
  log_info "Validating core services"
  ensure_service traefik traefik
  ensure_service nextcloud nextcloud
  ensure_service jellyfin jellyfin

  local svc_type
  svc_type=$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)
  if [[ ${svc_type} != "LoadBalancer" ]]; then
    die ${EX_SOFTWARE} "Traefik service type is ${svc_type:-unknown}; expected LoadBalancer"
  fi

  local actual_ip
  actual_ip=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z ${actual_ip} ]]; then
    die ${EX_UNAVAILABLE} "Traefik LoadBalancer does not report an external IP"
  fi
  if [[ ${actual_ip} != "${TRAEFIK_LOCAL_IP}" ]]; then
    die ${EX_SOFTWARE} "Traefik LoadBalancer IP ${actual_ip} does not match expected ${TRAEFIK_LOCAL_IP}"
  fi
  log_info "Traefik service advertises expected LoadBalancer IP ${actual_ip}"
}

probe_via_traefik() {
  if [[ $# -lt 2 ]]; then
    die ${EX_USAGE} "probe_via_traefik requires <host> and <description>"
  fi
  local host=$1
  local description=$2
  local path="${3:-/}"
  local url="https://${host}${path}"

  log_info "Probing ${description} at ${url} via Traefik VIP ${TRAEFIK_LOCAL_IP}"
  local http_code
  if ! http_code=$(curl --silent --show-error --fail --location -k --resolve "${host}:443:${TRAEFIK_LOCAL_IP}" --max-time "${HTTP_PROBE_TIMEOUT}" "${url}" -o /dev/null -w '%{http_code}'); then
    die ${EX_UNAVAILABLE} "HTTP probe for ${description} at ${url} via Traefik IP ${TRAEFIK_LOCAL_IP} failed"
  fi
  log_info "  ${description} responded with HTTP ${http_code}"
}

probe_http_endpoints() {
  log_info "Validating ingress endpoints via Traefik"
  probe_via_traefik "${LABZ_NEXTCLOUD_HOST}" "Nextcloud"
  probe_via_traefik "${LABZ_JELLYFIN_HOST}" "Jellyfin"
}

main() {
  parse_args "$@"
  validate_retry_config
  if load_env "${ENV_FILE_OVERRIDE}"; then
    ENV_FILE_PATH="${HOMELAB_ENV_FILE:-${ENV_FILE_OVERRIDE:-}}"
  else
    if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    ENV_FILE_PATH=""
    log_warn "No environment file found; relying on existing environment variables"
  fi

  require_env_vars LABZ_MINIKUBE_PROFILE TRAEFIK_LOCAL_IP LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST
  DESIRED_CONTEXT="${LABZ_MINIKUBE_PROFILE}"

  if [[ -n ${ENV_FILE_PATH} ]]; then
    log_info "Environment file: ${ENV_FILE_PATH}"
  fi
  log_info "Expected Traefik VIP: ${TRAEFIK_LOCAL_IP}"
  log_info "Nextcloud host: ${LABZ_NEXTCLOUD_HOST}"
  log_info "Jellyfin host: ${LABZ_JELLYFIN_HOST}"

  need kubectl curl python3 || die ${EX_UNAVAILABLE} "kubectl, curl, and python3 are required"

  log_info "Using kubectl context ${DESIRED_CONTEXT} derived from LABZ_MINIKUBE_PROFILE"
  ensure_kubectl_context "${DESIRED_CONTEXT}"

  check_ready_nodes
  check_pod_health
  check_services
  probe_http_endpoints

  log_info "Kubernetes smoketest completed successfully."
}

main "$@"
