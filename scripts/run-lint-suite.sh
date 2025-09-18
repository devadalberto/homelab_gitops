#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib/common.sh"

need git shellcheck yamllint kubeconform kustomize

log_info "Running ShellCheck across repository scripts"
mapfile -t shell_scripts < <(cd "${REPO_ROOT}" && git ls-files '*.sh')
if [[ "${#shell_scripts[@]}" -gt 0 ]]; then
  (cd "${REPO_ROOT}" && shellcheck --format=tty "${shell_scripts[@]}")
else
  log_info "No shell scripts found"
fi

log_info "Running yamllint against Kubernetes manifests"
yamllint -c "${REPO_ROOT}/.yamllint.yaml" \
  "${REPO_ROOT}/apps" \
  "${REPO_ROOT}/clusters" \
  "${REPO_ROOT}/data" \
  "${REPO_ROOT}/flux" \
  "${REPO_ROOT}/infra" \
  "${REPO_ROOT}/k8s" \
  "${REPO_ROOT}/observability"

log_info "Rendering manifests with kustomize for kubeconform"
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

mapfile -t kustomizations < <(cd "${REPO_ROOT}" && find clusters k8s -name kustomization.yaml -print | sort)
if [[ "${#kustomizations[@]}" -eq 0 ]]; then
  log_error "No kustomization.yaml files found"
  exit 1
fi

for kustomization in "${kustomizations[@]}"; do
  dir=$(dirname "${kustomization}")
  rel=${dir#./}
  safe_name=$(echo "${rel}" | tr '/._' '-' | tr '[:upper:]' '[:lower:]')
  log_debug "Building ${rel}"
  (cd "${REPO_ROOT}" && kustomize build "${dir}") > "${tmpdir}/${safe_name}.yaml"
done

log_info "Validating rendered manifests with kubeconform"
kubeconform -strict -ignore-missing-schemas -skip CustomResourceDefinition -summary "${tmpdir}"/*.yaml
