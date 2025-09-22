#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )"
# shellcheck source=lib/load-env.sh
source "${SCRIPT_DIR}/lib/load-env.sh"
load_env "$@"

usage() {
  cat <<'USAGE'
Usage: status.sh [options]

Options:
  -e, --env-file <path>   Load environment variables from the given file before running.
  -h, --help              Show this help message and exit.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "error: unknown argument: $1" >&2
    usage
    exit 1
    ;;
  esac
done

print_section() {
  local title="$1"
  printf "\n%s\n" "$title"
  printf '%s\n' "$(printf '%*s' "${#title}" '' | tr ' ' '-')"
}

print_key_value() {
  local label="$1"
  local value="$2"
  printf "  %-24s %s\n" "$label" "$value"
}

run_cmd() {
  local description="$1"
  shift
  printf "  - %s\n" "$description"

  set +e
  local output
  output=$("$@" 2>&1)
  local status=$?
  set -e

  if [[ $status -eq 0 ]]; then
    if [[ -z "$output" ]]; then
      printf "      (no output)\n"
    else
      printf '%s\n' "$output" | sed 's/^/      /'
    fi
  else
    printf "      command failed (exit code %d)\n" "$status"
    if [[ -n "$output" ]]; then
      printf '%s\n' "$output" | sed 's/^/        /'
    fi
  fi
}

print_header() {
  printf "Homelab Status Summary\n"
  printf "======================\n"
}

print_env_summary() {
  print_section "Environment configuration"

  if [[ -n "${HOMELAB_ENV_FILE:-}" ]]; then
    print_key_value "Environment file:" "${HOMELAB_ENV_FILE}"
  else
    print_key_value "Environment file:" "(none)"
  fi

  print_key_value "Domain:" "${LABZ_DOMAIN:-<unset>}"
  print_key_value "Domain base:" "${LAB_DOMAIN_BASE:-<unset>}"
  print_key_value "Traefik host:" "${LABZ_TRAEFIK_HOST:-<unset>}"
  print_key_value "Nextcloud host:" "${LABZ_NEXTCLOUD_HOST:-<unset>}"
  print_key_value "Jellyfin host:" "${LABZ_JELLYFIN_HOST:-<unset>}"
  print_key_value "Minikube profile:" "${LABZ_MINIKUBE_PROFILE:-<unset>}"
  print_key_value "Minikube driver:" "${LABZ_MINIKUBE_DRIVER:-<unset>}"
  print_key_value "Minikube CPUs:" "${LABZ_MINIKUBE_CPUS:-<unset>}"
  print_key_value "Minikube memory:" "${LABZ_MINIKUBE_MEMORY:-<unset>}"
  print_key_value "Minikube disk:" "${LABZ_MINIKUBE_DISK:-<unset>}"
  print_key_value "Mount (backups):" "${LABZ_MOUNT_BACKUPS:-<unset>}"
  print_key_value "Mount (media):" "${LABZ_MOUNT_MEDIA:-<unset>}"
  print_key_value "Mount (nextcloud):" "${LABZ_MOUNT_NEXTCLOUD:-<unset>}"
}

print_virsh_summary() {
  print_section "Virtualization (virsh)"

  if ! command -v virsh >/dev/null 2>&1; then
    printf "  virsh command not found. Skipping virtualization summary.\n"
    return
  fi

  run_cmd "Defined domains" virsh list --all
  run_cmd "Defined networks" virsh net-list --all
  run_cmd "Defined storage pools" virsh pool-list --all
}

print_kubectl_summary() {
  print_section "Kubernetes (kubectl)"

  if ! command -v kubectl >/dev/null 2>&1; then
    printf "  kubectl command not found. Skipping Kubernetes summary.\n"
    return
  fi

  run_cmd "Current context" kubectl config current-context
  run_cmd "Nodes" kubectl get nodes
  run_cmd "Namespaces" kubectl get ns
  run_cmd "Pods not running" kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
}

print_ingress_hosts() {
  print_section "Ingress hosts"

  local has_env_hosts=false
  if [[ -n "${LABZ_TRAEFIK_HOST:-}" || -n "${LABZ_NEXTCLOUD_HOST:-}" || -n "${LABZ_JELLYFIN_HOST:-}" ]]; then
    has_env_hosts=true
  fi

  if [[ "$has_env_hosts" == true ]]; then
    printf "  From environment configuration:\n"
    if [[ -n "${LABZ_TRAEFIK_HOST:-}" ]]; then
      print_key_value "Traefik:" "${LABZ_TRAEFIK_HOST}"
    fi
    if [[ -n "${LABZ_NEXTCLOUD_HOST:-}" ]]; then
      print_key_value "Nextcloud:" "${LABZ_NEXTCLOUD_HOST}"
    fi
    if [[ -n "${LABZ_JELLYFIN_HOST:-}" ]]; then
      print_key_value "Jellyfin:" "${LABZ_JELLYFIN_HOST}"
    fi
  else
    printf "  No ingress host variables found in the environment.\n"
  fi

  if command -v kubectl >/dev/null 2>&1; then
    run_cmd "Ingress resources" kubectl get ingress -A --output=custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host,ADDRESS:.status.loadBalancer.ingress[*].ip' --no-headers
  else
    printf "  kubectl command not found, skipping live ingress summary.\n"
  fi
}

print_k9s_tips() {
  print_section "k9s tips"
  cat <<'TIPS'
  - Start k9s in a specific context: `k9s --context <name>`.
  - Use `:ns` to quickly switch namespaces, and `:ctx` for contexts.
  - Press `/` to filter resources, `:ing` for ingress view, or `:svc` for services.
  - Use `Shift+F` to toggle port-forward view (`:pf`) and manage tunnels.
  - Press `?` at any time to see the built-in cheat sheet.
TIPS
}

main() {
  print_header
  print_env_summary
  print_virsh_summary
  print_kubectl_summary
  print_ingress_hosts
  print_k9s_tips
}

main "$@"
