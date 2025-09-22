#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POSTGRES_VALUES_FILE="${REPO_ROOT}/values/postgresql.yaml"
STORAGE_MANIFEST_DIR="${REPO_ROOT}/k8s/storage"

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

# shellcheck disable=SC2034
ASSUME_YES=false
ENV_FILE_OVERRIDE=""
# shellcheck disable=SC2034
ENV_FILE_PATH=""
DRY_RUN=false
CONTEXT_ONLY=false

usage() {
  cat <<'USAGE'
Usage: uranus_homelab_apps.sh [OPTIONS]

Deploy PostgreSQL, Redis, Nextcloud, and Jellyfin workloads into the Uranus
homelab cluster using environment configuration.

Options:
  --env-file PATH         Load configuration overrides from PATH.
  --assume-yes            Automatically confirm prompts when possible.
  --dry-run               Log mutating actions without executing them.
  --context-preflight     Validate cluster context and exit without changes.
  --verbose               Increase logging verbosity to debug.
  -h, --help              Show this help message.

Exit codes:
  0   Success.
  64  Usage error (invalid CLI arguments).
  69  Missing required dependencies.
  70  Runtime failure during workload deployment.
  78  Configuration error (missing environment variables or values files).
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

kubectl_apply_manifest() {
  local manifest=$1
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] kubectl apply -f - <<'EOF'"
    printf '%s\n' "${manifest}"
    log_info "[DRY-RUN] EOF"
    return 0
  fi
  need kubectl || return $?
  printf '%s\n' "${manifest}" | kubectl apply -f -
}

ensure_namespace_safe() {
  local namespace=$1
  if [[ ${DRY_RUN} == true ]]; then
    if kubectl get namespace "${namespace}" >/dev/null 2>&1; then
      log_debug "Namespace ${namespace} already exists"
    else
      log_info "[DRY-RUN] kubectl create namespace ${namespace}"
    fi
    return 0
  fi
  ensure_namespace "${namespace}"
}

apply_manifest_with_envsubst() {
  local manifest=$1
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] envsubst <${manifest} | kubectl apply -f -"
    return 0
  fi
  need envsubst || return $?
  envsubst <"${manifest}" | kubectl apply -f -
}

load_environment() {
  if [[ -n ${ENV_FILE_OVERRIDE} ]]; then
    log_info "Loading environment overrides from ${ENV_FILE_OVERRIDE}"
    if [[ ! -f ${ENV_FILE_OVERRIDE} ]]; then
      die ${EX_CONFIG} "Environment file not found: ${ENV_FILE_OVERRIDE}"
    fi
    # shellcheck disable=SC2034
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
    log_debug "Checking for environment file at ${candidate}"
    if [[ -f ${candidate} ]]; then
      log_info "Loading environment from ${candidate}"
      # shellcheck disable=SC2034
      ENV_FILE_PATH="${candidate}"
      load_env "${candidate}" || die ${EX_CONFIG} "Failed to load ${candidate}"
      return
    fi
  done
  # shellcheck disable=SC2034
  ENV_FILE_PATH=""
  log_debug "No environment file present in default search locations"
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
    --assume-yes)
      # shellcheck disable=SC2034
      ASSUME_YES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --context-preflight)
      CONTEXT_ONLY=true
      shift
      ;;
    --verbose)
      log_set_level debug
      shift
      ;;
    -h | --help)
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
    -*)
      usage
      die ${EX_USAGE} "Unknown option: $1"
      ;;
    *)
      usage
      die ${EX_USAGE} "Positional arguments are not supported"
      ;;
    esac
  done
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

ensure_context() {
  need kubectl || die ${EX_UNAVAILABLE} "kubectl is required"
  local desired=${LABZ_MINIKUBE_PROFILE}
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  if [[ ${current} != "${desired}" ]]; then
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] kubectl config use-context ${desired}"
    else
      run_cmd kubectl config use-context "${desired}"
    fi
  else
    log_info "kubectl context already set to ${desired}"
  fi
}

ensure_helm_repo_safe() {
  local name=$1
  local url=$2
  need helm || die ${EX_UNAVAILABLE} "helm is required"
  if helm repo list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${name}"; then
    log_debug "Helm repository ${name} already present"
  else
    if [[ ${DRY_RUN} == true ]]; then
      log_info "[DRY-RUN] helm repo add ${name} ${url}"
    else
      run_cmd helm repo add "${name}" "${url}"
    fi
  fi
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] helm repo update ${name}"
  else
    run_cmd helm repo update "${name}"
  fi
}

print_context_summary() {
  log_info "Context summary"
  log_info "  Environment file: ${ENV_FILE_PATH:-<not found>}"
  log_info "  Postgres values file: ${POSTGRES_VALUES_FILE}"
  log_info "  Storage manifests: ${STORAGE_MANIFEST_DIR}"
  log_info "  Cluster profile: ${LABZ_MINIKUBE_PROFILE}"
  log_info "  Nextcloud host: ${LABZ_NEXTCLOUD_HOST}"
  log_info "  Jellyfin host: ${LABZ_JELLYFIN_HOST}"
  log_info "  MetalLB range: ${LABZ_METALLB_RANGE}"
}

collect_postgresql_diagnostics() {
  log_warn "Collecting PostgreSQL diagnostics"
  helm status postgresql --namespace databases || true
  kubectl -n databases get pods,pvc,svc,statefulset || true
  kubectl -n databases describe statefulset postgresql || true
  kubectl -n databases describe pods -l app.kubernetes.io/name=postgresql || true
  kubectl get events --all-namespaces --sort-by='.metadata.creationTimestamp' | tail -n 50 || true
}

