#!/usr/bin/env bash
set -Eeuo pipefail

ASSUME_YES=false
DELETE_PREVIOUS=false
ENV_FILE="./.env"

usage() {
  cat <<'USAGE'
Usage: uranus_nuke_and_bootstrap.sh [--env-file PATH] [--assume-yes] [--delete-previous-environment]

Bootstraps the Uranus homelab Minikube environment using configuration in .env.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%F %T')" "$*"
}

confirm() {
  local prompt=$1
  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  read -r -p "${prompt} [y/N]: " reply
  case "${reply}" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "Required command not found: ${cmd}" >&2
      exit 1
    fi
  done
}

load_env_file() {
  local file=$1
  if [[ ! -f "${file}" ]]; then
    echo "Environment file not found: ${file}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a
  source "${file}"
  set +a
}

require_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    echo "Missing required variables: ${missing[*]}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --assume-yes)
      ASSUME_YES=true
      shift
      ;;
    --delete-previous-environment)
      DELETE_PREVIOUS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

load_env_file "${ENV_FILE}"
require_vars LABZ_MINIKUBE_PROFILE LABZ_MINIKUBE_DRIVER LABZ_MINIKUBE_CPUS \
  LABZ_MINIKUBE_MEMORY LABZ_MINIKUBE_DISK LABZ_MOUNT_BACKUPS \
  LABZ_MOUNT_MEDIA LABZ_MOUNT_NEXTCLOUD LABZ_METALLB_RANGE \
  METALLB_POOL_START METALLB_POOL_END

: "${LABZ_MINIKUBE_EXTRA_ARGS:=}"
: "${SKIP_MINIKUBE_START:=false}"

require_command minikube kubectl helm

log "Ensuring host mount directories exist"
mkdir -p "${LABZ_MOUNT_BACKUPS}" "${LABZ_MOUNT_MEDIA}" "${LABZ_MOUNT_NEXTCLOUD}"

if [[ "${DELETE_PREVIOUS}" == "true" ]]; then
  if confirm "Delete existing Minikube profile ${LABZ_MINIKUBE_PROFILE}?"; then
    log "Deleting Minikube profile ${LABZ_MINIKUBE_PROFILE}"
    minikube delete -p "${LABZ_MINIKUBE_PROFILE}" >/dev/null 2>&1 || true
  fi
fi

log "Starting Minikube profile ${LABZ_MINIKUBE_PROFILE}"
MINIKUBE_ARGS=(
  --profile "${LABZ_MINIKUBE_PROFILE}"
  --driver "${LABZ_MINIKUBE_DRIVER}"
  --cpus "${LABZ_MINIKUBE_CPUS}"
  --memory "${LABZ_MINIKUBE_MEMORY}"
  --disk-size "${LABZ_MINIKUBE_DISK}"
)
if [[ -n "${LABZ_MINIKUBE_EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2207
  read -r -a EXTRA_ARGS <<<"${LABZ_MINIKUBE_EXTRA_ARGS}"
  MINIKUBE_ARGS+=("${EXTRA_ARGS[@]}")
fi
if [[ "${SKIP_MINIKUBE_START}" == "true" ]]; then
  if minikube status -p "${LABZ_MINIKUBE_PROFILE}" >/dev/null 2>&1; then
    log "Skipping Minikube start (SKIP_MINIKUBE_START=true and profile already running)"
  else
    log "Minikube profile not running; starting despite SKIP_MINIKUBE_START=true"
    minikube start "${MINIKUBE_ARGS[@]}"
  fi
else
  minikube start "${MINIKUBE_ARGS[@]}"
fi

log "Switching kubectl context to ${LABZ_MINIKUBE_PROFILE}"
kubectl config use-context "${LABZ_MINIKUBE_PROFILE}" >/dev/null

log "Enabling Minikube registry addon"
minikube -p "${LABZ_MINIKUBE_PROFILE}" addons enable registry >/dev/null
# Ensure the registry pods are ready before attempting to expose the service
kubectl -n kube-system rollout status deployment/registry --timeout=90s >/dev/null 2>&1 || true
# Expose the registry via local port-forwarding for host access
kubectl -n kube-system port-forward --address 0.0.0.0 svc/registry 5000:80 >/dev/null 2>&1 &
REGISTRY_URL="localhost:5000"
log "Local registry is reachable at ${REGISTRY_URL}"
cat <<INSTRUCTIONS
To push images:   docker tag IMAGE ${REGISTRY_URL}/IMAGE && docker push ${REGISTRY_URL}/IMAGE
To pull in cluster: use image reference ${REGISTRY_URL}/IMAGE
INSTRUCTIONS

log "Bootstrap complete. Proceed with uranus_homelab_one.sh for core addons."
