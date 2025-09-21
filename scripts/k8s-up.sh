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

ORIGINAL_ARGS=("$@")

ENV_FILE_OVERRIDE=""
ENV_FILE_PATH=""
DRY_RUN=false

POSTGRES_VALUES_FILE="${REPO_ROOT}/values/postgresql.yaml"
STORAGE_MANIFEST_DIR="${REPO_ROOT}/k8s/storage"
TRAEFIK_VALUES_FILE="${REPO_ROOT}/k8s/traefik/values.yaml"
METALLB_L2ADV_FILE="${REPO_ROOT}/k8s/addons/metallb/l2adv.yaml"

usage() {
  cat <<'USAGE'
Usage: k8s-up.sh [OPTIONS]

Bring up the local homelab Minikube cluster with core addons and
self-hosted applications.

Options:
  --env-file PATH   Load environment configuration from PATH.
  --dry-run         Log actions without performing changes.
  --verbose         Increase logging verbosity to debug.
  -h, --help        Show this help message.
USAGE
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
      --verbose)
        log_set_level debug
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
        die ${EX_USAGE} "Positional arguments are not supported"
        ;;
    esac
  done
}

run_cmd() {
  local formatted
  formatted=$(format_command "$@")
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] ${formatted}"
    return 0
  fi
  log_debug "Executing: ${formatted}"
  "$@"
}

kubectl_apply_manifest() {
  local manifest=$1
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl apply -f - <<'EOF'"
    printf '%s\n' "${manifest}"
    log_info "[DRY-RUN] EOF"
    return 0
  fi
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"
  printf '%s\n' "${manifest}" | kubectl apply -f -
}

kubectl_apply_file() {
  local file=$1
  if [[ ! -f ${file} ]]; then
    die ${EX_CONFIG} "Manifest not found: ${file}"
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl apply -f ${file}"
    return 0
  fi
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"
  kubectl apply -f "${file}"
}

apply_manifest_with_envsubst() {
  local file=$1
  if [[ ! -f ${file} ]]; then
    die ${EX_CONFIG} "Manifest not found: ${file}"
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] envsubst < ${file} | kubectl apply -f -"
    return 0
  fi
  need envsubst kubectl || die ${EX_UNAVAILABLE} "envsubst and kubectl are required"
  envsubst <"${file}" | kubectl apply -f -
}

ensure_namespace_safe() {
  local namespace=$1
  if [[ ${DRY_RUN} == true ]]; then
    if command -v kubectl >/dev/null 2>&1 && kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_debug "Namespace ${namespace} already exists"
    else
      log_info "[DRY-RUN] kubectl create namespace ${namespace}"
    fi
    return 0
  fi
  ensure_namespace "${namespace}" || die ${EX_SOFTWARE} "Failed to ensure namespace ${namespace}"
}

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    log_info "Loading environment overrides from ${ENV_FILE_OVERRIDE}"
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    ENV_FILE_PATH="${ENV_FILE_OVERRIDE}"
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
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      ENV_FILE_PATH="${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  ENV_FILE_PATH=""
  log_warn "No environment file found in default search paths"
}

require_env_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die ${EX_CONFIG} "Missing required variables: ${missing[*]}"
  fi
}

ensure_dependencies() {
  local -a required=(minikube kubectl helm envsubst)
  if [[ ${DRY_RUN} == true ]]; then
    local -a missing=()
    local cmd
    for cmd in "${required[@]}"; do
      if ! command -v "${cmd}" >/dev/null 2>&1; then
        missing+=("${cmd}")
      fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      log_warn "Dry-run mode: missing dependencies will be skipped: ${missing[*]}"
    fi
    return 0
  fi

  need "${required[@]}" || die ${EX_UNAVAILABLE} "minikube, kubectl, helm, and envsubst are required"
}

