#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--env-file" ]]; then ENV_FILE="${2:-./.env}"; shift 2; else ENV_FILE="./.env"; fi
sudo rm -f /opt/homelab/pfsense/config/pfSense-config.iso || true
echo "[OK] Cleaned generated artifacts"
