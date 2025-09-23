#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

NAMESPACE="nextcloud"
RELEASE_NAME="nextcloud"
CHART_NAME="nextcloud/nextcloud"
HELM_REPO_NAME="nextcloud"
HELM_REPO_URL="https://nextcloud.github.io/helm/"
VALUES_FILE="${REPO_ROOT}/values/nextcloud.yaml"
STORAGE_MANIFEST="${REPO_ROOT}/charts/nextcloud/pv-pvc.yaml"

ENV_FILE_OVERRIDE=""
REINSTALL=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy or upgrade the Nextcloud Helm chart using the homelab environment configuration.

Options:
  --env-file PATH    Load environment variables from PATH before deployment.
  --reinstall        Uninstall the existing release before deploying.
  -h, --help         Show this help message and exit.
USAGE
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file|-e)
        if [[ $# -lt 2 ]]; then
          usage >&2
          die "${EX_USAGE}" "--env-file requires a path argument"
        fi
        ENV_FILE_OVERRIDE="$2"
        shift 2
        ;;
      --env-file=*|-e=*)
        ENV_FILE_OVERRIDE="${1#*=}"
        shift
        ;;
      --reinstall)
        REINSTALL=true
        shift
        ;;
      -h|--help)
        usage
        exit "${EX_OK}"
        ;;
      --)
        shift
        if [[ $# -gt 0 ]]; then
          usage >&2
          die "${EX_USAGE}" "Unexpected positional arguments: $*"
        fi
        ;;
      -*)
        usage >&2
        die "${EX_USAGE}" "Unknown option: $1"
        ;;
      *)
        usage >&2
        die "${EX_USAGE}" "Positional arguments are not supported"
        ;;
    esac
  done
}

ensure_namespace() {
  if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    info "Creating namespace ${NAMESPACE}"
    kubectl create namespace "${NAMESPACE}"
  else
    log_debug "Namespace ${NAMESPACE} already exists"
  fi
}

apply_storage_manifest() {
  if [[ ! -f ${STORAGE_MANIFEST} ]]; then
    die "${EX_SOFTWARE}" "Persistent volume manifest not found at ${STORAGE_MANIFEST}"
  fi
  info "Applying persistent volume and claim manifest"
  kubectl apply -f "${STORAGE_MANIFEST}"
}

ensure_nextcloud_repo() {
  info "Adding/updating Helm repo ${HELM_REPO_NAME}"
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" --force-update >/dev/null
  helm repo update "${HELM_REPO_NAME}" >/dev/null
}

release_exists() {
  helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" >/dev/null 2>&1
}

reinstall_release() {
  if release_exists; then
    info "Uninstalling existing release ${RELEASE_NAME} from namespace ${NAMESPACE}"
    helm uninstall "${RELEASE_NAME}" --namespace "${NAMESPACE}" --wait
  else
    log_debug "No existing release ${RELEASE_NAME} found in namespace ${NAMESPACE}"
  fi
}

install_chart() {
  local host=${LABZ_NEXTCLOUD_HOST:?LABZ_NEXTCLOUD_HOST must be set}
  local admin_user=${LABZ_NEXTCLOUD_ADMIN_USER:-ncadmin}
  local admin_password=${LABZ_NEXTCLOUD_ADMIN_PASSWORD:-changeme}
  local postgres_db=${LABZ_POSTGRES_DB:?LABZ_POSTGRES_DB must be set}
  local postgres_user=${LABZ_POSTGRES_USER:?LABZ_POSTGRES_USER must be set}
  local postgres_password=${LABZ_POSTGRES_PASSWORD:?LABZ_POSTGRES_PASSWORD must be set}
  local redis_password=${LABZ_REDIS_PASSWORD:?LABZ_REDIS_PASSWORD must be set}

  if [[ ${admin_password} == "changeme" ]]; then
    warn "Using default Nextcloud admin password 'changeme'. Set LABZ_NEXTCLOUD_ADMIN_PASSWORD in your .env file to override."
  fi

  info "Deploying ${RELEASE_NAME} to namespace ${NAMESPACE}"

  helm upgrade --install "${RELEASE_NAME}" "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --values "${VALUES_FILE}" \
    --set-string nextcloud.host="${host}" \
    --set-string nextcloud.username="${admin_user}" \
    --set-string nextcloud.password="${admin_password}" \
    --set-string nextcloud.trustedDomains[0]="${host}" \
    --set-string ingress.tls[0].hosts[0]="${host}" \
    --set-string externalDatabase.user="${postgres_user}" \
    --set-string externalDatabase.password="${postgres_password}" \
    --set-string externalDatabase.database="${postgres_db}" \
    --set-string externalRedis.password="${redis_password}" \
    --wait \
    --timeout 10m
}

print_followup() {
  local traefik_lb
  traefik_lb=$(kubectl get svc traefik --namespace traefik -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z ${traefik_lb} ]]; then
    traefik_lb=$(kubectl get svc traefik --namespace traefik -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  fi

  printf '\nNext steps:\n'
  if [[ -n ${traefik_lb} ]]; then
    printf '  - Map DNS: %s -> %s\n' "${LABZ_NEXTCLOUD_HOST}" "${traefik_lb}"
  else
    printf '  - Determine the Traefik LoadBalancer address and map %s to it in DNS.\n' "${LABZ_NEXTCLOUD_HOST}"
  fi
  printf '  - Access Nextcloud at: https://%s/\n' "${LABZ_NEXTCLOUD_HOST}"
  printf '  - Admin username: %s\n' "${LABZ_NEXTCLOUD_ADMIN_USER:-ncadmin}"
  printf '  - Admin password: %s\n' "${LABZ_NEXTCLOUD_ADMIN_PASSWORD:-changeme}"
}

main() {
  parse_args "$@"

  require_cmd kubectl helm

  local -a load_env_args=(--required)
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    load_env_args+=(--env-file "${ENV_FILE_OVERRIDE}")
  fi
  load_env "${load_env_args[@]}"

  ensure_namespace
  apply_storage_manifest
  ensure_nextcloud_repo

  if [[ ${REINSTALL} == true ]]; then
    reinstall_release
  fi

  install_chart
  print_followup
}

main "$@"
