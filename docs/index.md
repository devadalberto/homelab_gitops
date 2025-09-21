# Homelab GitOps — Uranus

Welcome to the documentation portal for the Uranus homelab GitOps stack. This site is generated with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) and is intended to provide both Day-1 bootstrap guidance and deeper architectural notes for future contributors.

## Day-1 Quickstart

```bash
git clone https://github.com/devadalberto/homelab_gitops.git
cd homelab_gitops
cp .env.example .env
# Edit passwords, ranges, mount paths, and set PF_INSTALLER_SRC to the downloaded pfSense installer (legacy PF_SERIAL_INSTALLER_PATH/PF_ISO_PATH remain fallbacks)
make up
```

`.env.example` defaults to the serial image workflow. Update `PF_INSTALLER_SRC` with your local download location so the automation can stage the media automatically before you run `make up`.
Legacy `PF_SERIAL_INSTALLER_PATH`/`PF_ISO_PATH` variables remain supported for backwards compatibility (use `PF_ISO_PATH` when opting into the VGA build).

The `make up` target first runs `scripts/preflight_and_bootstrap.sh` in preflight mode so host packages, kernel modules, and firewall rules are ready before Minikube is rebuilt. It then hands control to the combined bootstrap workflow in `scripts/uranus_homelab.sh` for cluster bring-up and application deployment.

If you chose `br0`, the host will reboot once, then resume automatically:
- pfSense VM defined with the `pfSense_config` ISO attached so first boot auto-imports `/opt/homelab/pfsense/config/config.xml`.
- `make up` orchestrates Minikube, MetalLB, Traefik, cert-manager, Postgres, backups, AWX, Observability, Django, and Flux end-to-end.

A deeper walk-through of every subsystem, bootstrap dependency, and GitOps controller can be found in the [Architecture](architecture.md) guide. That page also includes Mermaid sequence/state diagrams that are rendered as part of the documentation build.

### Manage encrypted application secrets

Both the AWX admin and Postgres superuser Kubernetes Secrets live in this repository as [SOPS](https://github.com/getsops/sops) manifests and are encrypted for the Age recipient defined in `.sops/.sops.yaml`. To edit either secret:

1. Export the matching Age private key so SOPS can decrypt locally (for example `export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt`).
2. Open the manifest with SOPS (`sops awx/sops-secrets/awx-admin.sops.yaml` or `sops data/postgres/sops-secrets/postgres-superuser.yaml`). SOPS handles the decrypt/edit/re-encrypt cycle automatically when the editor closes.
3. Apply the updated manifest back to the cluster (`kubectl apply -f <path-to-secret>`).

#### Rotate AWX admin credentials

The AWX operator expects the `awx-admin` secret to exist before the instance comes online. When rotating the admin password, generate a new credential, update the `stringData.password` field in `awx/sops-secrets/awx-admin.sops.yaml`, apply the manifest, and then synchronize the running AWX instance: `kubectl -n awx exec deployment/awx-task -- awx-manage changepassword admin '<new-password>'`. Bounce the AWX pods if the operator does not reconcile automatically.

#### Rotate Postgres superuser credentials

The bootstrap Postgres chart consumes `data/postgres/sops-secrets/postgres-superuser.yaml` for the `pg-superuser` secret. When changing the password, ensure the `stringData.postgres-password` field and the `stringData.database-url` connection string stay in sync before applying the manifest.

### Refreshing pfSense bootstrap media

pfSense reads configuration overrides from the secondary CD-ROM labelled `pfSense_config` during its first boot. The ISO lives at `${WORK_ROOT}/pfsense/config/pfSense-config.iso` (defaults to `/opt/homelab/pfsense/config/pfSense-config.iso`). When lab addressing or credentials change, regenerate and reattach the media before starting the VM:

```bash
./pfsense/pf-config-gen.sh   # rebuild config.xml and the pfSense_config ISO (requires genisoimage or mkisofs)
virsh shutdown ${VM_NAME}    # skip if the VM has never been started
./pfsense/pf-bootstrap.sh    # reattach the refreshed ISO; rerun after edits to .env
```

`pf-bootstrap.sh` swaps the ISO automatically for shut-off domains. If the VM is running, stop it first or run the `virsh change-media ${VM_NAME} sdb ${WORK_ROOT}/pfsense/config/pfSense-config.iso --insert --force --config` command manually after the shutdown completes. The helper re-reads `.env` on each invocation, so confirm `PF_INSTALLER_SRC` still references the installer download before triggering a refresh. Legacy `PF_SERIAL_INSTALLER_PATH`/`PF_ISO_PATH` entries are still honored when present (`PF_ISO_PATH` remains the VGA build toggle).

## Environment Variables and Mapping

| Existing var            | Canonical var       | Used by              |
|------------------------ |-------------------- |--------------------- |
| `LAB_DOMAIN_BASE`       | `LABZ_DOMAIN`       | Ingress/hosts        |
| `LAB_CLUSTER_SUB`       | (keep as-is)        | Cluster FQDNs (misc) |
| `METALLB_POOL_START/END`| `LABZ_METALLB_RANGE`| MetalLB AddressPool  |
| `TRAEFIK_LOCAL_IP`      | (derive from VIP)   | Docs only            |
| `PG_BACKUP_HOSTPATH`    | `LABZ_MOUNT_BACKUPS`| Backups              |
| `/srv/*` mounts         | `LABZ_MOUNT_*`      | hostPath PVs         |

After updating the MetalLB fields in `.env`, regenerate the Flux manifest so the
GitOps path and bootstrap helpers agree on the pool range:

```bash
./scripts/render_metallb_pool_manifest.sh --env-file ./.env
```

## Internal CA

Export root CA to trust on clients:

```bash
kubectl -n cert-manager get secret labz-root-ca-secret -o jsonpath='{.data.ca\.crt}' | base64 -d > labz-root-ca.crt
```

## Traefik Dashboard

The Traefik dashboard is published at [https://traefik.labz.home.arpa/dashboard/](https://traefik.labz.home.arpa/dashboard/) behind the `websecure` entry point. The route terminates TLS with the `traefik-dashboard-tls` certificate issued by `labz-ca-issuer`, so install the internal root CA on any workstation before browsing.

Basic authentication protects the dashboard. Use the following credentials when prompted:

| Username | Password           |
| -------- | ------------------ |
| `ops`    | `xOps!Traefik2024` |

## Enabling NAT Examples

pfSense GUI → **Firewall** → **NAT** → **Port Forward** → edit example → uncheck **Disable** → **Save** → **Apply**. Then navigate to **Firewall** → **Rules** → **WAN** → enable the matching pass rule if present.

## Troubleshooting

- MetalLB not advertising? Ensure pfSense LAN is `10.10.0.0/24` and does not overlap with WAN ranges.
- Traefik returning `404`? Check the Ingress class `traefik` and confirm certificate secrets exist.
- AWX pending? Wait for operator rollout; check `kubectl -n awx get pods` for image pulls and migrations.
- Need remote access to troubleshoot without exposing services? Follow the [WireGuard Remote Access (Host-Only)](../README.md#wireguard-remote-access-host-only) steps in the README.

## Working on the Docs

Use `make docs-serve` to preview the site locally. This command regenerates all Mermaid diagrams before starting the MkDocs dev server. The [`docs`](../Makefile) target runs the same pipeline non-interactively, which is also executed inside CI prior to publishing to GitHub Pages.

Refer to the [Documentation Workflow](docs-workflow.md) page for dependency installation tips, Mermaid authoring guidelines, and CI/CD behavior.
