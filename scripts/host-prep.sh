#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${COMMON_LIB}" ]]; then
  # shellcheck source=scripts/lib/common.sh
  source "${COMMON_LIB}"
else
  FALLBACK_LIB="${SCRIPT_DIR}/lib/common_fallback.sh"
  if [[ -f "${FALLBACK_LIB}" ]]; then
    # shellcheck source=scripts/lib/common_fallback.sh
    source "${FALLBACK_LIB}"
  else
    echo "Unable to locate scripts/lib/common.sh or fallback helpers" >&2
    exit 70
  fi
fi

readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_UNAVAILABLE=69
readonly EX_SOFTWARE=70
readonly EX_CONFIG=78

DRY_RUN=false
CONTEXT_ONLY=false
ENV_FILE_OVERRIDE=""

usage() {
  cat <<'USAGE'
Usage: host-prep.sh [OPTIONS]

Prepare an Ubuntu host with the dependencies required for the homelab stack.

Options:
  --env-file PATH         Load configuration overrides from PATH.
  --dry-run               Log actions without executing mutating commands.
  --context-preflight     Run non-mutating host checks and exit.
  -h, --help              Show this help message.

Exit codes:
  0  Success.
  64 Usage error (invalid CLI arguments).
  69 Missing required dependencies.
  70 Runtime failure such as download errors.
  78 Configuration error (missing environment file).
USAGE
}

format_command() {
  local formatted=""
  local arg
  for arg in "$@"; do
    if [[ -z ${formatted} ]]; then
      formatted=$(printf '%q' "$arg")
    else
      formatted+=" $(printf '%q' "$arg")"
    fi
  done
  printf '%s' "$formatted"
}

run_cmd() {
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "$@")"
    return 0
  fi
  log_debug "Executing: $(format_command "$@")"
  "$@"
}

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    log_info "Loading environment overrides from ${ENV_FILE_OVERRIDE}"
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    load_env "${ENV_FILE_OVERRIDE}" || die ${EX_CONFIG} "Failed to load ${ENV_FILE_OVERRIDE}"
    return
  fi

  local candidates=(
    "${REPO_ROOT}/.env"
    "${SCRIPT_DIR}/.env"
    "/opt/homelab/.env"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    log_debug "Checking for environment file at ${candidate}"
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  log_debug "No environment file present in default search locations"
}

declare -a APT_PACKAGES=()

