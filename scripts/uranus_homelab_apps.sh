#!/usr/bin/env bash
set -Eeuo pipefail

ASSUME_YES=false
ENV_FILE="./.env"

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

verify_kubectl_context() {
  local expected_context=$1
  local current_context
  if ! current_context=$(kubectl config current-context); then
    echo "Failed to determine the current kubectl context" >&2
    exit 1
  fi
  if [[ ${current_context} != "${expected_context}" ]]; then
    echo "kubectl context mismatch: expected ${expected_context}, got ${current_context}" >&2
    exit 1
  fi
}

verify_cluster_nodes() {
  if ! kubectl get nodes >/dev/null 2>&1; then
    echo "Unable to communicate with the Kubernetes API" >&2
    exit 1
  fi
}

verify_cluster_dns() {
  local pod_name="dns-check-$(date +%s)"
  local timeout_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=(timeout 30s)
  fi
  if ! "${timeout_cmd[@]}" kubectl run "${pod_name}" \
    --image=busybox:1.36 \
    --restart=Never \
    --rm \
    --attach \
    --command \
    -- /bin/sh -c 'nslookup kubernetes.default.svc.cluster.local >/dev/null'; then
    echo "Cluster DNS lookup failed" >&2
    exit 1
  fi
}

verify_cluster_connectivity() {
  verify_kubectl_context "$1"
  verify_cluster_nodes
  verify_cluster_dns
}

ensure_namespace() {
  local namespace=$1
  if ! kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl create namespace "${namespace}" >/dev/null
  fi
}

apply_storage_manifests() {
  local manifest
  local storage_dir=$1
  for manifest in "${storage_dir}"/*.yaml; do
    [[ -f "${manifest}" ]] || continue
    envsubst <"${manifest}" | kubectl apply -f -
  done
}

wait_for_pvc_bound() {
  local namespace=$1
  local pvc_name=$2
  local timeout=${3:-60}
  local end_time=$((SECONDS + timeout))
  local phase

  log "Waiting for PVC ${namespace}/${pvc_name} to reach Bound"
  while (( SECONDS < end_time )); do
    phase=$(kubectl get pvc "${pvc_name}" -n "${namespace}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ ${phase} == "Bound" ]]; then
      log "PVC ${namespace}/${pvc_name} is Bound"
      return 0
    fi
    sleep 5
  done

  log "PVC ${namespace}/${pvc_name} failed to reach Bound within ${timeout}s"
  kubectl describe pvc "${pvc_name}" -n "${namespace}" || true
  return 1
}

wait_for_required_pvcs() {
  local failures=0
  local namespace
  local pvc
  for namespace in databases nextcloud jellyfin; do
    case ${namespace} in
      databases)
        pvc=postgresql-data
        ;;
      nextcloud)
        pvc=nextcloud-data
        ;;
      jellyfin)
        pvc=jellyfin-media
        ;;
    esac
    if ! wait_for_pvc_bound "${namespace}" "${pvc}"; then
      failures=1
    fi
  done

  if (( failures != 0 )); then
    echo "PersistentVolumeClaims failed to reach Bound state" >&2
    exit 1
  fi
}

collect_postgresql_diagnostics() {
  log "Collecting diagnostics for PostgreSQL release"
  helm status postgresql --namespace databases || true
  kubectl get pods,statefulsets,svc -n databases || true
  kubectl describe statefulset postgresql -n databases || true
  kubectl describe pods -n databases || true
  kubectl get events -A --sort-by=.metadata.creationTimestamp || true
}

deploy_postgresql() {
  local max_attempts=3
  local attempt
  local backoff_seconds=10

  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    log "Installing PostgreSQL (attempt ${attempt}/${max_attempts})"
    if helm upgrade --install postgresql bitnami/postgresql \
      --namespace databases \
      --create-namespace \
      --wait \
      --timeout 15m0s \
      --values values/postgresql.yaml \
      --set image.tag="${LABZ_POSTGRES_VERSION}" \
      --set global.postgresql.auth.database="${LABZ_POSTGRES_DB}" \
      --set global.postgresql.auth.username="${LABZ_POSTGRES_USER}" \
      --set global.postgresql.auth.password="${LABZ_POSTGRES_PASSWORD}"; then
      if kubectl -n databases rollout status statefulset/postgresql; then
        log "PostgreSQL rollout completed"
        return 0
      fi
      log "PostgreSQL rollout did not complete successfully"
    else
      log "PostgreSQL installation attempt ${attempt} failed"
    fi

    if (( attempt < max_attempts )); then
      local sleep_time=$((backoff_seconds * attempt))
      log "Retrying PostgreSQL installation in ${sleep_time}s"
      sleep "${sleep_time}"
    else
      collect_postgresql_diagnostics
      exit 1
    fi
  done
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
require_vars LABZ_MINIKUBE_PROFILE LABZ_POSTGRES_VERSION LABZ_POSTGRES_DB \
  LABZ_POSTGRES_USER LABZ_POSTGRES_PASSWORD LABZ_REDIS_PASSWORD \
  LABZ_PHP_UPLOAD_LIMIT LABZ_MOUNT_BACKUPS LABZ_MOUNT_MEDIA \
  LABZ_MOUNT_NEXTCLOUD LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST \
  LABZ_TRAEFIK_HOST LABZ_METALLB_RANGE PG_STORAGE_SIZE

require_command kubectl helm envsubst

log "Switching kubectl context to ${LABZ_MINIKUBE_PROFILE}"
kubectl config use-context "${LABZ_MINIKUBE_PROFILE}" >/dev/null
verify_cluster_connectivity "${LABZ_MINIKUBE_PROFILE}"

POSTGRES_DATA_PATH="${LABZ_MOUNT_BACKUPS%/}/postgresql-data"
export POSTGRES_DATA_PATH
mkdir -p "${POSTGRES_DATA_PATH}" "${LABZ_MOUNT_NEXTCLOUD}" "${LABZ_MOUNT_MEDIA}"

ensure_namespace databases
ensure_namespace nextcloud
ensure_namespace jellyfin

log "Adding Bitnami Helm repository"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Applying hostPath storage manifests"
apply_storage_manifests "k8s/storage"
wait_for_required_pvcs

deploy_postgresql

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
    - ${LABZ_TRAEFIK_HOST}
    - ${LABZ_NEXTCLOUD_HOST}
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
    - ${LABZ_TRAEFIK_HOST}
    - ${LABZ_JELLYFIN_HOST}
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
