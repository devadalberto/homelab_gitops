# homelab_gitops — Uranus

## Day-1 Quickstart
```bash
git clone https://github.com/devadalberto/homelab_gitops.git
cd homelab_gitops
cp .env.example .env
# Edit passwords, ranges, and mount paths if needed
make up
```

If you chose `br0`, host will reboot once, then resume automatically:
- pfSense VM defined, import `config.xml` from `/opt/homelab/pfsense/config/config.xml`
- `make all` brings up Minikube + MetalLB + Traefik + cert-manager + Postgres+backups + AWX + Observability + Django + Flux.

## Env variables and mapping

| Existing var                 | Canonical var       | Used by              |
|-----------------------------|---------------------|----------------------|
| LAB_DOMAIN_BASE             | LABZ_DOMAIN         | Ingress/hosts        |
| LAB_CLUSTER_SUB             | (keep as-is)        | Cluster FQDNs (misc) |
| METALLB_POOL_START/END      | LABZ_METALLB_RANGE  | MetalLB AddressPool  |
| TRAEFIK_LOCAL_IP            | (derive from VIP)   | Docs only            |
| PG_BACKUP_HOSTPATH          | LABZ_MOUNT_BACKUPS  | Backups              |
| /srv/* mounts               | LABZ_MOUNT_*        | hostPath PVs         |

## Internal CA
Export root CA to trust on clients:
```bash
kubectl -n cert-manager get secret labz-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > labz-root-ca.crt
```

## Enabling NAT examples
pfSense GUI → Firewall → NAT → Port Forward → edit example → uncheck **Disable** → Save → Apply.
Then Firewall → Rules → WAN → enable matching pass rule if present.

## Troubleshooting
- MetalLB not advertising? Ensure pfSense LAN is `10.10.0.0/24` and no overlap with WAN.
- Traefik 404? Check Ingress class `traefik` and certificate secrets existence.
- AWX pending? Wait for operator rollout; check `kubectl -n awx get pods`.
