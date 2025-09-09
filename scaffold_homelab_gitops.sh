#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_VERSION="0.8.2 (2025-09-08)"

# Homelab GitOps Scaffold (Flux + Helm + SOPS + mkcert + MetalLB + Apps)
# Target: Ubuntu noble (24.04) with Minikube (docker driver)
# Features: Pi-hole, Nextcloud (Postgres), Jellyfin, Bitwarden scaffold, Homepage, AWX
# Secrets: SOPS+age; Image automation; Renovate PRs for charts
# This version wires README.md auto-generation and fixes sops installation fallbacks
# SCRIPT_VERSION=0.8.2 (2025-09-08)

trap 'echo "[ERROR] Failed at line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*"; }
die() { echo "[FATAL] $*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }
aptget() { sudo DEBIAN_FRONTEND=noninteractive apt-get -yq install "$@"; }

# --- ensure_sops function ---
ensure_sops() {
  if command -v sops >/dev/null 2>&1; then
    log "sops present: $(sops --version || true)"
    return 0
  fi
  log "Installing sops (apt, then snap, then brew, then GitHub asset)"

  # 1) apt (universe)
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -yq || true
    if sudo apt-get -yq install sops 2>/dev/null; then
      log "sops installed via apt"
      return 0
    else
      log "sops not available via apt (or failed)."
    fi
  fi

  # 2) snap
  if command -v snap >/dev/null 2>&1; then
    if sudo snap install sops --classic 2>/dev/null; then
      # snap puts it at /snap/bin/sops; ensure in PATH
      if ! command -v sops >/dev/null 2>&1 && [ -x /snap/bin/sops ]; then
        sudo ln -sf /snap/bin/sops /usr/local/bin/sops || true
      fi
      if command -v sops >/dev/null 2>&1; then
        log "sops installed via snap"
        return 0
      fi
    fi
    log "sops via snap failed."
  fi

  # 3) brew (linuxbrew)
  if command -v brew >/dev/null 2>&1; then
    if brew install sops; then
      log "sops installed via brew"
      return 0
    fi
    log "sops via brew failed."
  fi

  # 4) GitHub release (no jq dependency)
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  api_url="https://api.github.com/repos/getsops/sops/releases/latest"
  log "Fetching latest sops release metadata from GitHub API"
  dl_url="$(curl -fsSL "$api_url" \
    | grep -Eo '"browser_download_url":\s*"[^"]+' \
    | cut -d'"' -f4 \
    | grep -E 'linux_amd64\.tar\.gz$' \
    | head -n1 || true)"
  if [ -z "${dl_url:-}" ]; then
    die "Unable to determine sops download URL from GitHub API."
  fi
  log "Downloading: $dl_url"
  curl -fsSL "$dl_url" -o "$tmp/sops.tar.gz"
  tar -xzf "$tmp/sops.tar.gz" -C "$tmp"
  if [ ! -f "$tmp/sops" ]; then
    # some releases package under a folder
    bin_path="$(find "$tmp" -maxdepth 2 -type f -name sops | head -n1 || true)"
    [ -n "$bin_path" ] || die "sops binary not found within tarball."
    mv "$bin_path" "$tmp/sops"
  fi
  chmod +x "$tmp/sops"
  sudo mv "$tmp/sops" /usr/local/bin/sops
  if ! command -v sops >/dev/null 2>&1; then
    die "sops installation failed (all strategies)."
  fi
  log "sops installed via GitHub asset: $(sops --version || true)"
}

ensure_mkcert() {
  if command -v mkcert >/dev/null 2>&1; then
    log "mkcert present"
    return 0
  fi
  log "Installing mkcert"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -yq || true
    sudo apt-get -yq install mkcert libnss3-tools || die "Failed to install mkcert"
  else
    die "mkcert install path missing (no apt). Install mkcert manually."
  fi
}

ensure_flux() {
  if command -v flux >/dev/null 2>&1; then
    log "flux present"
    return 0
  fi
  log "Installing flux via curl"
  curl -s https://fluxcd.io/install.sh | sudo bash
  require flux
}

ensure_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl present"
    return 0
  fi
  log "Installing kubectl"
  if command -v snap >/dev/null 2>&1; then
    sudo snap install kubectl --classic || true
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    curl -fsSLo /tmp/kubectl "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
  fi
  require kubectl
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    log "helm present"
    return 0
  fi
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  require helm
}

ensure_age() {
  if command -v age >/dev/null 2>&1 && command -v age-keygen >/dev/null 2>&1; then
    log "age present"
    return 0
  fi
  log "Installing age"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -yq || true
    sudo apt-get -yq install age || die "Failed to install age"
  else
    die "age install path missing (no apt). Install age manually."
  fi
}

ensure_minikube() {
  if command -v minikube >/dev/null 2>&1; then
    log "minikube present"
    return 0
  fi
  log "Installing minikube"
  curl -fsSL https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 -o /tmp/minikube
  chmod +x /tmp/minikube
  sudo mv /tmp/minikube /usr/local/bin/minikube
  require minikube
}

start_minikube() {
  if ! minikube status --output=json >/dev/null 2>&1; then
    log "Starting minikube (docker driver)"
    minikube start --driver=docker --kubernetes-version=stable
  else
    log "Minikube already running"
  fi
  # use minikube's docker env for local builds if needed
  # eval "$(minikube docker-env)"
}

scaffold_repo() {
  log "Scaffolding GitOps repo structure (idempotent)"
  mkdir -p infra/{ansible,bootstrap,docs}
  mkdir -p k8s/{namespaces,base,apps,infra,addons}
  mkdir -p k8s/addons/{metallb,traefik,cert-manager,awx-operator}
  mkdir -p k8s/apps/{pihole,nextcloud,jellyfin,bitwarden,homepage}
  mkdir -p clusters/minikube
  mkdir -p .sops
  mkdir -p scripts

  # flux kustomization placeholders
  cat > k8s/base/kustomization.yaml <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../addons/metallb
  - ../addons/traefik
  - ../addons/cert-manager
  - ../addons/awx-operator
  - ../apps/pihole
  - ../apps/nextcloud
  - ../apps/jellyfin
  - ../apps/bitwarden
  - ../apps/homepage
YAML

  # MetalLB placeholder
  cat > k8s/addons/metallb/kustomization.yaml <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML

  # Traefik placeholder
  cat > k8s/addons/traefik/kustomization.yaml <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML

  # cert-manager placeholder
  cat > k8s/addons/cert-manager/kustomization.yaml <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML

  # AWX operator placeholder
  cat > k8s/addons/awx-operator/kustomization.yaml <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML

  # README auto-gen script (simple)
  cat > scripts/generate_readme.sh <<'RS'
#!/usr/bin/env bash
set -euo pipefail
out="README.md"
cat > "$out" <<MD
# Homelab GitOps

- Flux + Helm + SOPS + age
- Addons: MetalLB, Traefik, cert-manager, AWX Operator
- Apps: Pi-hole, Nextcloud(Postgres), Jellyfin, Bitwarden, Homepage

## Tree
\`\`\`
$(find . -maxdepth 3 -type d | sed 's|^\./||' | sort)
\`\`\`

## How to run
1) Ensure minikube is running:
   \`\`\`bash
   minikube start --driver=docker
   \`\`\`

2) Bootstrap Flux (after you set your git remote):
   \`\`\`bash
   flux check --pre
   # Example (adjust your repo):
   # flux bootstrap github --owner <you> --repository homelab_gitops --path clusters/minikube
   \`\`\`

## Secrets with SOPS (age)
- Keys in: .sops/age.key
- Example to encrypt:
  \`\`\`bash
  sops --encrypt --in-place k8s/apps/nextcloud/values.yaml
  \`\`\`
MD
echo "[OK] Wrote README.md"
RS
  chmod +x scripts/generate_readme.sh
}

init_certs() {
  log "Initializing local CA with mkcert (if not present)"
  if [ ! -d "${HOME}/.local/share/mkcert" ]; then
    mkcert -install || true
  fi
}

init_age_keys() {
  if [ -f .sops/age.key ]; then
    log "age key exists (.sops/age.key)"
    return 0
  fi
  log "Generating age key"
  umask 077
  age-keygen -o .sops/age.key
  pub=$(grep -E '^public-key:' .sops/age.key | awk '{print $2}')
  log "AGE public key: $pub"
  cat > .sops/.sops.yaml <<YAML
creation_rules:
  - path_regex: .*
    age: ["$pub"]
YAML
  log "Wrote .sops/.sops.yaml"
}

write_flux_notes() {
  mkdir -p infra/docs
  cat > infra/docs/BOOTSTRAP_NOTES.md <<'MD'
# Flux Bootstrap Notes

1. Ensure kubectl context points to minikube:
   kubectl config use-context minikube

2. Verify cluster:
   kubectl get nodes -o wide

3. Flux install (option A - manual):
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux check --pre

4. Flux bootstrap (example with GitHub):
   flux bootstrap github \
     --owner YOUR_GH_USER \
     --repository homelab_gitops \
     --branch main \
     --path clusters/minikube

5. Commit and push k8s manifests as you go; Flux will reconcile.
MD
}

main() {
  log "== Homelab GitOps Scaffold v$SCRIPT_VERSION =="

  ensure_kubectl
  ensure_helm
  ensure_sops
  ensure_age
  ensure_mkcert
  ensure_flux
  ensure_minikube
  start_minikube

  scaffold_repo
  init_certs
  init_age_keys
  write_flux_notes

  ./scripts/generate_readme.sh

  log "DONE. Next steps:"
  cat <<'NEXT'
- Optional: export AGE key for sops usage in shell:
    export SOPS_AGE_KEY_FILE="$(pwd)/.sops/age.key"
- Decide your MetalLB IP range and add a YAML in: k8s/addons/metallb/
- Add Traefik values and IngressClass in: k8s/addons/traefik/
- Add cert-manager CRDs/ClusterIssuer in: k8s/addons/cert-manager/
- Add AWX operator in: k8s/addons/awx-operator/
- Initialize git and push, then bootstrap Flux (see infra/docs/BOOTSTRAP_NOTES.md)
NEXT
}

main "$@"

