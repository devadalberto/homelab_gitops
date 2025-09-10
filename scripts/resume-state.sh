#!/usr/bin/env bash
set -euo pipefail
STATE="/root/.uranus_bootstrap_state"
[[ -f "$STATE" ]] && cat "$STATE" || echo "start"
