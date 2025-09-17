#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || source "$ROOT/.env.example"
if docker image inspect "${DJ_IMAGE}" >/dev/null 2>&1; then
  profile="${LABZ_MINIKUBE_PROFILE:-labz}"

  if ! minikube status -p "${profile}" >/dev/null 2>&1; then
    echo "Minikube profile '${profile}' is not running or does not exist. Start it and retry." >&2
    exit 1
  fi

  echo "Loading local image ${DJ_IMAGE} into minikube profile ${profile}..."
  minikube -p "${profile}" image load "${DJ_IMAGE}"
else
  echo "Local image ${DJ_IMAGE} not found. Build it and re-run this script."
fi
