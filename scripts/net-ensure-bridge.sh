#!/usr/bin/env bash
set -euo pipefail

readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70

usage() {
  echo "Usage: $0 <bridge-name>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit ${EX_USAGE}
fi

bridge_name=$1

if ! command -v ip >/dev/null 2>&1; then
  echo "ip command is required" >&2
  exit ${EX_UNAVAILABLE}
fi

is_up() {
  local link=$1
  local state
  if ! state=$(ip -o link show dev "${link}" 2>/dev/null | awk '{print $9}'); then
    return 1
  fi
  [[ ${state} == "UP" ]]
}

if ! ip link show dev "${bridge_name}" >/dev/null 2>&1; then
  echo "Creating bridge ${bridge_name}"
  sudo ip link add name "${bridge_name}" type bridge
fi

if ! is_up "${bridge_name}"; then
  echo "Bringing up bridge ${bridge_name}"
  sudo ip link set dev "${bridge_name}" up
fi

if ! is_up "${bridge_name}"; then
  echo "Bridge ${bridge_name} is not up" >&2
  exit ${EX_SOFTWARE}
fi
