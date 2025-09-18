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
require_vars LABZ_MINIKUBE_PROFILE LABZ_POSTGRES_VERSION LABZ_POSTGRES_DB \
  LABZ_POSTGRES_USER LABZ_POSTGRES_PASSWORD LABZ_REDIS_PASSWORD \
  LABZ_PHP_UPLOAD_LIMIT LABZ_MOUNT_BACKUPS LABZ_MOUNT_MEDIA \
  LABZ_MOUNT_NEXTCLOUD LABZ_NEXTCLOUD_HOST LABZ_JELLYFIN_HOST \
  LABZ_TRAEFIK_HOST LABZ_METALLB_RANGE PG_STORAGE_SIZE

require_command kubectl helm

log "Switching kubectl context to ${LABZ_MINIKUBE_PROFILE}"
kubectl config use-context "${LABZ_MINIKUBE_PROFILE}" >/dev/null

POSTGRES_DATA_PATH="${LABZ_MOUNT_BACKUPS%/}/postgresql-data"
mkdir -p "${POSTGRES_DATA_PATH}" "${LABZ_MOUNT_NEXTCLOUD}" "${LABZ_MOUNT_MEDIA}"

log "Adding Bitnami Helm repository"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update >/dev/null

log "Configuring PersistentVolumes for hostPath data"
cat <<EOF_PV | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: labz-postgresql-pv
spec:
  capacity:
    storage: ${PG_STORAGE_SIZE}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${POSTGRES_DATA_PATH}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgresql-data
  namespace: data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  resources:
    requests:
      storage: ${PG_STORAGE_SIZE}
  volumeName: labz-postgresql-pv
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: labz-nextcloud-pv
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${LABZ_MOUNT_NEXTCLOUD}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data
  namespace: apps
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  resources:
    requests:
      storage: 1Ti
  volumeName: labz-nextcloud-pv
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: labz-jellyfin-media-pv
spec:
  capacity:
    storage: 5Ti
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: ${LABZ_MOUNT_MEDIA}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-media
  namespace: apps
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  resources:
    requests:
      storage: 5Ti
  volumeName: labz-jellyfin-media-pv
EOF_PV

log "Installing PostgreSQL"
helm upgrade --install postgresql bitnami/postgresql \
  --namespace data \
  --create-namespace \
  --values "${POSTGRES_VALUES_FILE}" \
  --set fullnameOverride=postgresql \
  --set image.tag="${LABZ_POSTGRES_VERSION}" \
  --set global.postgresql.auth.database="${LABZ_POSTGRES_DB}" \
  --set global.postgresql.auth.username="${LABZ_POSTGRES_USER}" \
  --set global.postgresql.auth.password="${LABZ_POSTGRES_PASSWORD}" \
  --wait \
  --timeout 10m0s

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
  namespace: apps
spec:
  secretName: labz-apps-tls
  dnsNames:
    - ${LABZ_TRAEFIK_HOST}
    - ${LABZ_NEXTCLOUD_HOST}
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
  --namespace apps \
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
  --set externalDatabase.host=postgresql.data.svc.cluster.local \
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
  namespace: apps
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
  namespace: apps
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
  namespace: apps
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
