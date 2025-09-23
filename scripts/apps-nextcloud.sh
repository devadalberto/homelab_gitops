#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

NAMESPACE="nextcloud"
RELEASE_NAME="nextcloud"
CHART_NAME="bitnami/nextcloud"
BITNAMI_REPO_NAME="bitnami"
BITNAMI_REPO_URL="https://charts.bitnami.com/bitnami"
VALUES_FILE=""
ENV_FILE_OVERRIDE=""
REINSTALL=false

cleanup() {
  if [[ -n ${VALUES_FILE} && -f ${VALUES_FILE} ]]; then
    rm -f "${VALUES_FILE}"
  fi
}
trap cleanup EXIT

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

ensure_bitnami_repo() {
  info "Adding/updating Helm repo ${BITNAMI_REPO_NAME}"
  helm repo add "${BITNAMI_REPO_NAME}" "${BITNAMI_REPO_URL}" --force-update >/dev/null
  helm repo update "${BITNAMI_REPO_NAME}" >/dev/null
}

get_secret_field() {
  local secret_name=$1
  local field=$2
  kubectl get secret "${secret_name}" \
    --namespace "${NAMESPACE}" \
    --ignore-not-found \
    -o "jsonpath={.data.${field}}" 2>/dev/null || true
}

ensure_password_value() {
  local secret_name=$1
  local field=$2
  local generated=$3
  local current
  current=$(get_secret_field "${secret_name}" "${field}")
  if [[ -n ${current} ]]; then
    printf '%s' "${current}" | base64 --decode
    return 0
  fi
  printf '%s' "${generated}"
}

random_password() {
  local length=${1:-32}
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${length}"
}

render_values() {
  local mariadb_secret="${RELEASE_NAME}-mariadb"
  local mariadb_password
  local mariadb_root_password

  mariadb_password=$(ensure_password_value "${mariadb_secret}" "mariadb-password" "$(random_password 32)")
  mariadb_root_password=$(ensure_password_value "${mariadb_secret}" "mariadb-root-password" "$(random_password 32)")

  local nextcloud_admin_user=${LABZ_NEXTCLOUD_ADMIN_USER:-ncadmin}
  local nextcloud_admin_password=${LABZ_NEXTCLOUD_ADMIN_PASSWORD:-changeme}
  local nextcloud_admin_email=${LABZ_NEXTCLOUD_ADMIN_EMAIL:-admin@${LABZ_DOMAIN:-example.com}}
  local nextcloud_host=${LABZ_NEXTCLOUD_HOST:?LABZ_NEXTCLOUD_HOST must be set}
  local nextcloud_storage_size=${LABZ_NEXTCLOUD_STORAGE_SIZE:-100Gi}
  local mariadb_storage_size=${LABZ_NEXTCLOUD_DB_SIZE:-20Gi}
  local php_upload_limit=${LABZ_PHP_UPLOAD_LIMIT:-512M}

  if [[ ${nextcloud_admin_password} == "changeme" ]]; then
    warn "Using default Nextcloud admin password 'changeme'. Set LABZ_NEXTCLOUD_ADMIN_PASSWORD in your .env file to override."
  fi

  VALUES_FILE=$(mktemp)
  cat <<EOF_VALUES >"${VALUES_FILE}"
nextcloudHost: "${nextcloud_host}"
nextcloudUsername: "${nextcloud_admin_user}"
nextcloudPassword: "${nextcloud_admin_password}"
nextcloudEmail: "${nextcloud_admin_email}"

phpClient:
  maxUploadSize: "${php_upload_limit}"

ingress:
  enabled: true
  ingressClassName: traefik
  hostname: "${nextcloud_host}"
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
  tls: true
  extraTls:
    - hosts:
        - "${nextcloud_host}"
      secretName: labz-apps-tls

persistence:
  enabled: true
  storageClass: ""
  size: "${nextcloud_storage_size}"

mariadb:
  enabled: true
  auth:
    username: nextcloud
    database: nextcloud
    password: "${mariadb_password}"
    rootPassword: "${mariadb_root_password}"
  primary:
    persistence:
      enabled: true
      storageClass: ""
      size: "${mariadb_storage_size}"
EOF_VALUES
}

install_chart() {
  info "Deploying ${RELEASE_NAME} to namespace ${NAMESPACE}"
  helm upgrade --install "${RELEASE_NAME}" "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 10m
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

  require_cmd kubectl helm openssl

  local -a load_env_args=(--required)
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    load_env_args+=(--env-file "${ENV_FILE_OVERRIDE}")
  fi
  load_env "${load_env_args[@]}"

  ensure_namespace
  ensure_bitnami_repo
  if [[ ${REINSTALL} == true ]]; then
    reinstall_release
  fi
  render_values
  install_chart
  print_followup
}

main "$@"