wait_for_pvc_bound_safe() {
  local namespace=$1
  local pvc=$2
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] Wait for PVC ${namespace}/${pvc}"
    return 0
  fi
  pvc_wait_bound "${pvc}" "${namespace}" 300s
}

clear_lingering_pv_claim_refs() {
  local selector="pv-role"
  log_info "Scanning persistent volumes with selector '${selector}' for lingering claimRefs"

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

install_postgresql() {
  local cmd=(
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
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${cmd[@]}")"
    return 0
  fi
  if ! retry 3 5 "${cmd[@]}"; then
    collect_postgresql_diagnostics
    die ${EX_SOFTWARE} "PostgreSQL installation failed after retries"
  fi
  retry 5 10 kubectl -n databases rollout status statefulset/postgresql --timeout=5m
}

install_redis() {
  local cmd=(
    helm upgrade --install redis bitnami/redis
    --namespace data
    --create-namespace
    --set fullnameOverride=redis
    --set architecture=standalone
    --set auth.enabled=true
    --set auth.password="${LABZ_REDIS_PASSWORD}"
    --set master.persistence.enabled=true
    --wait
    --timeout 10m0s
  )
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${cmd[@]}")"
    return 0
  fi
  "${cmd[@]}"
}

create_certificates() {
  local manifest
  manifest=$(
    cat <<EOM
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
  local cmd=(
    helm upgrade --install nextcloud bitnami/nextcloud
    --namespace nextcloud
    --create-namespace
    --set fullnameOverride=nextcloud
    --set mariadb.enabled=false
    --set postgresql.enabled=false
    --set redis.enabled=false
    --set nextcloudHost="${LABZ_NEXTCLOUD_HOST}"
    --set ingress.enabled=true
    --set ingress.ingressClassName=traefik
    --set ingress.hostname="${LABZ_NEXTCLOUD_HOST}"
    --set "ingress.tls[0].hosts[0]=${LABZ_NEXTCLOUD_HOST}"
    --set "ingress.tls[0].secretName=labz-apps-tls"
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
    --wait
    --timeout 10m0s
  )
  if [[ ${DRY_RUN} == true ]]; then
    log_info "[DRY-RUN] $(format_command "${cmd[@]}")"
    return 0
  fi
  "${cmd[@]}"
}

install_jellyfin() {
  local manifest
  manifest=$(
    cat <<EOM
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
      securityContext:
        fsGroup: 1000
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

main() {
  parse_args "$@"
  load_environment

  if [[ ! -f ${POSTGRES_VALUES_FILE} ]]; then
    die ${EX_CONFIG} "PostgreSQL values file not found: ${POSTGRES_VALUES_FILE}"
  fi
  if [[ ! -d ${STORAGE_MANIFEST_DIR} ]]; then
    die ${EX_CONFIG} "Storage manifest directory not found: ${STORAGE_MANIFEST_DIR}"
  fi

  require_env_vars \
    LABZ_MINIKUBE_PROFILE LABZ_POSTGRES_DB LABZ_POSTGRES_USER LABZ_POSTGRES_PASSWORD \
    LABZ_REDIS_PASSWORD LABZ_PHP_UPLOAD_LIMIT LABZ_MOUNT_BACKUPS LABZ_MOUNT_MEDIA \
    LABZ_MOUNT_NEXTCLOUD LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST LABZ_TRAEFIK_HOST \
    LABZ_METALLB_RANGE PG_STORAGE_SIZE

  local POSTGRES_DATA_PATH="${LABZ_MOUNT_BACKUPS%/}/postgresql-data"
  local NEXTCLOUD_DATA_PATH="${LABZ_MOUNT_NEXTCLOUD%/}"
  local JELLYFIN_MEDIA_PATH="${LABZ_MOUNT_MEDIA%/}"

  print_context_summary

  if [[ ${CONTEXT_ONLY} == true ]]; then
    ensure_context
    log_info "Context preflight complete"
    return
  fi

  need kubectl helm envsubst || die ${EX_UNAVAILABLE} "kubectl, helm, and envsubst are required"

  ensure_context
  ensure_helm_repo_safe bitnami https://charts.bitnami.com/bitnami

  run_cmd mkdir -p "${POSTGRES_DATA_PATH}" "${NEXTCLOUD_DATA_PATH}" "${JELLYFIN_MEDIA_PATH}"
  export POSTGRES_DATA_PATH NEXTCLOUD_DATA_PATH JELLYFIN_MEDIA_PATH PG_STORAGE_SIZE

  ensure_namespace_safe databases
  ensure_namespace_safe data
  ensure_namespace_safe nextcloud
  ensure_namespace_safe jellyfin

  log_info "Applying hostPath storage manifests"
  local manifest_file
  for manifest_file in "${STORAGE_MANIFEST_DIR}"/*.yaml; do
    [[ -f ${manifest_file} ]] || continue
    log_info "Applying ${manifest_file}"
    apply_manifest_with_envsubst "${manifest_file}"
  done

  clear_lingering_pv_claim_refs

  wait_for_pvc_bound_safe databases postgresql-data
  wait_for_pvc_bound_safe nextcloud nextcloud-data
  wait_for_pvc_bound_safe jellyfin jellyfin-media

  install_postgresql
  install_redis
  create_certificates
  install_nextcloud
  install_jellyfin

  log_info "Deployment summary"
  log_info "  Traefik dashboard: https://${LABZ_TRAEFIK_HOST}/dashboard/"
  log_info "  Nextcloud:         https://${LABZ_NEXTCLOUD_HOST}/"
  log_info "  Jellyfin:          https://${LABZ_JELLYFIN_HOST}/"
  log_info "Use pfSense DNS overrides to point these hosts at an IP from ${LABZ_METALLB_RANGE}."
}

main "$@"