ensure_minikube_profile() {
  local profile=${LABZ_MINIKUBE_PROFILE}
  local driver=${LABZ_MINIKUBE_DRIVER:-docker}
  local cpus=${LABZ_MINIKUBE_CPUS:-4}
  local memory=${LABZ_MINIKUBE_MEMORY:-8192}
  local disk=${LABZ_MINIKUBE_DISK:-60g}
  local version=${LABZ_KUBERNETES_VERSION:-}
  if [[ -n ${version} && ${version} != v* ]]; then
    version="v${version}"
  fi

  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] minikube status -p ${profile}"
    local -a start_cmd=(
      minikube start
      -p "${profile}"
      --driver="${driver}"
      --cpus="${cpus}"
      --memory="${memory}"
      --disk-size="${disk}"
      --cni=bridge
      --extra-config=kubeadm.pod-network-cidr=10.244.0.0/16
      --extra-config=apiserver.service-node-port-range=30000-32767
    )
    if [[ -n ${version} ]]; then
      start_cmd+=(--kubernetes-version="${version}")
    fi
    log_info "[DRY-RUN] $(format_command "${start_cmd[@]}")"
    return
  fi

  need minikube || die ${EX_UNAVAILABLE} "minikube is required"
  if minikube status -p "${profile}" >/dev/null 2>&1; then
    log_info "Minikube profile ${profile} already running"
    return
  fi

  local -a cmd=(
    minikube start
    -p "${profile}"
    --driver="${driver}"
    --cpus="${cpus}"
    --memory="${memory}"
    --disk-size="${disk}"
    --cni=bridge
    --extra-config=kubeadm.pod-network-cidr=10.244.0.0/16
    --extra-config=apiserver.service-node-port-range=30000-32767
  )
  if [[ -n ${version} ]]; then
    cmd+=(--kubernetes-version="${version}")
  fi
  run_cmd "${cmd[@]}"
}

ensure_context() {
  if [[ ${DRY_RUN} == true ]]; then
    if ! command -v kubectl >/dev/null 2>&1; then
      log_warn "Dry-run mode: kubectl not available; skipping context switch"
      return
    fi
  fi

  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"
  local desired=${LABZ_MINIKUBE_PROFILE}
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ ${current} == "${desired}" ]]; then
    log_info "kubectl context already set to ${desired}"
    return
  fi
  run_cmd kubectl config use-context "${desired}"
}

ensure_helm_repo_present() {
  local name=$1
  local url=$2
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] helm repo add ${name} ${url} (if missing)"
    log_info "[DRY-RUN] helm repo update ${name}"
    return 0
  fi
  ensure_helm_repo "${name}" "${url}" || die ${EX_SOFTWARE} "Failed to ensure Helm repository ${name}"
}

install_metallb() {
  ensure_namespace_safe metallb-system
  local -a cmd=(
    helm upgrade --install metallb metallb/metallb
    --namespace metallb-system
    --create-namespace
    --wait
    --timeout 10m0s
  )
  if [[ -n ${METALLB_HELM_VERSION:-} ]]; then
    cmd+=(--version "${METALLB_HELM_VERSION}")
  fi
  run_cmd "${cmd[@]}"
  if [[ ${DRY_RUN} == false ]]; then
    run_cmd kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=180s
    run_cmd kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=180s
  fi
}

apply_metallb_pool() {
  require_env_vars METALLB_POOL_START METALLB_POOL_END
  local pool_manifest
  if ! pool_manifest=$(metallb_render_ip_pool_manifest "homelab-pool" "metallb-system"); then
    die ${EX_CONFIG} "Failed to render MetalLB IPAddressPool"
  fi
  kubectl_apply_manifest "${pool_manifest}"
  kubectl_apply_file "${METALLB_L2ADV_FILE}"
}

install_cert_manager() {
  ensure_namespace_safe cert-manager
  local -a cmd=(
    helm upgrade --install cert-manager jetstack/cert-manager
    --namespace cert-manager
    --create-namespace
    --wait
    --timeout 10m0s
    --set crds.enabled=true
  )
  if [[ -n ${CERT_MANAGER_HELM_VERSION:-} ]]; then
    cmd+=(--version "${CERT_MANAGER_HELM_VERSION}")
  fi
  run_cmd "${cmd[@]}"
  local issuer
  issuer=$(cat <<'EOM'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: labz-selfsigned
spec:
  selfSigned: {}
EOM
)
  kubectl_apply_manifest "${issuer}"
}

