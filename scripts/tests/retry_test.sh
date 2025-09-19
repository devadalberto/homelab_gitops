#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

check_retry_failure() {
  local lib_path=$1
  (
    set -euo pipefail
    # shellcheck source=/dev/null
    source "${lib_path}"
    if retry 1 0 false; then
      echo "retry from ${lib_path} succeeded unexpectedly" >&2
      exit 1
    fi
  )
}

check_retry_failure "${REPO_ROOT}/scripts/lib/common.sh"
check_retry_failure "${REPO_ROOT}/scripts/lib/common_fallback.sh"

echo "retry failure regression tests passed"
