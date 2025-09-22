# Reference

This guide aggregates the architecture, operational procedures, and historical notes for the Uranus homelab GitOps stack. Pair it with the [Workflow](workflow.md) overview for reconciliation details and automation entry points.

## Platform Overview

The environment stitches together on-premises virtualization, Kubernetes tooling, and GitOps pipelines so that every environment can be reproduced deterministically. The following diagram highlights the primary subsystems and the traffic flow between them.

![Homelab component overview](diagrams/homelab-overview.svg)

### Network & Edge

- **pfSense CE** supplies DHCP, DNS, and outbound NAT for the homelab VLAN. Firewall port-forward examples remain disabled by default so operators can opt in to each exposure after validating policies.
- **MetalLB** advertises LoadBalancer services within the `10.10.0.0/24` range published by pfSense. The values are templated via environment variables inside `.env` to keep addresses portable between labs.
- **Traefik** terminates TLS using certificates issued by the internal cert-manager hierarchy and provides a default ingress class for workloads.

### Cluster Runtime

- **Minikube** forms the base Kubernetes control plane. Bootstrap scripts configure container runtimes, storage classes, and hostPath directories aligned with the repository layout.
- **Flux** reconciles Helm releases and Kubernetes manifests stored in this Git repository, ensuring the cluster continuously converges towards the desired state.
- **Cert-Manager** provisions a root Certificate Authority and application leaf certs. The root CA export procedure lives in [Internal CA](#internal-ca).

### Stateful Services

- **PostgreSQL (Bitnami chart)** runs in the `data` namespace. A nightly CronJob pushes WAL backups to the hostPath defined by `LABZ_MOUNT_BACKUPS`.
- **Persistent hostPath volumes** for application storage are parameterized through `.env` to align with local disk layout.

### User-Facing Applications

- **AWX** provides Ansible automation inside the `awx` namespace with persistent volumes and TLS termination handled by Traefik.
- **Homepage** publishes the default landing page for the homelab at `https://home.lab-minikube.labz.home.arpa/`, loading its layout from `k8s/apps/homepage/configmap.yaml` and pulling widget credentials (`openweathermap_api_key`, `uptime_kuma_api_key`) from the SOPS-encrypted secret at `apps/homepage/sops-secrets/homepage-secrets.yaml`.
- **Django Multiproject Demo** showcases the platform deployment pipeline, including container image preloading via `apps/django-multiproject/load-image.sh`.
- **Observability stack** is powered by `kube-prometheus-stack`, exposing Grafana, Prometheus, and Alertmanager through Traefik-managed Ingresses.

## Secrets and Credentials

- SOPS/AGE secret placeholders live in the repo (`.sops/`). Actual encrypted files should be stored separately and decrypted only on trusted hosts.
- Export `SOPS_AGE_KEY_FILE` (for example, `export SOPS_AGE_KEY_FILE="$PWD/.sops/age.key"`) before invoking `sops` locally or running Flux bootstrap scripts so the controllers mount the same private key during reconciliation.
- Traefik ingress routes always reference TLS secrets; the repo defaults to the internal CA but can be swapped for ACME with external DNS integration.

### Manage Encrypted Application Secrets

The AWX admin, Postgres superuser, and Pi-hole admin Kubernetes Secrets live in this repository as [SOPS](https://github.com/getsops/sops) manifests and are encrypted for the Age recipient defined in `.sops/.sops.yaml`. To edit any of these secrets:

1. Export the matching Age private key so SOPS can decrypt locally (for example `export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt`).
2. Open the manifest with SOPS (`sops awx/sops-secrets/awx-admin.sops.yaml`, `sops data/postgres/sops-secrets/postgres-superuser.yaml`, or `sops apps/pihole/sops-secrets/admin-secret.yaml`). SOPS handles the decrypt/edit/re-encrypt cycle automatically when the editor closes.
3. Apply the updated manifest back to the cluster (`kubectl apply -f <path-to-secret>`).

#### Rotate AWX Admin Credentials

The AWX operator expects the `awx-admin` secret to exist before the instance comes online. When rotating the admin password, generate a new credential, update the `stringData.password` field in `awx/sops-secrets/awx-admin.sops.yaml`, apply the manifest, and then synchronize the running AWX instance:

```bash
kubectl -n awx exec deployment/awx-task -- awx-manage changepassword admin '<new-password>'
```

Bounce the AWX pods if the operator does not reconcile automatically.

#### Rotate Postgres Superuser Credentials

The bootstrap Postgres chart consumes `data/postgres/sops-secrets/postgres-superuser.yaml` for the `pg-superuser` secret. When changing the password, ensure the `stringData.postgres-password` field and the `stringData.database-url` connection string stay in sync before applying the manifest.

#### Rotate Pi-hole Admin Password

The Pi-hole Helm release references the SOPS-encrypted manifest at `apps/pihole/sops-secrets/admin-secret.yaml` to supply the `pihole-admin` Secret before the chart installs. To change the web UI password:

1. Decrypt and edit the manifest:
   ```bash
   sops apps/pihole/sops-secrets/admin-secret.yaml
   ```
2. Replace the value under `stringData.password` with a new credential and save; SOPS will re-encrypt on exit.
3. Apply the updated secret and restart the release so the deployment consumes the new password:
   ```bash
   kubectl apply -f apps/pihole/sops-secrets/admin-secret.yaml
   kubectl -n pihole rollout restart deployment/pihole
   ```

#### Homepage API Keys

The Homepage dashboard reads its widget credentials from `apps/homepage/sops-secrets/homepage-secrets.yaml`. The secret must define `openweathermap_api_key` for the weather widget and `uptime_kuma_api_key` for the Uptime Kuma status widget referenced in `k8s/apps/homepage/configmap.yaml`.

1. Open the manifest with SOPS:
   ```bash
   sops apps/homepage/sops-secrets/homepage-secrets.yaml
   ```
2. Update the API keys under the `secrets.yaml` document.
3. Save and exit so SOPS re-encrypts the file, then commit the change or apply it manually (`kubectl apply -f apps/homepage/sops-secrets/homepage-secrets.yaml`).


#### Manage Nextcloud Credentials

Flux deploys Nextcloud with the Bitnami chart using three SOPS-encrypted secrets stored under `apps/nextcloud/sops-secrets/`:

- `nextcloud-admin` maps to the Helm values `nextcloudUsername`, `nextcloudPassword`, and `nextcloudEmail` for the initial UI administrator account.【F:apps/nextcloud/sops-secrets/admin-secret.yaml†L1-L24】【F:k8s/apps/nextcloud/helmrelease.yaml†L55-L71】
- `nextcloud-redis` provides the external cache password consumed by `externalCache.password`.【F:apps/nextcloud/sops-secrets/redis-secret.yaml†L1-L18】【F:k8s/apps/nextcloud/helmrelease.yaml†L72-L76】
- `nextcloud-database` carries the PostgreSQL DSN plus discrete host, port, database, username, and password values that feed the chart's `externalDatabase` block and populate the `DATABASE_URL` environment variable exposed to the pod.【F:apps/nextcloud/sops-secrets/database-secret.yaml†L1-L24】【F:k8s/apps/nextcloud/helmrelease.yaml†L77-L104】

Update the credentials by decrypting the manifests with `sops`, editing the `stringData` fields, and applying the files back to the cluster:

```bash
sops apps/nextcloud/sops-secrets/admin-secret.yaml
sops apps/nextcloud/sops-secrets/redis-secret.yaml
sops apps/nextcloud/sops-secrets/database-secret.yaml
kubectl apply -f apps/nextcloud/sops-secrets/
```

Keep the `dsn` string synchronized with the individual host/port/username/password entries so the HelmRelease renders consistent values. Adjust the ingress host, TLS mapping, and upload limit in `k8s/apps/nextcloud/helmrelease.yaml` if your lab uses a different FQDN or quota than the defaults committed to Git.【F:k8s/apps/nextcloud/helmrelease.yaml†L25-L54】


### Grafana Admin Credential Management

Grafana is deployed through the `kube-prometheus-stack` chart. The admin credentials are stored in the SOPS-encrypted manifest at `observability/sops-secrets/grafana-admin.yaml`.

#### Prerequisites

1. Install [SOPS](https://github.com/getsops/sops) on your workstation.
2. Import the **Homelab SOPS** GPG key (`06D8D7726588CB103AE9717413BF4A9EA7B7C3F8`) from the team credential vault into your local keyring. This key is **not** stored in the repository; request access through the normal secure channel if it is not already present.

#### Retrieve the Password

```bash
# Decrypt the manifest and print the admin credentials
sops -d observability/sops-secrets/grafana-admin.yaml \
  | yq '.stringData["admin-user"] + ":" + .stringData["admin-password"]' -r
```

#### Rotate the Password

1. Open the manifest with `sops`:
   ```bash
   sops observability/sops-secrets/grafana-admin.yaml
   ```
2. Replace the value under `stringData.admin-password` with a new random password. The helper below generates a 32-character value:
   ```bash
   python - <<'PY'
   import secrets, string
   alphabet = string.ascii_letters + string.digits + '!@#$%^&*()-_=+'
   print(''.join(secrets.choice(alphabet) for _ in range(32)))
   PY
   ```
3. Save and exit; `sops` will re-encrypt the document automatically.
4. Commit the updated secret and let Flux reconcile, or apply it manually if you need the change immediately:
   ```bash
   kubectl apply -f observability/sops-secrets/grafana-admin.yaml
   ```

#### Why This Matters

The chart values file (`observability/kps-values.yaml`) points Grafana at the `grafana-admin` Secret via `grafana.admin.existingSecret`. This keeps credentials out of Git history while still allowing GitOps workflows to manage the rendered Secret manifest.

### Internal CA

Export the root CA to trust on clients:

```bash
kubectl -n cert-manager get secret labz-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > labz-root-ca.crt
```

## pfSense and Networking

### Refreshing pfSense Bootstrap Media

pfSense reads configuration overrides from the secondary CD-ROM labelled `pfSense_config` during its first boot. The ISO lives at `${WORK_ROOT}/pfsense/config/pfSense-config.iso` (defaults to `/opt/homelab/pfsense/config/pfSense-config.iso`). When lab addressing or credentials change, regenerate and reattach the media before starting the VM:

```bash
./pfsense/pf-config-gen.sh   # rebuild config.xml and the pfSense_config ISO (requires genisoimage or mkisofs)
virsh shutdown ${VM_NAME}    # skip if the VM has never been started
sudo ./scripts/pf-ztp.sh --env-file ./.env
```

`pf-ztp.sh` swaps both the installer disk and config ISO, inserting media live when possible. If the VM is running and libvirt refuses a hot change, stop it first or run `virsh change-media ${VM_NAME} sdy ${WORK_ROOT}/pfsense/config/pfSense-config.iso --insert --force --config` manually after the shutdown completes. The helper re-reads `.env` on each invocation, so confirm `PF_INSTALLER_SRC` still references the installer download before triggering a refresh. Legacy `PF_SERIAL_INSTALLER_PATH`/`PF_ISO_PATH` entries are still honored when present (`PF_ISO_PATH` remains the VGA build toggle).

### Enabling NAT Examples

pfSense GUI → **Firewall** → **NAT** → **Port Forward** → edit example → uncheck **Disable** → **Save** → **Apply**. Then navigate to **Firewall** → **Rules** → **WAN** → enable the matching pass rule if present.

## Configuration Reference

### Environment Variables and Mapping

| Existing var            | Canonical var       | Used by              |
|------------------------ |-------------------- |--------------------- |
| `LAB_DOMAIN_BASE`       | `LABZ_DOMAIN`       | Ingress/hosts        |
| `LAB_CLUSTER_SUB`       | (keep as-is)        | Cluster FQDNs (misc) |
| `METALLB_POOL_START/END`| `LABZ_METALLB_RANGE`| MetalLB AddressPool  |
| `TRAEFIK_LOCAL_IP`      | (derive from VIP)   | Docs only            |
| `PG_BACKUP_HOSTPATH`    | `LABZ_MOUNT_BACKUPS`| Backups              |
| `/srv/*` mounts         | `LABZ_MOUNT_*`      | hostPath PVs         |

#### Jellyfin configuration

The Jellyfin overlay sources runtime values from the `jellyfin-config` ConfigMap and the SOPS-managed `jellyfin-api` Secret. Update `k8s/apps/jellyfin/configmap.yaml` when the timezone, published URL, or media mount path change, and edit `k8s/apps/jellyfin/sops-secrets/jellyfin-api.yaml` with the Age key to rotate the API token exposed as `JELLYFIN_API_KEY` in the deployment.【F:k8s/apps/jellyfin/configmap.yaml†L1-L9】【F:k8s/apps/jellyfin/sops-secrets/jellyfin-api.yaml†L1-L29】【F:k8s/apps/jellyfin/deployment.yaml†L1-L42】

After updating the MetalLB fields in `.env`, regenerate the Flux manifest so the GitOps path and bootstrap helpers agree on the pool range:

```bash
./scripts/render_metallb_pool_manifest.sh --env-file ./.env
```

### Traefik Dashboard

The Traefik dashboard is published at [https://traefik.labz.home.arpa/dashboard/](https://traefik.labz.home.arpa/dashboard/) behind the `websecure` entry point. The route terminates TLS with the `traefik-dashboard-tls` certificate issued by `labz-ca-issuer`, so install the internal root CA on any workstation before browsing.

Basic authentication protects the dashboard. Use the following credentials when prompted:

| Username | Password           |
| -------- | ------------------ |
| `ops`    | `xOps!Traefik2024` |

## Backup & Disaster Recovery

- PostgreSQL backups are scheduled by the CronJob in `data/postgres/backup-cron.yaml`.
- HostPath directories are prepared by `scripts/uranus_homelab.sh`, which can optionally wipe and recreate volumes for a clean re-provisioning.
- To restore, re-run the bootstrap scripts (`make up`) and re-apply the saved secrets using Flux or manual `kubectl` commands.

## Extending the Platform

- Add new apps by creating namespaces in `apps/` and referencing them inside the main `Makefile` or Flux `kustomizations`.
- Leverage the documentation pipeline described in [Workflow](workflow.md) to record decisions, diagrams, and operational runbooks.
- Use the GitHub Pages deployment to surface the latest diagrams and Markdown whenever changes merge into `main`.

## Changelog

### 2025-09-20T00:00:00.000000Z
- Extended the GitOps CI workflow with a cached lint job that runs ShellCheck, yamllint, and kubeconform before manifest validation.
- Documented how to invoke the lint suite locally via `make fmt`/`pre-commit run --all-files` so contributors can mirror the CI checks.

### 2025-09-19T00:00:00.000000Z
- Documented a host-only WireGuard workflow in the README, including package installation, key management, sample `wg0.conf`, router/VPS considerations, client configuration, and verification guidance for the `192.168.88.0/24` overlay.
- Linked troubleshooting content to the new remote access guidance so runbooks point operators at the same procedure.

### 2025-09-18T00:00:00.000000Z
- Recorded current release cadence and pinned the GitOps stack to the n-1 builds exercised in testing: Kubernetes v1.31.3, MetalLB 0.14.7, Traefik 27.0.2, cert-manager 1.16.3, Bitnami PostgreSQL 16.2.6, kube-prometheus-stack 65.5.0, and AWX operator 2.20.0.
- Updated the Flux CLI bootstrap helper to install v2.3.0 so local environments reconcile with the same binary verified in automation.
- Refreshed documentation to note the latest upstream versions alongside the pinned releases for easier future upgrades.

### 2025-09-17T08:00:00.000000Z
- Pin Flux-managed chart versions to the builds exercised in automation: MetalLB 0.14.5, cert-manager 1.15.3, and Traefik 26.0.0.
- Document the Helm chart upgrade workflow (bump `k8s/addons/*/release.yaml`, stage with `make up`/`scripts/uranus_homelab_one.sh`, then update docs) to keep production in lockstep with staging.
- Wire Flux `dependsOn` for Traefik so upgrades wait on MetalLB and cert-manager health, surfacing dependency issues earlier.

### 2025-09-10T04:47:38.065634Z
- Restructured repo to modular stages (Makefile).
- Added `bootstrap.sh` with br0 default + safe reboot/resume.
- pfSense CE 2.8.0 ISO URL; config.xml generator with labz domain + NAT examples (disabled).
- Minikube + MetalLB + Traefik + cert-manager internal CA.
- Postgres with 7-day nightly backups to hostPath.
- AWX (small), kube-prometheus-stack, Django multiproject app.
- Flux controllers installed (no remote Git).
