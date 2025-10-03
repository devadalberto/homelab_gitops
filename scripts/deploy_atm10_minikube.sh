#!/usr/bin/env bash
# deploy_atm10_minikube.sh (auto NodePort)
# - Picks a free NodePort (prefers 32065-32075, else scans)
# - Writes nftables redirect 25565 -> <chosen NodePort> (replaces any prior)
# - Deploys ATM10 with AUTO_CURSEFORGE CF_FILE_ID=7058545

set -euo pipefail

NS="atm10"
APP="atm10-minecraft"
DATA_DIR_HOST="/srv/minecraft/atm10/data"
BACKUP_DIR_HOST="/srv/minecraft/atm10/backups"
STORAGE_CAPACITY="50Gi"

CF_FILE_ID="7058545"
REQUEST_CPU="1"
LIMIT_CPU="2"
REQUEST_MEM="4Gi"
LIMIT_MEM="8Gi"
MEMORY_HEAP="6G"
WHITELIST="far,farfer,farferkugel,adalberto"
TZ="America/Los_Angeles"

NEXTCLOUD_URL="DISABLED"
NEXTCLOUD_USER="DISABLED"
NEXTCLOUD_APP_PASSWORD="DISABLED" # pragma: allowlist secret

need() { command -v "$1" >/dev/null 2>&1 || {
  echo "[FATAL] Missing: $1"
  exit 1
}; }
need kubectl
need openssl
if ! command -v nft >/dev/null 2>&1; then
  echo "[INFO] Installing nftables..."
  sudo apt-get update -y && sudo apt-get install -y nftables
fi

# --- choose a free NodePort ---
choose_nodeport() {
  # gather used nodePorts
  mapfile -t USED < <(kubectl get svc -A -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.nodePort}{"\n"}{end}{end}' | grep -E '^[0-9]+$' || true)
  is_used() {
    local p="$1"
    for x in "${USED[@]:-}"; do [[ "$x" == "$p" ]] && return 0; done
    return 1
  }

  # preferred window first
  for p in $(seq 32065 32075); do
    if ! is_used "$p"; then
      echo "$p"
      return
    fi
  done
  # fallback scan
  for p in $(seq 30100 32767); do
    if ! is_used "$p"; then
      echo "$p"
      return
    fi
  done
  return 1
}
NODEPORT="$(choose_nodeport)"
if [[ -z "${NODEPORT:-}" ]]; then
  echo "[FATAL] Could not find a free NodePort."
  exit 1
fi
echo "[INFO] Chosen free NodePort: $NODEPORT (will redirect from 25565)"

# --- secrets ---
if [[ -z "${CF_API_KEY:-}" ]]; then
  read -r -p "Enter CF_API_KEY (input hidden): " -s CF_API_KEY
  echo
fi
[[ -z "${CF_API_KEY:-}" ]] && {
  echo "[FATAL] CF_API_KEY required."
  exit 1
}

RCON_PASSWORD="${RCON_PASSWORD:-}"
[[ -z "$RCON_PASSWORD" ]] && RCON_PASSWORD="$(openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 28)"

echo "[INFO] kube-context: $(kubectl config current-context)"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

sudo mkdir -p "$DATA_DIR_HOST" "$BACKUP_DIR_HOST"
sudo chmod 0775 "$DATA_DIR_HOST" "$BACKUP_DIR_HOST"
sudo chown -R root:root "$DATA_DIR_HOST" "$BACKUP_DIR_HOST"

kubectl -n "$NS" delete secret "${APP}-secrets" --ignore-not-found
kubectl -n "$NS" create secret generic "${APP}-secrets" \
  --from-literal=CF_API_KEY="$CF_API_KEY" \
  --from-literal=RCON_PASSWORD="$RCON_PASSWORD" \
  --from-literal=WHITELIST="$WHITELIST" \
  --from-literal=TZ="$TZ"

kubectl -n "$NS" delete secret "${APP}-nextcloud" --ignore-not-found
kubectl -n "$NS" create secret generic "${APP}-nextcloud" \
  --from-literal=NEXTCLOUD_URL="$NEXTCLOUD_URL" \
  --from-literal=NEXTCLOUD_USER="$NEXTCLOUD_USER" \
  --from-literal=NEXTCLOUD_APP_PASSWORD="$NEXTCLOUD_APP_PASSWORD"

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${APP}-data-pv
spec:
  capacity: { storage: ${STORAGE_CAPACITY} }
  accessModes: [ "ReadWriteOnce" ]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: ["${NODE}"]
  hostPath: { path: "${DATA_DIR_HOST}" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP}-data-pvc
  namespace: ${NS}
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources: { requests: { storage: ${STORAGE_CAPACITY} } }
  storageClassName: ""
  volumeName: ${APP}-data-pv
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${APP}-backups-pv
spec:
  capacity: { storage: ${STORAGE_CAPACITY} }
  accessModes: [ "ReadWriteOnce" ]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  volumeMode: Filesystem
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values: ["${NODE}"]
  hostPath: { path: "${BACKUP_DIR_HOST}" }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP}-backups-pvc
  namespace: ${NS}
