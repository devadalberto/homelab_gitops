#!/usr/bin/env bash
set -euo pipefail
if ! command -v flux >/dev/null 2>&1; then
  curl -s https://fluxcd.io/install.sh | bash
fi
kubectl create ns flux-system --dry-run=client -o yaml | kubectl apply -f -
flux install -n flux-system || true
mkdir -p "$(dirname "$0")/clusters/uranus"
