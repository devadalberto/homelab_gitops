#!/usr/bin/env bash
set -Eeuo pipefail

ASSUME_YES=false
ENV_FILE="./.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POSTGRES_VALUES_FILE="${REPO_ROOT}/values/postgresql.yaml"

if [[ ! -f "${POSTGRES_VALUES_FILE}" ]]; then
  echo "PostgreSQL values file not found: ${POSTGRES_VALUES_FILE}" >&2
  exit 1
fi

usage() {
  cat <<'USAGE'
Usage: uranus_homelab_apps.sh [--env-file PATH] [--assume-yes]

Deploys Postgres, Redis, Nextcloud, and Jellyfin workloads into the Uranus homelab cluster.
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%F %T')" "$*"
}

require_command() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "Required command not found: ${cmd}" >&2
      exit 1
    fi
  done
}

load_env_file() {
  local file=$1
  if [[ ! -f "${file}" ]]; then
    echo "Environment file not found: ${file}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a
  source "${file}"
  set +a
}

require_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if [[ ${#missing[@]} -ne 0 ]]; then
    echo "Missing required variables: ${missing[*]}" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --assume-yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

load_env_file "${ENV_FILE}"
require_vars LABZ_MINIKUBE_PROFILE LABZ_POSTGRES_DB \
  LABZ_POSTGRES_USER LABZ_POSTGRES_PASSWORD LABZ_REDIS_PASSWORD \
  LABZ_PHP_UPLOAD_LIMIT LABZ_MOUNT_BACKUPS LABZ_MOUNT_MEDIA \
  LABZ_MOUNT_NEXTCLOUD LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST \
  LABZ_TRAEFIK_HOST LABZ_METALLB_RANGE PG_STORAGE_SIZE

require_command kubectl helm envsubst

ensure_namespaces() {
  local ns
  for ns in "$@"; do
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
}

verify_current_context() {
  local current_context
  if ! current_context=$(kubectl config current-context 2>/dev/null); then
    echo "Failed to determine the current kubectl context" >&2
    exit 1
  fi
  if [[ "${current_context}" != "${LABZ_MINIKUBE_PROFILE}" ]]; then
    echo "kubectl current-context '${current_context}' does not match expected context '${LABZ_MINIKUBE_PROFILE}'" >&2
    exit 1
  fi
}

verify_cluster_nodes() {
  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "Unable to list cluster nodes via kubectl" >&2
    exit 1
  fi
}

verify_cluster_dns() {
  if ! kubectl run dns-check --rm --restart=Never --image=busybox:1.36.1 \
    --command -- nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    echo "BusyBox DNS lookup for kubernetes.default.svc.cluster.local failed" >&2
    exit 1
  fi
}

verify_cluster_connectivity() {
  log "Verifying kubectl current-context"
  verify_current_context
  log "Verifying cluster node access"
  verify_cluster_nodes
  log "Verifying in-cluster DNS resolution"
  verify_cluster_dns
}

apply_manifest_with_envsubst() {
  local manifest=$1
  envsubst <"${manifest}" | kubectl apply -f -
}

deploy_hostpath_storage() {
  local manifest
  for manifest in "${STORAGE_MANIFEST_DIR}"/*.yaml; do
    if [[ -f "${manifest}" ]]; then
      log "Applying storage manifest ${manifest}"
      apply_manifest_with_envsubst "${manifest}"
    fi
  done
}

wait_for_pvc_bound() {
  local namespace=$1
  local pvc_name=$2
  local pv_label_selector=$3
  local timeout=${4:-60}
  local interval=5
  local elapsed=0

  log "Waiting for PVC ${namespace}/${pvc_name} to become Bound"
  while (( elapsed < timeout )); do
    local phase
    phase=$(kubectl -n "${namespace}" get pvc "${pvc_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "${phase}" == "Bound" ]]; then
      log "PVC ${namespace}/${pvc_name} is Bound"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "PVC ${namespace}/${pvc_name} failed to reach Bound within ${timeout} seconds" >&2
  kubectl -n "${namespace}" describe pvc "${pvc_name}" || true
  if [[ -n "${pv_label_selector}" ]]; then
    kubectl describe pv -l "${pv_label_selector}" || true
  fi
  exit 1
}

wait_for_required_pvcs() {
  wait_for_pvc_bound databases postgresql-data 'pv-role=postgresql-data'
  wait_for_pvc_bound nextcloud nextcloud-data 'pv-role=nextcloud-data'
  wait_for_pvc_bound jellyfin jellyfin-media 'pv-role=jellyfin-media'
}

collect_postgresql_diagnostics() {
  log "Collecting PostgreSQL diagnostics"
  helm status postgresql --namespace databases || true
  kubectl -n databases get pods,pvc,svc,statefulset || true
  kubectl -n databases describe statefulset postgresql || true
  kubectl -n databases describe pods -l app.kubernetes.io/name=postgresql || true
  kubectl get events --all-namespaces --sort-by='.metadata.creationTimestamp' | tail -n 50 || true
}

install_postgresql_with_retry() {
  local attempt delay=5
  for attempt in 1 2 3; do
    log "Installing PostgreSQL (attempt ${attempt}/3)"
    if helm upgrade --install postgresql bitnami/postgresql \
      --namespace databases \
      --create-namespace \
      --wait \
      --timeout 15m0s \
      --values "${POSTGRES_VALUES_FILE}" \
      --set fullnameOverride=postgresql \
      --set global.postgresql.auth.database="${LABZ_POSTGRES_DB}" \
      --set global.postgresql.auth.username="${LABZ_POSTGRES_USER}" \
      --set global.postgresql.auth.password="${LABZ_POSTGRES_PASSWORD}"; then
      log "PostgreSQL installed successfully"
      return 0
    fi

    log "PostgreSQL installation attempt ${attempt} failed"
    collect_postgresql_diagnostics
    if (( attempt < 3 )); then
      sleep "${delay}"
      delay=$((delay * 2))
    else
      echo "PostgreSQL installation failed after ${attempt} attempts" >&2
      exit 1
    fi
  done
}

log "Switching kubectl context to ${LABZ_MINIKUBE_PROFILE}"
kubectl config use-context "${LABZ_MINIKUBE_PROFILE}" >/dev/null

verify_cluster_connectivity

POSTGRES_DATA_PATH="${LABZ_MOUNT_BACKUPS%/}/postgresql-data"
NEXTCLOUD_DATA_PATH="${LABZ_MOUNT_NEXTCLOUD%/}"
JELLYFIN_MEDIA_PATH="${LABZ_MOUNT_MEDIA%/}"
STORAGE_MANIFEST_DIR="${REPO_ROOT}/k8s/storage"

mkdir -p "${POSTGRES_DATA_PATH}" "${NEXTCLOUD_DATA_PATH}" "${JELLYFIN_MEDIA_PATH}"

export POSTGRES_DATA_PATH NEXTCLOUD_DATA_PATH JELLYFIN_MEDIA_PATH PG_STORAGE_SIZE

if [[ ! -d "${STORAGE_MANIFEST_DIR}" ]]; then
  echo "Storage manifest directory not found: ${STORAGE_MANIFEST_DIR}" >&2
  exit 1
fi

log "Ensuring application namespaces exist"
ensure_namespaces databases nextcloud jellyfin

log "Adding Bitnami Helm repository"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Configuring PersistentVolumes for hostPath data"
deploy_hostpath_storage
wait_for_required_pvcs

install_postgresql_with_retry
log "Waiting for PostgreSQL rollout to complete"
kubectl -n databases rollout status statefulset/postgresql

log "Installing Redis"
helm upgrade --install redis bitnami/redis \
  --namespace data \
  --create-namespace \
  --set fullnameOverride=redis \
  --set architecture=standalone \
  --set auth.enabled=true \
  --set auth.password="${LABZ_REDIS_PASSWORD}" \
  --set master.persistence.enabled=true \
  --wait \
  --timeout 10m0s

log "Creating shared TLS certificates"
cat <<EOF_CERT | kubectl apply -f -
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
EOF_CERT

log "Deploying Nextcloud"
helm upgrade --install nextcloud bitnami/nextcloud \
  --namespace nextcloud \
  --create-namespace \
  --set fullnameOverride=nextcloud \
  --set mariadb.enabled=false \
  --set postgresql.enabled=false \
  --set redis.enabled=false \
  --set nextcloudHost="${LABZ_NEXTCLOUD_HOST}" \
  --set ingress.enabled=true \
  --set ingress.ingressClassName=traefik \
  --set ingress.hostname="${LABZ_NEXTCLOUD_HOST}" \
  --set ingress.tls[0].hosts[0]="${LABZ_NEXTCLOUD_HOST}" \
  --set ingress.tls[0].secretName=labz-apps-tls \
  --set persistence.enabled=true \
  --set persistence.existingClaim=nextcloud-data \
  --set externalDatabase.enabled=true \
  --set externalDatabase.type=postgresql \
  --set externalDatabase.host=postgresql.databases.svc.cluster.local \
  --set externalDatabase.port=5432 \
  --set externalDatabase.user="${LABZ_POSTGRES_USER}" \
  --set externalDatabase.password="${LABZ_POSTGRES_PASSWORD}" \
  --set externalDatabase.database="${LABZ_POSTGRES_DB}" \
  --set externalCache.enabled=true \
  --set externalCache.host=redis-master.data.svc.cluster.local \
  --set externalCache.port=6379 \
  --set externalCache.password="${LABZ_REDIS_PASSWORD}" \
  --set phpClient.maxUploadSize="${LABZ_PHP_UPLOAD_LIMIT}" \
  --set podSecurityContext.enabled=true \
  --set podSecurityContext.fsGroup=33 \
  --set containerSecurityContext.enabled=true \
  --set containerSecurityContext.runAsUser=33 \
  --set containerSecurityContext.runAsGroup=33 \
  --wait \
  --timeout 10m0s

log "Deploying Jellyfin"
cat <<EOF_JELLY | kubectl apply -f -
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
EOF_JELLY

log "Deployment summary"
cat <<SUMMARY
Traefik dashboard: https://${LABZ_TRAEFIK_HOST}/dashboard/
Nextcloud:         https://${LABZ_NEXTCLOUD_HOST}/
Jellyfin:          https://${LABZ_JELLYFIN_HOST}/
Use pfSense DNS overrides to point these hosts at an IP from ${LABZ_METALLB_RANGE}.
SUMMARY