install_traefik() {
  ensure_namespace_safe traefik
  local -a cmd=(
    helm upgrade --install traefik traefik/traefik
    --namespace traefik
    --create-namespace
    --wait
    --timeout 10m0s
    --set service.type=LoadBalancer
    --set service.spec.loadBalancerIP="${TRAEFIK_LOCAL_IP}"
    --set ingressRoute.dashboard.enabled=true
    --set ingressRoute.dashboard.tls.secretName=labz-traefik-tls
  )
  if [[ -n ${TRAEFIK_HELM_VERSION:-} ]]; then
    cmd+=(--version "${TRAEFIK_HELM_VERSION}")
  fi
  if [[ -f ${TRAEFIK_VALUES_FILE} ]]; then
    cmd+=(--values "${TRAEFIK_VALUES_FILE}")
  fi
  run_cmd "${cmd[@]}"
}

create_support_namespaces() {
  ensure_namespace_safe databases
  ensure_namespace_safe data
  ensure_namespace_safe nextcloud
  ensure_namespace_safe jellyfin
}

create_postgresql_secret() {
  local manifest
  manifest=$(cat <<EOM
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secrets
  namespace: databases
stringData:
  postgres-password: ${LABZ_POSTGRES_PASSWORD}
  password: ${LABZ_POSTGRES_PASSWORD}
  replication-password: ${LABZ_POSTGRES_PASSWORD}
  patroni-admin-password: ${LABZ_POSTGRES_PASSWORD}
  patroni-replication-password: ${LABZ_POSTGRES_PASSWORD}
  patroni-superuser-password: ${LABZ_POSTGRES_PASSWORD}
EOM
)
  kubectl_apply_manifest "${manifest}"
}

install_postgresql() {
  local -a cmd=(
    helm upgrade --install postgresql bitnami/postgresql
    --namespace databases
    --create-namespace
    --wait
    --timeout 15m0s
    --values "${POSTGRES_VALUES_FILE}"
    --set fullnameOverride=postgresql
    --set global.postgresql.auth.database="${LABZ_POSTGRES_DB}"
    --set global.postgresql.auth.username="${LABZ_POSTGRES_USER}"
    --set global.postgresql.auth.password="${LABZ_POSTGRES_PASSWORD}"
  )
  if [[ -n ${LABZ_POSTGRES_HELM_VERSION:-} ]]; then
    cmd+=(--version "${LABZ_POSTGRES_HELM_VERSION}")
  fi
  run_cmd "${cmd[@]}"
}

install_redis() {
  local -a cmd=(
    helm upgrade --install redis bitnami/redis
    --namespace data
    --create-namespace
    --wait
    --timeout 10m0s
    --set fullnameOverride=redis
    --set architecture=standalone
    --set auth.enabled=true
    --set auth.password="${LABZ_REDIS_PASSWORD}"
    --set master.persistence.enabled=true
  )
  if [[ -n ${LABZ_REDIS_HELM_VERSION:-} ]]; then
    cmd+=(--version "${LABZ_REDIS_HELM_VERSION}")
  fi
  run_cmd "${cmd[@]}"
}

create_certificates() {
  local manifest
  manifest=$(cat <<EOM
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: labz-apps-tls
  namespace: nextcloud
spec:
  secretName: labz-apps-tls
  dnsNames:
    - ${LABZ_NEXTCLOUD_HOST}
  issuerRef:
    kind: ClusterIssuer
    name: labz-selfsigned
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: labz-traefik-tls
  namespace: traefik
spec:
  secretName: labz-traefik-tls
  dnsNames:
    - ${LABZ_TRAEFIK_HOST}
  issuerRef:
    kind: ClusterIssuer
    name: labz-selfsigned
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: labz-apps-tls
  namespace: jellyfin
spec:
  secretName: labz-apps-tls
  dnsNames:
    - ${LABZ_JELLYFIN_HOST}
  issuerRef:
    kind: ClusterIssuer
    name: labz-selfsigned
EOM
)
  kubectl_apply_manifest "${manifest}"
}

