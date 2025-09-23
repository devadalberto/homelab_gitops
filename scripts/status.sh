#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: status.sh [--env-file PATH]

Summarize the repository, environment, and cluster state for the homelab stack.

Options:
  --env-file PATH  Path to the environment file to load (default: value of $ENV_FILE or ./.env).
  -h, --help       Show this help message and exit.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE_PATH="${ENV_FILE:-./.env}"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --env-file)
    shift || true
    if [[ $# -eq 0 ]]; then
      printf 'Missing value for --env-file option.\n' >&2
      usage >&2
      exit 64
    fi
    ENV_FILE_PATH="$1"
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    printf 'Unknown argument: %s\n' "$1" >&2
    usage >&2
    exit 64
    ;;
  esac
  shift || true
done

cd "${REPO_ROOT}"

if [[ ${ENV_FILE_PATH:-} == ~* ]]; then
  ENV_FILE_PATH="${HOME}${ENV_FILE_PATH:1}"
elif [[ ${ENV_FILE_PATH:-} != /* ]]; then
  ENV_FILE_PATH="${REPO_ROOT}/${ENV_FILE_PATH#./}"
fi

ENV_FILE_STATUS="missing"
if [[ -f ${ENV_FILE_PATH} ]]; then
  set -a
  # shellcheck disable=SC1090
  if source "${ENV_FILE_PATH}" 2>/dev/null; then
    ENV_FILE_STATUS="loaded"
  else
    printf '[WARN] Failed to load environment file: %s\n' "${ENV_FILE_PATH}" >&2
    ENV_FILE_STATUS="error"
  fi
  set +a || true
else
  printf '[WARN] Environment file not found: %s\n' "${ENV_FILE_PATH}" >&2
fi

section() {
  local title="$1"
  printf '\n=== %s ===\n' "${title}"
}

print_env_value() {
  local key="$1"
  local value
  if [[ ${!key+x} ]]; then
    value="${!key}"
    if [[ -z ${value} ]]; then
      value='<empty>'
    fi
  else
    value='<unset>'
  fi
  printf '  %-28s %s\n' "${key}:" "${value}"
}

collect_phony_targets() {
  local makefile="$1"
  local -n out_ref=$2
  out_ref=()
  if [[ ! -f ${makefile} ]]; then
    return
  fi
  local line
  local current=""
  while IFS= read -r line || [[ -n ${line} ]]; do
    if [[ ${line} == .PHONY:* ]]; then
      current=${line#*.PHONY:}
      while [[ ${current} == *\\ ]]; do
        current=${current%\\}
        local continuation
        IFS= read -r continuation || true
        current+=" ${continuation}"
      done
      local entry
      for entry in ${current}; do
        if [[ -n ${entry} ]]; then
          out_ref+=("${entry}")
        fi
      done
    fi
  done <"${makefile}"
  if [[ ${#out_ref[@]} -eq 0 ]]; then
    return
  fi
  local -A seen=()
  local unique=()
  local item
  for item in "${out_ref[@]}"; do
    if [[ -z ${seen[${item}]:-} ]]; then
      seen[${item}]=1
      unique+=("${item}")
    fi
  done
  out_ref=()
  if command -v sort >/dev/null 2>&1; then
    local sorted
    sorted=$(printf '%s\n' "${unique[@]}" | sort 2>/dev/null || true)
    if [[ -n ${sorted} ]]; then
      while IFS= read -r item; do
        [[ -n ${item} ]] || continue
        out_ref+=("${item}")
      done <<<"${sorted}"
      return
    fi
  fi
  out_ref=("${unique[@]}")
}

make_has_target() {
  local target="$1"
  local makefile="${REPO_ROOT}/Makefile"
  if [[ ! -f ${makefile} ]]; then
    return 1
  fi
  local targets
  collect_phony_targets "${makefile}" targets
  local item
  for item in "${targets[@]}"; do
    if [[ ${item} == "${target}" ]]; then
      return 0
    fi
  done
  if command -v grep >/dev/null 2>&1 && grep -Eq "^${target}:" "${makefile}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

run_command() {
  local label="$1"
  shift || true
  if [[ $# -eq 0 ]]; then
    printf '  %s: no command provided\n' "${label}"
    return
  fi
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf '  %s: %s not found\n' "${label}" "${cmd}"
    return
  fi
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -z ${formatted} ]]; then
      formatted=$(printf '%q' "${arg}")
    else
      formatted+=" $(printf '%q' "${arg}")"
    fi
  done
  printf '  %s ($ %s)\n' "${label}" "${formatted}"
  "$@" || true
}

print_git_summary() {
  section "Git status"
  if command -v git >/dev/null 2>&1; then
    run_command "Status" git -C "${REPO_ROOT}" status --short --branch
    run_command "Recent commit" git -C "${REPO_ROOT}" log -1 --oneline
  else
    printf '  git command not available.\n'
  fi
}

print_env_summary() {
  section "Environment summary"
  printf '  Environment file: %s (%s)\n' "${ENV_FILE_PATH}" "${ENV_FILE_STATUS}"
  local -a keys=(
    LABZ_DOMAIN
    LABZ_TRAEFIK_HOST
    LABZ_NEXTCLOUD_HOST
    LABZ_JELLYFIN_HOST
    LABZ_METALLB_RANGE
    TRAEFIK_LOCAL_IP
    LABZ_MINIKUBE_PROFILE
    LABZ_MINIKUBE_DRIVER
    LABZ_MINIKUBE_CPUS
    LABZ_MINIKUBE_MEMORY
    LABZ_MINIKUBE_DISK
    LABZ_KUBERNETES_VERSION
    LABZ_POSTGRES_DB
    LABZ_POSTGRES_USER
    LABZ_PHP_UPLOAD_LIMIT
    LABZ_MOUNT_BACKUPS
    LABZ_MOUNT_MEDIA
    LABZ_MOUNT_NEXTCLOUD
    PG_STORAGE_SIZE
  )
  local key
  for key in "${keys[@]}"; do
    print_env_value "${key}"
  done
}

print_make_targets() {
  section "Make targets"
  local makefile="${REPO_ROOT}/Makefile"
  if [[ ! -f ${makefile} ]]; then
    printf '  Makefile not found at %s\n' "${makefile}"
    return
  fi
  local targets
  collect_phony_targets "${makefile}" targets
  if [[ ${#targets[@]} -eq 0 ]]; then
    printf '  No .PHONY targets declared.\n'
    return
  fi
  local target
  for target in "${targets[@]}"; do
    printf '  - %s\n' "${target}"
  done
}

run_make_doctor() {
  section "Doctor checks"
  if ! command -v make >/dev/null 2>&1; then
    printf '  make command not available.\n'
    return
  fi
  if make_has_target "doctor"; then
    printf '  Running make doctor...\n'
    make doctor || true
  else
    printf '  No doctor target defined in Makefile.\n'
  fi
}

print_minikube_info() {
  section "Minikube diagnostics"
  if ! command -v minikube >/dev/null 2>&1; then
    printf '  minikube command not available.\n'
    return
  fi
  local profile="${LABZ_MINIKUBE_PROFILE:-minikube}"
  run_command "Profile list" minikube profile list
  run_command "Status (${profile})" minikube status -p "${profile}"
  run_command "Addons" minikube addons list
}

print_kubectl_info() {
  section "kubectl diagnostics"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl command not available.\n'
    return
  fi
  run_command "Version" kubectl version --short
  run_command "Current context" kubectl config current-context
  run_command "Nodes" kubectl get nodes -o wide
  run_command "Namespaces" kubectl get namespaces
  run_command "All pods" kubectl get pods --all-namespaces
}

print_flux_info() {
  section "Flux status"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl command not available.\n'
    return
  fi
  if kubectl get namespace flux-system >/dev/null 2>&1; then
    run_command "GitRepositories" kubectl -n flux-system get gitrepositories.source.toolkit.fluxcd.io
    run_command "Kustomizations" kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io
    run_command "HelmRepositories" kubectl -n flux-system get helmrepositories.source.toolkit.fluxcd.io
    run_command "HelmReleases" kubectl -n flux-system get helmreleases.helm.toolkit.fluxcd.io
    if command -v flux >/dev/null 2>&1; then
      run_command "Flux check" flux check --pre
      run_command "Flux CLI kustomizations" flux get kustomizations --all-namespaces
      run_command "Flux CLI hr" flux get helmreleases --all-namespaces
    fi
  else
    printf '  Namespace flux-system not present.\n'
  fi
}

print_metallb_traefik_info() {
  section "MetalLB and Traefik"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl command not available.\n'
    return
  fi
  if kubectl get namespace metallb-system >/dev/null 2>&1; then
    run_command "MetalLB pods" kubectl -n metallb-system get pods
    run_command "IPAddressPools" kubectl -n metallb-system get ipaddresspools.metallb.io
    run_command "L2Advertisements" kubectl -n metallb-system get l2advertisements.metallb.io
  else
    printf '  Namespace metallb-system not present.\n'
  fi
  if kubectl get namespace traefik-system >/dev/null 2>&1; then
    run_command "Traefik pods" kubectl -n traefik-system get pods
    run_command "Traefik services" kubectl -n traefik-system get services
  else
    printf '  Namespace traefik-system not present.\n'
  fi
}

print_observability_info() {
  section "Observability"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl command not available.\n'
    return
  fi
  if kubectl get namespace observability >/dev/null 2>&1; then
    run_command "Pods" kubectl -n observability get pods
    run_command "Services" kubectl -n observability get services
  else
    printf '  Namespace observability not present.\n'
  fi
}

print_app_namespaces() {
  section "Application namespaces"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl command not available.\n'
    return
  fi
  local -a namespaces=(
    data
    nextcloud
    jellyfin
    awx
    apps
    homepage
    bitwarden
    pihole
  )
  local ns
  for ns in "${namespaces[@]}"; do
    printf '  Namespace: %s\n' "${ns}"
    if kubectl get namespace "${ns}" >/dev/null 2>&1; then
      run_command "    Pods" kubectl -n "${ns}" get pods
      run_command "    Services" kubectl -n "${ns}" get services
      run_command "    Ingress" kubectl -n "${ns}" get ingress
    else
      printf '    Namespace %s not present.\n' "${ns}"
    fi
  done
}

print_storage_info() {
  section "Storage"
  if ! command -v kubectl >/dev/null 2>&1; then
    printf '  kubectl command not available.\n'
    return
  fi
  run_command "StorageClasses" kubectl get storageclass
  run_command "PersistentVolumes" kubectl get pv
  run_command "PersistentVolumeClaims" kubectl get pvc --all-namespaces
}

print_host_overrides() {
  section "Traefik load-balancer host overrides"
  local lb_ip="${TRAEFIK_LOCAL_IP:-}";
  if [[ -z ${lb_ip} && ${LABZ_TRAEFIK_HOST:-} ]]; then
    lb_ip="${LABZ_TRAEFIK_IP:-}"
  fi
  if [[ -z ${lb_ip} ]]; then
    printf '  Traefik load-balancer IP is not set (TRAEFIK_LOCAL_IP).\n'
  else
    printf '  Load-balancer IP: %s\n' "${lb_ip}"
  fi
  local -a hosts=()
  if [[ -n ${LABZ_TRAEFIK_HOST:-} ]]; then hosts+=("${LABZ_TRAEFIK_HOST}"); fi
  if [[ -n ${LABZ_NEXTCLOUD_HOST:-} ]]; then hosts+=("${LABZ_NEXTCLOUD_HOST}"); fi
  if [[ -n ${LABZ_JELLYFIN_HOST:-} ]]; then hosts+=("${LABZ_JELLYFIN_HOST}"); fi
  if [[ ${#hosts[@]} -gt 0 ]]; then
    printf '  Map the following hostnames to the load-balancer IP:\n'
    local host
    for host in "${hosts[@]}"; do
      printf '    - %s\n' "${host}"
    done
  else
    printf '  No ingress hostnames defined in the environment file.\n'
  fi
  if [[ -n ${LABZ_METALLB_RANGE:-} ]]; then
    printf '  MetalLB address pool: %s\n' "${LABZ_METALLB_RANGE}"
  fi
}

print_next_steps() {
  section "What to run next"
  cat <<'GUIDANCE'
  1. make up        – Rebuild the Minikube cluster and deploy the Flux-managed applications.
  2. make status    – Re-run this probe after changes to confirm MetalLB, Traefik, and application endpoints.
  3. Update DNS or /etc/hosts so the published ingress hostnames resolve to the Traefik load-balancer IP.
GUIDANCE
}

print_git_summary
print_env_summary
print_make_targets
run_make_doctor
print_minikube_info
print_kubectl_info
print_flux_info
print_metallb_traefik_info
print_observability_info
print_app_namespaces
print_storage_info
print_host_overrides
print_next_steps

exit 0
