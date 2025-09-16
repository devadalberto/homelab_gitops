#!/usr/bin/env bash
set -Eeuo pipefail

ASSUME_YES=false
ENV_FILE="./.env"
DELETE_PREVIOUS=false

usage() {
  cat <<'USAGE'
Usage: uranus_homelab.sh [--env-file PATH] [--assume-yes] [--delete-previous-environment]

Runs the full Uranus homelab bootstrap, core addons, and app deployment.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%F %T')" "$*"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_ARGS=("--env-file" "${ENV_FILE}")
if [[ "${ASSUME_YES}" == "true" ]]; then
  COMMON_ARGS+=("--assume-yes")
fi

BOOTSTRAP_ARGS=("${COMMON_ARGS[@]}")
if [[ "${DELETE_PREVIOUS}" == "true" ]]; then
  BOOTSTRAP_ARGS+=("--delete-previous-environment")
fi

log "Running nuke and bootstrap"
"${SCRIPT_DIR}/uranus_nuke_and_bootstrap.sh" "${BOOTSTRAP_ARGS[@]}"

log "Installing core addons"
"${SCRIPT_DIR}/uranus_homelab_one.sh" "${COMMON_ARGS[@]}"

log "Deploying applications"
"${SCRIPT_DIR}/uranus_homelab_apps.sh" "${COMMON_ARGS[@]}"

log "Uranus homelab setup complete."
