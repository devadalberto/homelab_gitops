#!/usr/bin/env bash
set -euo pipefail
log(){ printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }

apt-get update -y
apt-get install -y qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst virt-viewer \
  bridge-utils genisoimage qemu-utils wget curl jq ca-certificates apt-transport-https gnupg \
  git make unzip net-tools python3 python3-venv

systemctl enable --now libvirtd

# Docker CE from Docker Inc. repo only if docker not present
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker CE (official repo)"
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 containerd runc || true
  apt-get purge  -y docker.io docker-doc docker-compose docker-compose-v2 containerd runc || true
  apt-get autoremove -y || true
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

# kubectl
if ! command -v kubectl >/dev/null 2>&1; then
  curl -fsSLo /usr/local/bin/kubectl https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
  chmod +x /usr/local/bin/kubectl
fi
# helm
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
# minikube
if ! command -v minikube >/dev/null 2>&1; then
  curl -fsSLo /usr/local/bin/minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
  chmod +x /usr/local/bin/minikube
fi
# sops
if ! command -v sops >/dev/null 2>&1; then
  SOPS_URL="https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64"
  curl -fsSLo /usr/local/bin/sops "${SOPS_URL}"
  chmod +x /usr/local/bin/sops
fi

# Helm repos
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null 2>&1 || true