gather_defaults() {
  local default_packages=(
    qemu-system-x86
    libvirt-daemon-system
    libvirt-clients
    virtinst
    virt-viewer
    bridge-utils
    genisoimage
    qemu-utils
    wget
    curl
    jq
    ca-certificates
    apt-transport-https
    gnupg
    git
    make
    unzip
    net-tools
    python3
    python3-venv
  )
  APT_PACKAGES=("${default_packages[@]}")

  if [[ -n ${HOST_PREP_EXTRA_APT_PACKAGES:-} ]]; then
    local old_ifs=${IFS}
    local extra_packages=()
    IFS=$' \t\n'
    read -r -a extra_packages <<<"${HOST_PREP_EXTRA_APT_PACKAGES}"
    IFS=${old_ifs}
    if [[ ${#extra_packages[@]} -gt 0 ]]; then
      APT_PACKAGES+=("${extra_packages[@]}")
    fi
  fi

  : "${HOST_PREP_INSTALL_DOCKER:=true}"
  : "${HOST_PREP_INSTALL_KUBECTL:=true}"
  : "${HOST_PREP_INSTALL_HELM:=true}"
  : "${HOST_PREP_INSTALL_MINIKUBE:=true}"
  : "${HOST_PREP_INSTALL_SOPS:=true}"
  : "${HOST_PREP_SOPS_URL:=https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env-file)
        if [[ $# -lt 2 ]]; then
          usage
          die ${EX_USAGE} "--env-file requires a path argument"
        fi
        ENV_FILE_OVERRIDE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --context-preflight)
        CONTEXT_ONLY=true
        shift
        ;;
      -h|--help)
        usage
        exit ${EX_OK}
        ;;
      --)
        shift
        if [[ $# -gt 0 ]]; then
          usage
          die ${EX_USAGE} "Unexpected positional arguments: $*"
        fi
        ;;
      -* )
        usage
        die ${EX_USAGE} "Unknown option: $1"
        ;;
      * )
        usage
        die ${EX_USAGE} "Positional arguments are not supported. Use -- to terminate options."
        ;;
    esac
  done
}

join_packages() {
  local joined=""
  local pkg
  for pkg in "$@"; do
    if [[ -z ${joined} ]]; then
      joined="${pkg}"
    else
      joined+=" ${pkg}"
    fi
  done
  printf '%s' "${joined}"
}

context_preflight() {
  log_info "Running host context preflight"
  need apt-get systemctl || die ${EX_UNAVAILABLE} "Required host utilities are missing"
  if [[ ${#APT_PACKAGES[@]} -gt 0 ]]; then
    log_info "APT packages requested: $(join_packages "${APT_PACKAGES[@]}")"
    local pkg
    for pkg in "${APT_PACKAGES[@]}"; do
      if dpkg -s "$pkg" >/dev/null 2>&1; then
        log_debug "Package ${pkg} already installed"
      else
        log_warn "Package ${pkg} is not yet installed"
      fi
    done
  else
    log_info "No APT packages requested"
  fi

  if command -v docker >/dev/null 2>&1; then
    log_info "Docker is already installed"
  else
    log_warn "Docker not detected"
  fi

  if command -v kubectl >/dev/null 2>&1; then
    log_info "kubectl is available"
  else
    log_warn "kubectl not detected"
  fi

  if command -v helm >/dev/null 2>&1; then
    log_info "Helm is available"
  else
    log_warn "Helm not detected"
  fi

  if command -v minikube >/dev/null 2>&1; then
    log_info "Minikube is available"
  else
    log_warn "Minikube not detected"
  fi

  if command -v sops >/dev/null 2>&1; then
    log_info "sops is available"
  else
    log_warn "sops not detected"
  fi
}

install_packages() {
  if [[ ${#APT_PACKAGES[@]} -eq 0 ]]; then
    log_info "No APT packages to install"
    return
  fi
  need apt-get || die ${EX_UNAVAILABLE} "apt-get is required"
  log_info "Installing host packages"
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${APT_PACKAGES[@]}"
}

configure_libvirt() {
  need systemctl || die ${EX_UNAVAILABLE} "systemctl is required"
  log_info "Ensuring libvirtd service is enabled"
  run_cmd systemctl enable --now libvirtd
}

install_docker() {
  if [[ ${HOST_PREP_INSTALL_DOCKER} != true ]]; then
    log_info "Skipping Docker installation per configuration"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    log_info "Docker already installed; skipping"
    return
  fi

  need curl gpg || die ${EX_UNAVAILABLE} "curl and gpg are required for Docker installation"
  log_info "Installing Docker CE from the official repository"
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 containerd runc
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get purge -y docker.io docker-doc docker-compose docker-compose-v2 containerd runc
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
  run_cmd install -m 0755 -d /etc/apt/keyrings
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  else
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi
  run_cmd chmod a+r /etc/apt/keyrings/docker.gpg
  # shellcheck disable=SC1091
  source /etc/os-release
  local repo_line="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would write Docker APT repository to /etc/apt/sources.list.d/docker.list"
  else
    printf '%s\n' "${repo_line}" >/etc/apt/sources.list.d/docker.list
  fi
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get update -y
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -- docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd systemctl enable --now docker
}

install_kubectl() {
  if [[ ${HOST_PREP_INSTALL_KUBECTL} != true ]]; then
    log_info "Skipping kubectl installation per configuration"
    return
  fi
  if command -v kubectl >/dev/null 2>&1; then
    log_info "kubectl already installed; skipping"
    return
  fi

  need curl || die ${EX_UNAVAILABLE} "curl is required to download kubectl"
  local release_url="https://storage.googleapis.com/kubernetes-release/release/stable.txt"
  local version
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would query ${release_url} for the latest kubectl version"
    return
  fi
  if ! version=$(retry 5 2 curl -fsSL "${release_url}"); then
    die ${EX_SOFTWARE} "Failed to determine the latest kubectl version"
  fi
  local kubectl_url="https://storage.googleapis.com/kubernetes-release/release/${version}/bin/linux/amd64/kubectl"
  log_info "Downloading kubectl ${version}"
  if ! retry 5 2 curl -fsSLo /usr/local/bin/kubectl "${kubectl_url}"; then
    die ${EX_SOFTWARE} "Failed to download kubectl from ${kubectl_url}"
  fi
  run_cmd chmod +x /usr/local/bin/kubectl
}

install_helm() {
  if [[ ${HOST_PREP_INSTALL_HELM} != true ]]; then
    log_info "Skipping Helm installation per configuration"
    return
  fi
  if command -v helm >/dev/null 2>&1; then
    log_info "Helm already installed; skipping"
    return
  fi

  need curl || die ${EX_UNAVAILABLE} "curl is required to install Helm"
  local installer_url="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would download and execute Helm installer from ${installer_url}"
    return
  fi
  local tmp_script
  tmp_script=$(mktemp)
  log_debug "Downloading Helm installer to ${tmp_script}"
  if ! retry 5 2 curl -fsSL "${installer_url}" -o "${tmp_script}"; then
    rm -f "${tmp_script}"
    die ${EX_SOFTWARE} "Failed to download Helm installer"
  fi
  chmod +x "${tmp_script}"
  if ! "${tmp_script}"; then
    rm -f "${tmp_script}"
    die ${EX_SOFTWARE} "Helm installer script failed"
  fi
  rm -f "${tmp_script}"
}

install_minikube() {
  if [[ ${HOST_PREP_INSTALL_MINIKUBE} != true ]]; then
    log_info "Skipping Minikube installation per configuration"
    return
  fi
  if command -v minikube >/dev/null 2>&1; then
    log_info "Minikube already installed; skipping"
    return
  fi

  need curl || die ${EX_UNAVAILABLE} "curl is required to install Minikube"
  local minikube_url="https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would download Minikube from ${minikube_url}"
    return
  fi
  if ! retry 5 2 curl -fsSLo /usr/local/bin/minikube "${minikube_url}"; then
    die ${EX_SOFTWARE} "Failed to download Minikube"
  fi
  run_cmd chmod +x /usr/local/bin/minikube
}

install_sops() {
  if [[ ${HOST_PREP_INSTALL_SOPS} != true ]]; then
    log_info "Skipping sops installation per configuration"
    return
  fi
  if command -v sops >/dev/null 2>&1; then
    log_info "sops already installed; skipping"
    return
  fi

  need curl || die ${EX_UNAVAILABLE} "curl is required to install sops"
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would download sops from ${HOST_PREP_SOPS_URL}"
    return
  fi
  if ! retry 5 2 curl -fsSLo /usr/local/bin/sops "${HOST_PREP_SOPS_URL}"; then
    die ${EX_SOFTWARE} "Failed to download sops"
  fi
  run_cmd chmod +x /usr/local/bin/sops
}

configure_helm_repos() {
  if [[ ${HOST_PREP_INSTALL_HELM} != true ]]; then
    log_debug "Helm repository configuration skipped because Helm installation is disabled"
    return
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Would ensure Helm repositories bitnami, traefik, jetstack, prometheus-community"
    return
  fi
  need helm || die ${EX_UNAVAILABLE} "Helm is required to configure repositories"
  ensure_helm_repo bitnami https://charts.bitnami.com/bitnami
  ensure_helm_repo traefik https://traefik.github.io/charts
  ensure_helm_repo jetstack https://charts.jetstack.io
  ensure_helm_repo prometheus-community https://prometheus-community.github.io/helm-charts
}

main() {
  parse_args "$@"
  load_environment
  gather_defaults

  if [[ ${CONTEXT_ONLY} == true ]]; then
    context_preflight
    return
  fi

  install_packages
  configure_libvirt
  install_docker
  install_kubectl
  install_helm
  install_minikube
  install_sops
  configure_helm_repos
  log_info "Host preparation completed"
}

main "$@"
