#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--env-file" ]]; then ENV_FILE="${2:-./.env}"; shift 2; else ENV_FILE="./.env"; fi
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

BASE="/opt/homelab/pfsense/config"
sudo mkdir -p "$BASE"

# Atomic write with proper perms for VIP hints (avoid Permission denied)
if [[ -n "${LABZ_METALLB_RANGE:-}" ]]; then
  tmp="$(mktemp)"
  printf 'METALLB_RANGE="%s"\n' "$LABZ_METALLB_RANGE" >"$tmp"
  sudo mv "$tmp" "$BASE/_vips.env"
fi

# Render config.xml placeholder if not present (your templater may overwrite later)
if [[ ! -f "$BASE/config.xml" ]]; then
  echo "<pfsense/>" | sudo tee "$BASE/config.xml" >/dev/null
fi

ISO="$BASE/pfSense-config.iso"
LABEL="pfSense_config"

USE_GENISO=0
if command -v xorriso >/dev/null 2>&1; then
  # Note: do NOT pass '-quiet' to xorriso; only genisoimage supports it
  if ! sudo xorriso -as mkisofs -V "$LABEL" -o "$ISO" "$BASE/config.xml" >/dev/null 2>&1; then
    echo "[WARN] xorriso failed; falling back to genisoimage"
    USE_GENISO=1
  fi
else
  USE_GENISO=1
fi

if [[ "$USE_GENISO" == "1" ]]; then
  if command -v genisoimage >/dev/null 2>&1; then
    if ! sudo genisoimage -quiet -V "$LABEL" -o "$ISO" "$BASE/config.xml" >/dev/null 2>&1; then
      echo "[FATAL] genisoimage fallback failed" >&2
      exit 32
    fi
  else
    echo "[FATAL] Neither xorriso nor genisoimage available" >&2
    exit 31
  fi
fi

echo "[OK] Generated pfSense config at $BASE/config.xml"
echo "[OK] Packaged pfSense config ISO at $ISO (label $LABEL)"