spec:
  accessModes: [ "ReadWriteOnce" ]
  resources: { requests: { storage: ${STORAGE_CAPACITY} } }
  storageClassName: ""
  volumeName: ${APP}-backups-pv
EOF

cat <<'EOF' | sed "s#__NS__#${NS}#g; s#__APP__#${APP}#g; s#__REQUEST_CPU__#${REQUEST_CPU}#g; s#__LIMIT_CPU__#${LIMIT_CPU}#g; s#__REQUEST_MEM__#${REQUEST_MEM}#g; s#__LIMIT_MEM__#${LIMIT_MEM}#g; s#__MEMORY_HEAP__#${MEMORY_HEAP}#g; s#__CF_FILE_ID__#${CF_FILE_ID}#g" | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __APP__
  namespace: __NS__
  labels: { app: __APP__ }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: __APP__ } }
  template:
    metadata: { labels: { app: __APP__ } }
    spec:
      securityContext: { fsGroup: 1000 }
      containers:
      - name: server
        image: itzg/minecraft-server:latest
        imagePullPolicy: IfNotPresent
        env:
        - { name: EULA, value: "TRUE" }
        - { name: TYPE, value: "AUTO_CURSEFORGE" }
        - { name: CF_FILE_ID, value: "__CF_FILE_ID__" }
        - name: CF_API_KEY
          valueFrom: { secretKeyRef: { name: __APP__-secrets, key: CF_API_KEY } }
        - { name: MEMORY, value: "__MEMORY_HEAP__" }
        - { name: MAX_PLAYERS, value: "6" }
        - { name: ENABLE_WHITELIST, value: "TRUE" }
        - name: WHITELIST
          valueFrom: { secretKeyRef: { name: __APP__-secrets, key: WHITELIST } }
        - { name: ONLINE_MODE, value: "TRUE" }
        - { name: VIEW_DISTANCE, value: "10" }
        - { name: USE_AIKAR_FLAGS, value: "true" }
        - { name: ENABLE_RCON, value: "true" }
        - name: RCON_PASSWORD
          valueFrom: { secretKeyRef: { name: __APP__-secrets, key: RCON_PASSWORD } }
        - { name: RCON_PORT, value: "25575" }
        - name: TZ
          valueFrom: { secretKeyRef: { name: __APP__-secrets, key: TZ } }
        ports:
        - { name: game, containerPort: 25565, protocol: TCP }
        - { name: rcon, containerPort: 25575, protocol: TCP }
        volumeMounts:
        - { name: data, mountPath: /data }
        resources:
          requests: { cpu: "__REQUEST_CPU__", memory: "__REQUEST_MEM__" }
          limits:   { cpu: "__LIMIT_CPU__",   memory: "__LIMIT_MEM__" }
        readinessProbe:
          tcpSocket: { port: game }
          initialDelaySeconds: 120
          periodSeconds: 15
        livenessProbe:
          tcpSocket: { port: game }
          initialDelaySeconds: 180
          periodSeconds: 30
      volumes:
      - { name: data, persistentVolumeClaim: { claimName: __APP__-data-pvc } }
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP}-svc
  namespace: ${NS}
  labels: { app: ${APP} }
spec:
  type: NodePort
  selector: { app: ${APP} }
  ports:
  - name: game
    port: 25565
    targetPort: 25565
    nodePort: ${NODEPORT}
    protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}-rcon
  namespace: ${NS}
  labels: { app: ${APP} }
spec:
  type: ClusterIP
  selector: { app: ${APP} }
  ports:
  - { name: rcon, port: 25575, targetPort: 25575, protocol: TCP }
EOF

# --- nftables redirect 25565 -> NODEPORT (replace any prior) ---
echo "[INFO] Configuring nftables redirect 25565 -> ${NODEPORT} ..."
sudo systemctl enable --now nftables

