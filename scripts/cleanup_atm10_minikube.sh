#!/usr/bin/env bash
# cleanup_atm10_minikube.sh
# Nuke the ATM10 K8s objects and nftables redirect.
# Flags:
#   --wipe-world : also deletes /srv/minecraft/atm10/{data,backups} contents
#   --drop-ns    : also deletes the atm10 namespace

set -euo pipefail
NS="atm10"
APP="atm10-minecraft"
DATA_DIR_HOST="/srv/minecraft/atm10/data"
BACKUP_DIR_HOST="/srv/minecraft/atm10/backups"

WIPE_WORLD="no"
DROP_NS="no"

# ---- parse args (fixed) ----
while [[ $# -gt 0 ]]; do
  case "$1" in
  --wipe-world)
    WIPE_WORLD="yes"
    shift
    ;;
  --drop-ns)
    DROP_NS="yes"
    shift
    ;;
  *)
    echo "Unknown flag: $1"
    exit 1
    ;;
  esac
done

echo "[INFO] Services using NodePorts (for awareness):"
kubectl get svc -A -o wide | awk 'NR==1 || $6 ~ /[0-9]+:[0-9]+\/TCP/ {print $0}'
echo

echo "[INFO] Deleting K8s objects in namespace ${NS} (ignore not found)..."
kubectl -n "$NS" delete deploy "$APP" --ignore-not-found
kubectl -n "$NS" delete svc "$APP-svc" "$APP-rcon" --ignore-not-found
kubectl -n "$NS" delete cronjob "$APP-backup-daily" "$APP-backup-weekly-nextcloud" --ignore-not-found
kubectl -n "$NS" delete secret "$APP-secrets" "$APP-nextcloud" --ignore-not-found
kubectl -n "$NS" delete pvc "$APP-data-pvc" "$APP-backups-pvc" --ignore-not-found

echo "[INFO] Deleting PVs (cluster-scoped)..."
kubectl delete pv "$APP-data-pv" "$APP-backups-pv" --ignore-not-found

if [[ "$DROP_NS" == "yes" ]]; then
  echo "[INFO] Deleting namespace ${NS} ..."
  kubectl delete ns "$NS" --ignore-not-found
fi

echo "[INFO] Removing nftables redirect rules for tcp/25565 (if present)..."
if command -v nft >/dev/null 2>&1; then
  sudo systemctl enable --now nftables || true
  for CH in prerouting output; do
    if sudo nft -a list chain inet nat "$CH" >/dev/null 2>&1; then
      HANDLES=$(sudo nft -a list chain inet nat "$CH" | awk '/tcp dport 25565/ && /redirect to/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
      for H in $HANDLES; do
        sudo nft delete rule inet nat "$CH" handle "$H" || true
      done
    fi
  done
  sudo sh -c 'nft list ruleset > /etc/nftables.conf' || true
else
  echo "[WARN] nft command not found; skipping nftables cleanup."
fi

if [[ "$WIPE_WORLD" == "yes" ]]; then
  echo "[DANGER] Wiping world/backups data at:"
  echo "  $DATA_DIR_HOST"
  echo "  $BACKUP_DIR_HOST"
  sudo rm -rf "${DATA_DIR_HOST:?}/"* "${BACKUP_DIR_HOST:?}/"* || true
fi

echo "[DONE] Cleanup complete."