install_nextcloud() {
  local -a cmd=(
    helm upgrade --install nextcloud bitnami/nextcloud
    --namespace nextcloud
    --create-namespace
    --wait
    --timeout 15m0s
    --set fullnameOverride=nextcloud
    --set mariadb.enabled=false
    --set postgresql.enabled=false
    --set redis.enabled=false
    --set nextcloudHost="${LABZ_NEXTCLOUD_HOST}"
    --set ingress.enabled=true
    --set ingress.ingressClassName=traefik
    --set ingress.hostname="${LABZ_NEXTCLOUD_HOST}"
    --set ingress.tls[0].hosts[0]="${LABZ_NEXTCLOUD_HOST}"
    --set ingress.tls[0].secretName=labz-apps-tls
    --set persistence.enabled=true
    --set persistence.existingClaim=nextcloud-data
    --set externalDatabase.enabled=true
    --set externalDatabase.type=postgresql
    --set externalDatabase.host=postgresql.databases.svc.cluster.local
    --set externalDatabase.port=5432
    --set externalDatabase.user="${LABZ_POSTGRES_USER}"
    --set externalDatabase.password="${LABZ_POSTGRES_PASSWORD}"
    --set externalDatabase.database="${LABZ_POSTGRES_DB}"
    --set externalCache.enabled=true
    --set externalCache.host=redis-master.data.svc.cluster.local
    --set externalCache.port=6379
    --set externalCache.password="${LABZ_REDIS_PASSWORD}"
    --set phpClient.maxUploadSize="${LABZ_PHP_UPLOAD_LIMIT}"
    --set podSecurityContext.enabled=true
    --set podSecurityContext.fsGroup=33
    --set containerSecurityContext.enabled=true
    --set containerSecurityContext.runAsUser=33
    --set containerSecurityContext.runAsGroup=33
  )
  if [[ -n ${LABZ_NEXTCLOUD_HELM_VERSION:-} ]]; then
    cmd+=(--version "${LABZ_NEXTCLOUD_HELM_VERSION}")
  fi
  run_cmd "${cmd[@]}"
}

