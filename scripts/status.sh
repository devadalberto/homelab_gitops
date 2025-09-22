#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--env-file" ]]; then ENV_FILE="${2:-./.env}"; shift 2; else ENV_FILE="./.env"; fi

echo "=== pfSense VM Disks ==="
sudo virsh domblklist "${PF_VM_NAME:-pfsense-uranus}" || true
echo
echo "=== pfSense VM NICs ==="
sudo virsh domiflist "${PF_VM_NAME:-pfsense-uranus}" || true
echo
echo "=== Config Artifacts ==="
ls -l /opt/homelab/pfsense/config/ || true
