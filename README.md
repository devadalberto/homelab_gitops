# Homelab GitOps

- Flux + Helm + SOPS + age
- Addons: MetalLB, Traefik, cert-manager, AWX Operator
- Apps: Pi-hole, Nextcloud(Postgres), Jellyfin, Bitwarden, Homepage

## Quick Start

```bash
cp .env.example .env
# Edit passwords, ranges, and mount paths if needed
make up
```

## pfSense DNS overrides

Set overrides in **Services → DNS Resolver → Host Overrides**:

- `traefik.${LABZ_DOMAIN}` → <MetalLB VIP in LABZ_METALLB_RANGE>
- `cloud.${LABZ_DOMAIN}`   → <MetalLB VIP>
- `media.${LABZ_DOMAIN}`   → <MetalLB VIP>

Use a TTL of 300 and ensure pfSense is the DNS handed out by DHCP.

## Tree
```
.
apps
apps/pihole
apps/pihole/sops-secrets
clusters
clusters/minikube
infra
infra/ansible
infra/bootstrap
infra/docs
k8s
k8s/addons
k8s/addons/awx-operator
k8s/addons/cert-manager
k8s/addons/metallb
k8s/addons/traefik
k8s/apps
k8s/apps/bitwarden
k8s/apps/homepage
k8s/apps/jellyfin
k8s/apps/nextcloud
k8s/apps/pihole
k8s/base
k8s/infra
k8s/namespaces
scripts
.sops
_todel_
```

## How to run
1) Ensure minikube is running:
   ```bash
   minikube start --driver=docker
   ```

2) Bootstrap Flux (after you set your git remote):
   ```bash
   flux check --pre
   # Example (adjust your repo):
   # flux bootstrap github --owner <you> --repository homelab_gitops --path clusters/minikube
   ```

## Secrets with SOPS (age)
- Keys in: .sops/age.key
- Example to encrypt:
  ```bash
  sops --encrypt --in-place k8s/apps/nextcloud/values.yaml
  ```