sudo nft add table inet nat 2>/dev/null || true
sudo nft 'add chain inet nat prerouting { type nat hook prerouting priority 0; }' 2>/dev/null || true
sudo nft 'add chain inet nat output     { type nat hook output     priority 0; }' 2>/dev/null || true

# remove any existing 25565 redirects
for CH in prerouting output; do
  if sudo nft -a list chain inet nat "$CH" >/dev/null 2>&1; then
    HANDLES=$(sudo nft -a list chain inet nat "$CH" | awk '/tcp dport 25565/ && /redirect to/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
    for H in $HANDLES; do
      sudo nft delete rule inet nat "$CH" handle "$H" || true
    done
  fi
done

# add new ones
sudo nft add rule inet nat prerouting tcp dport 25565 redirect to ${NODEPORT}
sudo nft add rule inet nat output tcp dport 25565 redirect to ${NODEPORT}
sudo sh -c 'nft list ruleset > /etc/nftables.conf'

# --- Backups ---
cat <<'EOF' | sed "s#__NS__#${NS}#g; s#__APP__#${APP}#g" | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: __APP__-backup-daily
  namespace: __NS__
spec:
  schedule: "17 3 * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: alpine:3
            command: ["/bin/sh","-c"]
            args:
              - |
                set -euo pipefail
                TS="$(date +%F_%H%M%S)"
                mkdir -p /backups
                tar -C /data -czf "/backups/world-\${TS}.tgz" .
                ls -1t /backups/world-*.tgz | awk 'NR>7' | xargs -r rm -f
                echo "[OK] Daily backup: /backups/world-\${TS}.tgz"
            volumeMounts:
            - { name: data,    mountPath: /data,    readOnly: true }
            - { name: backups, mountPath: /backups }
          volumes:
          - { name: data,    persistentVolumeClaim: { claimName: __APP__-data-pvc } }
          - { name: backups, persistentVolumeClaim: { claimName: __APP__-backups-pvc } }
EOF

cat <<'EOF' | sed "s#__NS__#${NS}#g; s#__APP__#${APP}#g" | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: __APP__-backup-weekly-nextcloud
  namespace: __NS__
spec:
  schedule: "33 4 * * 0"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 2
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: push
            image: curlimages/curl:8.10.1
            env:
            - name: NEXTCLOUD_URL
              valueFrom: { secretKeyRef: { name: __APP__-nextcloud, key: NEXTCLOUD_URL } }
            - name: NEXTCLOUD_USER
              valueFrom: { secretKeyRef: { name: __APP__-nextcloud, key: NEXTCLOUD_USER } }
            - name: NEXTCLOUD_APP_PASSWORD
              valueFrom: { secretKeyRef: { name: __APP__-nextcloud, key: NEXTCLOUD_APP_PASSWORD } }
            command: ["/bin/sh","-c"]
            args:
              - |
                set -euo pipefail
                if [ "$NEXTCLOUD_URL" = "DISABLED" ] || [ "$NEXTCLOUD_USER" = "DISABLED" ]; then
                  echo "[INFO] Nextcloud disabled; skipping."
                  exit 0
                fi
                LATEST="$(ls -1t /backups/world-*.tgz | head -n1 || true)"
                if [ -z "$LATEST" ]; then
                  echo "[WARN] No backup found to upload."
                  exit 0
                fi
                echo "[INFO] Uploading \$LATEST to \$NEXTCLOUD_URL"
                curl -sSf -u "${NEXTCLOUD_USER}:${NEXTCLOUD_APP_PASSWORD}" -T "$LATEST" "$NEXTCLOUD_URL"
                echo "[OK] Weekly backup uploaded."
            volumeMounts:
            - { name: backups, mountPath: /backups }
          volumes:
          - { name: backups, persistentVolumeClaim: { claimName: __APP__-backups-pvc } }
EOF

echo
echo "======================================================================"
echo "[OK] ATM10 deployed with NodePort: ${NODEPORT}"
echo "RCON_PASSWORD : ${RCON_PASSWORD}"
echo
echo "Router Port-Forward (HB810): WAN TCP/25565 -> 192.168.88.12:25565"
echo "Pi-hole DNS: minecraft.home.arpa -> 192.168.88.12"
echo
echo "Pod logs:"
echo "  kubectl -n ${NS} logs -f deploy/${APP} | sed -n '1,200p'"
echo "RCON list (inside pod):"
echo "  kubectl -n ${NS} exec deploy/${APP} -- rcon-cli --password '${RCON_PASSWORD}' list || true"
echo "======================================================================"