install_jellyfin() {
  local manifest
  manifest=$(cat <<EOM
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jellyfin
  namespace: jellyfin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jellyfin
  template:
    metadata:
      labels:
        app: jellyfin
    spec:
      containers:
        - name: jellyfin
          image: jellyfin/jellyfin:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8096
              name: http
          volumeMounts:
            - mountPath: /media
              name: media
      volumes:
        - name: media
          persistentVolumeClaim:
            claimName: jellyfin-media
---
apiVersion: v1
kind: Service
metadata:
  name: jellyfin
  namespace: jellyfin
spec:
  selector:
    app: jellyfin
  ports:
    - name: http
      port: 80
      targetPort: http
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jellyfin
  namespace: jellyfin
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ${LABZ_JELLYFIN_HOST}
      secretName: labz-apps-tls
  rules:
    - host: ${LABZ_JELLYFIN_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: jellyfin
                port:
                  number: 80
EOM
)
  kubectl_apply_manifest "${manifest}"
}

clear_lingering_pv_claim_refs() {
  local selector="pv-role"
  log_info "Scanning persistent volumes with selector '${selector}' for lingering claimRefs"

  if [[ ${DRY_RUN} == true ]]; then
    if ! command -v kubectl >/dev/null 2>&1; then
      log_warn "Dry-run mode: kubectl not available; skipping persistent volume scan"
      return 0
    fi
  else
    need kubectl || die ${EX_UNAVAILABLE} "kubectl is required to inspect persistent volumes"
  fi

  local pv_info=""
  if ! pv_info=$(kubectl get pv -l "${selector}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.spec.claimRef.name}{"\n"}{end}' 2>/dev/null); then
    log_warn "Unable to query persistent volumes with selector '${selector}'"
    return 0
  fi

  if [[ -z ${pv_info} ]]; then
    log_info "No persistent volumes matched selector '${selector}'"
    return 0
  fi

  local line
  while IFS= read -r line; do
    [[ -z ${line} ]] && continue
    local pv_name=""
    local phase=""
    local claim_ref=""
    IFS='|' read -r pv_name phase claim_ref <<<"${line}"
    [[ -z ${pv_name} ]] && continue
    [[ ${claim_ref} == "<no value>" ]] && claim_ref=""
    [[ ${phase} == "<no value>" ]] && phase=""

    if { [[ ${phase} == "Released" ]] || [[ ${phase} == "Failed" ]]; } && [[ -n ${claim_ref} ]]; then
      if [[ ${DRY_RUN} == true ]]; then
        log_info "[DRY-RUN] Would remove claimRef '${claim_ref}' from PV ${pv_name} (phase: ${phase})"
      else
        log_info "Removing claimRef '${claim_ref}' from PV ${pv_name} (phase: ${phase})"
        local patch_payload='[{"op":"remove","path":"/spec/claimRef"}]'
        if run_cmd kubectl patch pv "${pv_name}" --type=json -p "${patch_payload}" >/dev/null; then
          log_info "PV ${pv_name} claimRef cleared; volume is ready for rebinding"
        else
          log_warn "Failed to clear claimRef from PV ${pv_name}"
        fi
      fi
    elif [[ -z ${claim_ref} ]]; then
      local phase_display=${phase:-Unknown}
      log_info "PV ${pv_name} is ${phase_display} with no claimRef; already available"
    else
      log_debug "PV ${pv_name} is ${phase:-Unknown} with claimRef '${claim_ref}'; no action required"
    fi
  done <<<"${pv_info}"
}

wait_for_pvc_bound_safe() {
  local namespace=$1
  local pvc=$2
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl wait --namespace ${namespace} --for=condition=Bound pvc/${pvc} --timeout=300s"
    return 0
  fi
  if ! pvc_wait_bound "${pvc}" "${namespace}" 300s; then
    die ${EX_SOFTWARE} "PVC ${namespace}/${pvc} failed to become Bound"
  fi
}

apply_storage_manifests() {
  if [[ ! -d ${STORAGE_MANIFEST_DIR} ]]; then
    die ${EX_CONFIG} "Storage manifest directory not found: ${STORAGE_MANIFEST_DIR}"
  fi
  local manifest_file
  for manifest_file in "${STORAGE_MANIFEST_DIR}"/*.yaml; do
    [[ -f ${manifest_file} ]] || continue
    log_info "Applying storage manifest ${manifest_file}"
    apply_manifest_with_envsubst "${manifest_file}"
  done
}

prepare_storage_paths() {
  POSTGRES_DATA_PATH="${LABZ_MOUNT_BACKUPS%/}/postgresql-data"
  NEXTCLOUD_DATA_PATH="${LABZ_MOUNT_NEXTCLOUD%/}"
  JELLYFIN_MEDIA_PATH="${LABZ_MOUNT_MEDIA%/}"
  export POSTGRES_DATA_PATH NEXTCLOUD_DATA_PATH JELLYFIN_MEDIA_PATH PG_STORAGE_SIZE

  homelab_maybe_reexec_for_privileged_paths HOMELAB_ESCALATED \
    "${POSTGRES_DATA_PATH}" "${NEXTCLOUD_DATA_PATH}" "${JELLYFIN_MEDIA_PATH}"

  run_cmd mkdir -p "${POSTGRES_DATA_PATH}" "${NEXTCLOUD_DATA_PATH}" "${JELLYFIN_MEDIA_PATH}"
}

print_context_summary() {
  log_info "Environment summary"
  log_info "  Environment file: ${ENV_FILE_PATH:-<not found>}"
  log_info "  Minikube profile: ${LABZ_MINIKUBE_PROFILE}"
  log_info "  MetalLB range:    ${LABZ_METALLB_RANGE}"
  log_info "  Traefik host:     ${LABZ_TRAEFIK_HOST}"
  log_info "  Nextcloud host:   ${LABZ_NEXTCLOUD_HOST}"
  log_info "  Jellyfin host:    ${LABZ_JELLYFIN_HOST}"
  log_info "  Storage manifests: ${STORAGE_MANIFEST_DIR}"
  log_info "  Postgres values:   ${POSTGRES_VALUES_FILE}"
}

main() {
  parse_args "$@"
  load_environment

  if [[ -z ${ENV_FILE_PATH} ]]; then
    die ${EX_CONFIG} "Environment file is required. Use --env-file to specify one."
  fi

  : "${LABZ_MINIKUBE_PROFILE:=labz}"
  : "${LABZ_MINIKUBE_DRIVER:=docker}"
  : "${LABZ_MINIKUBE_CPUS:=4}"
  : "${LABZ_MINIKUBE_MEMORY:=8192}"
  : "${LABZ_MINIKUBE_DISK:=60g}"
  : "${LABZ_KUBERNETES_VERSION:=v1.31.3}"
  : "${METALLB_HELM_VERSION:=0.14.7}"
  : "${CERT_MANAGER_HELM_VERSION:=1.16.3}"
  : "${TRAEFIK_HELM_VERSION:=27.0.2}"
  : "${LABZ_POSTGRES_HELM_VERSION:=16.2.6}"
  : "${TRAEFIK_LOCAL_IP:=${METALLB_POOL_START:-}}"

  require_env_vars \
    LABZ_METALLB_RANGE METALLB_POOL_START METALLB_POOL_END \
    LABZ_TRAEFIK_HOST LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST \
    LABZ_POSTGRES_DB LABZ_POSTGRES_USER LABZ_POSTGRES_PASSWORD \
    LABZ_REDIS_PASSWORD LABZ_PHP_UPLOAD_LIMIT LABZ_MOUNT_BACKUPS \
    LABZ_MOUNT_MEDIA LABZ_MOUNT_NEXTCLOUD PG_STORAGE_SIZE

  if [[ ! -f ${POSTGRES_VALUES_FILE} ]]; then
    die ${EX_CONFIG} "PostgreSQL values file not found: ${POSTGRES_VALUES_FILE}"
  fi
  if [[ ! -f ${TRAEFIK_VALUES_FILE} ]]; then
    die ${EX_CONFIG} "Traefik values file not found: ${TRAEFIK_VALUES_FILE}"
  fi
  if [[ ! -f ${METALLB_L2ADV_FILE} ]]; then
    die ${EX_CONFIG} "MetalLB L2Advertisement manifest not found: ${METALLB_L2ADV_FILE}"
  fi

  ensure_dependencies
  prepare_storage_paths
  print_context_summary

  ensure_helm_repo_present bitnami https://charts.bitnami.com/bitnami
  ensure_helm_repo_present metallb https://metallb.github.io/metallb
  ensure_helm_repo_present traefik https://traefik.github.io/charts
  ensure_helm_repo_present jetstack https://charts.jetstack.io

  ensure_minikube_profile
  ensure_context

  install_metallb
  apply_metallb_pool

  install_cert_manager
  install_traefik
  create_support_namespaces

  apply_storage_manifests
  clear_lingering_pv_claim_refs

  wait_for_pvc_bound_safe databases postgresql-data
  wait_for_pvc_bound_safe nextcloud nextcloud-data
  wait_for_pvc_bound_safe jellyfin jellyfin-media

  create_postgresql_secret
  install_postgresql
  install_redis
  create_certificates
  install_nextcloud
  install_jellyfin

  log_info "Homelab deployment complete"
  log_info "  Traefik dashboard: https://${LABZ_TRAEFIK_HOST}/dashboard/"
  log_info "  Nextcloud:         https://${LABZ_NEXTCLOUD_HOST}/"
  log_info "  Jellyfin:          https://${LABZ_JELLYFIN_HOST}/"
  log_info "Assign DNS to an IP within ${LABZ_METALLB_RANGE} for access."
}

main "$@"
