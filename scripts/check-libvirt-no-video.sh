#!/usr/bin/env bash
set -euo pipefail

# Verify that libvirt domain definitions do not include <video> devices.
# The hook inspects XML files provided by pre-commit (or falls back to
# tracked XML manifests) and exits non-zero when a video device is found.

mapfile -t files < <(
  if [[ $# -gt 0 ]]; then
    for target in "$@"; do
      if [[ -f "${target}" ]]; then
        printf '%s\n' "${target}"
      fi
    done
  else
    git ls-files '*.xml'
  fi
)

status=0
for file in "${files[@]}"; do
  # Skip files that are not libvirt domains.
  if ! grep -qi "<domain[^>]*type" "${file}" 2>/dev/null; then
    continue
  fi

  if matches=$(grep -nE '\<video\b' "${file}" 2>/dev/null); then
    printf 'ERROR: %s contains libvirt <video> devices. Remove them for headless guests.\n' "${file}" >&2
    printf '%s\n' "${matches}" >&2
    status=1
  fi
done

exit "${status}"
