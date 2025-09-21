#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'kubectl is required but was not found in PATH\n' >&2
  exit 127
fi

# Determine the desired kubectl context. Prefer the LABZ_MINIKUBE_PROFILE
# environment variable when it is populated, otherwise fall back to the
# traditional "minikube" context name.
desired_context="${LABZ_MINIKUBE_PROFILE:-}"
if [[ -z "${desired_context}" ]]; then
  desired_context="minikube"
  printf 'LABZ_MINIKUBE_PROFILE not set; defaulting to "%s"\n' "${desired_context}" >&2
fi

# Changing kubectl contexts immediately after starting minikube can fail while
# the kubeconfig entry is still being created. Retry a few times before giving
# up so that the script keeps running under set -euo pipefail.
max_attempts=5
sleep_seconds=2
attempt=1
context_switched=false
while (( attempt <= max_attempts )); do
  if kubectl config use-context "${desired_context}" >/dev/null 2>&1; then
    printf 'Switched kubectl context to "%s"\n' "${desired_context}" >&2
    context_switched=true
    break
  fi

  if ! kubectl config get-contexts "${desired_context}" >/dev/null 2>&1; then
    printf 'kubectl context "%s" not available yet (attempt %d/%d); retrying...\n' \
      "${desired_context}" "${attempt}" "${max_attempts}" >&2
  else
    printf 'Failed to switch kubectl context to "%s" (attempt %d/%d); retrying...\n' \
      "${desired_context}" "${attempt}" "${max_attempts}" >&2
  fi

  sleep "${sleep_seconds}"
  ((attempt++))
done

if [[ ${context_switched} == false ]]; then
  current_context="unknown"
  if current_context=$(kubectl config current-context 2>/dev/null); then
    :
  fi
  printf 'Warning: unable to switch kubectl context to "%s"; continuing with "%s"\n' \
    "${desired_context}" "${current_context}" >&2
fi
