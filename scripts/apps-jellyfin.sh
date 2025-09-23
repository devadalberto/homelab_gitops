#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common-env.sh
source "${REPO_ROOT}/scripts/common-env.sh"

NAMESPACE="jellyfin"
RELEASE_NAME="jellyfin"
CHART_REPO_NAME="loeken-at-home"
CHART_REPO_URL="https://loeken-at-home.github.io/helm-charts"
CHART_NAME="${CHART_REPO_NAME}/jellyfin"
VALUES_FILE="${REPO_ROOT}/charts/jellyfin-values.yaml"
PV_MANIFEST="${REPO_ROOT}/charts/jellyfin-media-pv.yaml"
ENV_FILE_OVERRIDE=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [OPTIONS]

Deploy or upgrade the Jellyfin Helm chart using the homelab configuration.

Options:
  --env-file PATH    Load environment variables from PATH before deployment.
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

ensure_repo() {
  info "Adding/updating Helm repo ${CHART_REPO_NAME}"
  helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}" --force-update >/dev/null
  helm repo update "${CHART_REPO_NAME}" >/dev/null
}

apply_storage() {
  info "Applying PersistentVolume manifest ${PV_MANIFEST}"
  kubectl apply --filename "${PV_MANIFEST}"
}

install_chart() {
  info "Deploying ${RELEASE_NAME} to namespace ${NAMESPACE}"
  local -a helm_args=(
    upgrade
    --install
    "${RELEASE_NAME}"
    "${CHART_NAME}"
    --namespace "${NAMESPACE}"
    --create-namespace
    --values "${VALUES_FILE}"
    --wait
    --timeout 10m
  )

  if [[ -n ${LABZ_JELLYFIN_HOST:-} ]]; then
    helm_args+=(--set "ingress.main.hosts[0].host=${LABZ_JELLYFIN_HOST}")
    helm_args+=(--set "ingress.main.tls[0].hosts[0]=${LABZ_JELLYFIN_HOST}")
  fi

  helm "${helm_args[@]}"
}

print_followup() {
  local traefik_lb=""
  traefik_lb=$(kubectl get svc traefik --namespace traefik -o 'jsonpath={.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -z ${traefik_lb} ]]; then
    traefik_lb=$(kubectl get svc traefik --namespace traefik -o 'jsonpath={.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  fi

  printf '\nNext steps:\n'
  if [[ -n ${traefik_lb} ]]; then
    printf '  - Map DNS: %s -> %s\n' "${LABZ_JELLYFIN_HOST}" "${traefik_lb}"
  else
    printf '  - Determine the Traefik LoadBalancer address and map %s to it in DNS.\n' "${LABZ_JELLYFIN_HOST}"
  fi
  printf '  - Access Jellyfin at: https://%s/\n' "${LABZ_JELLYFIN_HOST}"
}

main() {
  parse_args "$@"

  require_cmd kubectl helm

  if [[ ! -f ${VALUES_FILE} ]]; then
    die "${EX_CONFIG}" "Values file not found: ${VALUES_FILE}"
  fi

  if [[ ! -f ${PV_MANIFEST} ]]; then
    die "${EX_CONFIG}" "PersistentVolume manifest not found: ${PV_MANIFEST}"
  fi

  local -a load_env_args=(--required)
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    load_env_args+=(--env-file "${ENV_FILE_OVERRIDE}")
  fi
  load_env "${load_env_args[@]}"

  : "${LABZ_JELLYFIN_HOST:?LABZ_JELLYFIN_HOST must be set}"

  ensure_namespace
  ensure_repo
  apply_storage
  install_chart
  print_followup
}

main "$@"
