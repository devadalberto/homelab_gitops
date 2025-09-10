#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || source "$ROOT/.env.example"
if docker image inspect "${DJ_IMAGE}" >/dev/null 2>&1; then
  echo "Loading local image ${DJ_IMAGE} into minikube..."
  minikube -p uranus image load "${DJ_IMAGE}"
else
  echo "Local image ${DJ_IMAGE} not found. Build it and re-run this script."
fi
