#!/usr/bin/env bash
set -euo pipefail

FLUX_VERSION="2.3.0"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_PATH="${CLUSTER_PATH:-clusters/minikube}"
if [[ "$CLUSTER_PATH" = /* ]]; then
  CLUSTER_ABS_PATH="$CLUSTER_PATH"
else
  CLUSTER_ABS_PATH="$REPO_ROOT/$CLUSTER_PATH"
fi

run_with_sudo_if_needed() {
  if "$@"; then
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "Command '$*' requires elevated privileges but sudo is not installed." >&2
    exit 1
  fi
}

INSTALLED_VERSION=""
if command -v flux >/dev/null 2>&1; then
  if FLUX_SHORT_VERSION=$(flux version --client --short 2>/dev/null); then
    INSTALLED_VERSION="${FLUX_SHORT_VERSION#v}"
  else
    FLUX_FULL_VERSION=$(flux --version 2>/dev/null || true)
    INSTALLED_VERSION=$(printf '%s\n' "$FLUX_FULL_VERSION" | awk 'NR==1 {for (i=1;i<=NF;i++) if ($i ~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/) {gsub("^v", "", $i); print $i; exit}}')
  fi
fi

if [[ "$INSTALLED_VERSION" != "$FLUX_VERSION" ]]; then
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  case "$OS" in
  linux | darwin) ;;
  *)
    echo "Unsupported operating system: $OS" >&2
    exit 1
    ;;
  esac

  ARCH=$(uname -m)
  case "$ARCH" in
  x86_64 | amd64)
    ARCH="amd64"
    ;;
  arm64 | aarch64)
    ARCH="arm64"
    ;;
  armv7l | armv7)
    ARCH="armv7"
    ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
  esac

  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT

  TARBALL="flux_${FLUX_VERSION}_${OS}_${ARCH}.tar.gz"
  CHECKSUM_FILE="flux_${FLUX_VERSION}_checksums.txt"
  BASE_URL="https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}"

  curl -fsSLo "$TMP_DIR/$TARBALL" "$BASE_URL/$TARBALL"
  curl -fsSLo "$TMP_DIR/$CHECKSUM_FILE" "$BASE_URL/$CHECKSUM_FILE"

  if command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum --check)
  elif command -v shasum >/dev/null 2>&1; then
    SHA_CMD=(shasum -a 256 -c)
  else
    echo "Neither sha256sum nor shasum is available for checksum verification." >&2
    exit 1
  fi

  (
    cd "$TMP_DIR"
    awk -v file="$TARBALL" '$2 == file {print; found=1} END {if (!found) exit 1}' "$CHECKSUM_FILE" >"$TARBALL.sha256"
    "${SHA_CMD[@]}" "$TARBALL.sha256"
  )

  tar -xzf "$TMP_DIR/$TARBALL" -C "$TMP_DIR"

  run_with_sudo_if_needed mkdir -p "$INSTALL_DIR"
  run_with_sudo_if_needed install -m 0755 "$TMP_DIR/flux" "$INSTALL_DIR/flux"
fi

kubectl create ns flux-system --dry-run=client -o yaml | kubectl apply -f -
flux install -n flux-system || true
mkdir -p "$CLUSTER_ABS_PATH"
