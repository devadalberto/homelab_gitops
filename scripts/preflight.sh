#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: preflight.sh [--env-file PATH]

Ensure required environment defaults are present and verify host dependencies.

Options:
  --env-file PATH  Path to the environment file to validate (default: ./.env).
  -h, --help       Show this help message and exit.
USAGE
}

log() {
  local level=${1:-INFO}
  shift || true
  local message="$*"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s [%5s] %s\n' "$ts" "${level^^}" "$message" >&2
}

log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }

fatal() {
  local status=${1:-1}
  shift || true
  if [[ $# -gt 0 ]]; then
    log_error "$*"
  fi
  exit "$status"
}

run_privileged() {
  if [[ $(id -u) -eq 0 ]]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  fatal 1 "Command requires elevated privileges: $*"
}

APT_UPDATED=0
apt_update_if_needed() {
  if [[ ${APT_UPDATED} -eq 0 ]]; then
    log_info "Updating apt package index"
    run_privileged apt-get update
    APT_UPDATED=1
  fi
}

ensure_file() {
  local path=$1
  if [[ -f ${path} ]]; then
    return
  fi
  local dir
  dir=$(dirname "${path}")
  if [[ ! -d ${dir} ]]; then
    if mkdir -p "${dir}" 2>/dev/null; then
      log_info "Created directory ${dir}"
    else
      log_info "Creating directory ${dir} with elevated privileges"
      run_privileged mkdir -p "${dir}"
    fi
  fi
  if touch "${path}" 2>/dev/null; then
    log_info "Created environment file at ${path}"
  else
    log_info "Creating environment file at ${path} with elevated privileges"
    run_privileged touch "${path}"
  fi
}

REQUIRED_ENV_DEFAULTS=(
  "LABZ_DOMAIN=labz.home.arpa"
  "LAB_DOMAIN_BASE=labz.home.arpa"
  "LABZ_TRAEFIK_HOST=traefik.labz.home.arpa"
  "LABZ_NEXTCLOUD_HOST=cloud.labz.home.arpa"
  "LABZ_JELLYFIN_HOST=media.labz.home.arpa"
  "LABZ_MOUNT_BACKUPS=/srv/backups"
  "LABZ_MOUNT_MEDIA=/srv/media"
  "LABZ_MOUNT_NEXTCLOUD=/srv/nextcloud"
  "LABZ_MINIKUBE_PROFILE=labz"
  "LABZ_MINIKUBE_CPUS=4"
  "LABZ_MINIKUBE_MEMORY=12288"
  "LABZ_MINIKUBE_DISK=80g"
  "LABZ_MINIKUBE_DRIVER=docker"
  "LABZ_MINIKUBE_EXTRA_ARGS="
  "LABZ_METALLB_RANGE=10.10.0.240-10.10.0.250"
  "METALLB_POOL_START=10.10.0.240"
  "METALLB_POOL_END=10.10.0.250"
  "METALLB_HELM_VERSION=0.14.7"
  "TRAEFIK_HELM_VERSION=27.0.2"
  "CERT_MANAGER_HELM_VERSION=1.16.3"
  "LABZ_KUBERNETES_VERSION=v1.31.3"
  "LABZ_POSTGRES_HELM_VERSION=16.2.6"
  "LABZ_KPS_HELM_VERSION=65.5.0"
  "LABZ_POSTGRES_DB=nextcloud"
  "LABZ_POSTGRES_USER=nextcloud"
  "LABZ_POSTGRES_PASSWORD=change-me"
  "LABZ_REDIS_PASSWORD=change-me"
  "LABZ_PHP_UPLOAD_LIMIT=2G"
  "WAN_NIC=eno1"
  "WAN_MODE=br0"
  "PF_VM_NAME=pfsense-uranus"
  "PF_LAN_BRIDGE="
  "PF_WAN_BRIDGE=br0"
  "PF_LAN_LINK=bridge:virbr-lan"
  "PF_FORCE_E1000=false"
  "PF_INSTALLER_SRC=/home/saitama/downloads/netgate-installer-amd64.img"
  "PF_SERIAL_INSTALLER_PATH="
  "LAB_CLUSTER_SUB=lab-minikube.labz.home.arpa"
  "TRAEFIK_LOCAL_IP=10.10.0.240"
  "WORK_ROOT=/opt/homelab"
  "PG_BACKUP_HOSTPATH=/opt/homelab/backups"
  "PG_STORAGE_SIZE=10Gi"
  "AWX_ADMIN_USER=admin"
  "DJ_IMAGE=djangomultiproject:latest"
  "VM_NAME=pfsense-uranus"
  "VCPUS=2"
  "RAM_MB=4096"
  "DISK_SIZE_GB=20"
  "LAN_CIDR=10.10.0.0/24"
  "LAN_GW_IP=10.10.0.1"
  "LAN_DHCP_FROM=10.10.0.100"
  "LAN_DHCP_TO=10.10.0.200"
  "DHCP_FROM=10.10.0.100"
  "DHCP_TO=10.10.0.200"
)

enforce_env_defaults() {
  local env_file=$1
  ensure_file "${env_file}"

  local added=0
  local entry key value
  for entry in "${REQUIRED_ENV_DEFAULTS[@]}"; do
    key=${entry%%=*}
    value=${entry#*=}
    if grep -Eq "^[[:space:]]*${key}=" "${env_file}"; then
      continue
    fi
    log_info "Setting default for ${key}"
    if printf '%s=%s\n' "${key}" "${value}" >>"${env_file}" 2>/dev/null; then
      :
    else
      printf '%s=%s\n' "${key}" "${value}" | run_privileged tee -a "${env_file}" >/dev/null
    fi
    added=1
  done

  if [[ ${added} -eq 0 ]]; then
    log_info "Environment file already defines all required keys"
  fi
}

print_effective_configuration() {
  local env_file=$1
  log_info "Effective configuration from ${env_file}:"
  local entry key line
  for entry in "${REQUIRED_ENV_DEFAULTS[@]}"; do
    key=${entry%%=*}
    if line=$(grep -E "^[[:space:]]*${key}=" "${env_file}" | tail -n 1); then
      line=$(printf '%s\n' "${line}" | sed 's/^[[:space:]]*//')
      printf '%s\n' "${line}"
    fi
  done
}

APT_PACKAGES=(
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

ensure_apt_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    log_warn "apt-get not available; skipping package installation"
    return
  fi

  local missing=()
  local pkg
  for pkg in "${APT_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "Required apt packages already installed"
    return
  fi

  log_info "Installing missing apt packages: ${missing[*]}"
  apt_update_if_needed
  run_privileged apt-get install -y "${missing[@]}"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log_info "Docker already installed"
    return
  fi

  log_warn "Docker not detected; installation will modify system packages and may require a re-login for group membership"
  apt_update_if_needed
  run_privileged apt-get install -y docker.io

  local user=${SUDO_USER:-${USER:-}}
  if [[ -n ${user} && ${user} != "root" ]]; then
    if command -v id >/dev/null 2>&1 && command -v usermod >/dev/null 2>&1; then
      if ! id -nG "${user}" | tr ' ' '\n' | grep -Fxq docker; then
        log_info "Adding ${user} to docker group"
        run_privileged usermod -aG docker "${user}"
        log_warn "User ${user} added to docker group. Log out and back in to apply membership."
      fi
    fi
  fi
}

install_binary() {
  local tmp
  tmp=$(mktemp)
  curl -fsSL "$1" -o "${tmp}"
  run_privileged install -m 0755 "${tmp}" "$2"
  rm -f "${tmp}"
}

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log_info "kubectl already installed"
    return
  fi

  local version=${KUBECTL_VERSION:-}
  if [[ -z ${version} ]]; then
    log_info "Fetching latest kubectl version"
    version=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  fi
  log_info "Installing kubectl ${version}"
  install_binary "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl" /usr/local/bin/kubectl
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    log_info "Helm already installed"
    return
  fi

  local version=${HELM_VERSION:-v3.15.2}
  local tmpdir
  tmpdir=$(mktemp -d)
  local archive="${tmpdir}/helm.tgz"
  log_info "Installing Helm ${version}"
  curl -fsSL "https://get.helm.sh/helm-${version}-linux-amd64.tar.gz" -o "${archive}"
  tar -xzf "${archive}" -C "${tmpdir}"
  run_privileged install -m 0755 "${tmpdir}/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "${tmpdir}"
}

ensure_minikube() {
  if command -v minikube >/dev/null 2>&1; then
    log_info "Minikube already installed"
    return
  fi

  local version=${MINIKUBE_VERSION:-latest}
  local url
  if [[ ${version} == "latest" ]]; then
    url="https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
  else
    url="https://storage.googleapis.com/minikube/releases/${version}/minikube-linux-amd64"
  fi
  log_info "Installing Minikube ${version}"
  install_binary "${url}" /usr/local/bin/minikube
}

main() {
  local env_file="./.env"
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --env-file)
      if [[ $# -lt 2 ]]; then
        usage
        fatal 64 "--env-file requires a path"
      fi
      env_file="$2"
      shift 2
      ;;
    --env-file=*)
      env_file="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      fatal 64 "Unknown option: $1"
      ;;
    *)
      usage
      fatal 64 "Unexpected positional argument: $1"
      ;;
    esac
  done

  enforce_env_defaults "${env_file}"
  print_effective_configuration "${env_file}"

  ensure_apt_packages
  ensure_docker
  ensure_kubectl
  ensure_helm
  ensure_minikube

  log_info "Preflight checks complete"
}

main "$@"
