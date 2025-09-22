# Operations Reference

Use this reference to dive deeper into the Uranus homelab architecture,
credential management practices, and operational runbooks.

## Platform Architecture

The Uranus homelab stitches together on-premises virtualization,
Kubernetes tooling, and GitOps pipelines so every environment can be
reproduced deterministically. The overview diagram highlights the primary
subsystems and traffic flow between them.

![Homelab component overview](diagrams/homelab-overview.svg)

### Network & Edge

- **pfSense CE** supplies DHCP, DNS, and outbound NAT for the homelab VLAN.
  Firewall port-forward examples remain disabled by default so operators
  can opt in to each exposure after validating policies.
- **MetalLB** advertises LoadBalancer services within the `10.10.0.0/24`
  range published by pfSense. The values are templated via environment
  variables inside `.env` to keep addresses portable between labs.
- **Traefik** terminates TLS using certificates issued by the internal
  cert-manager hierarchy and provides a default ingress class for
  workloads.

### Cluster Runtime

- **Minikube** forms the base Kubernetes control plane. Bootstrap scripts
  configure container runtimes, storage classes, and hostPath directories
  aligned with the repository layout.
- **Flux** reconciles Helm releases and Kubernetes manifests stored in
  this Git repository, ensuring the cluster continuously converges toward
  the desired state.
- **Cert-manager** provisions a root Certificate Authority and application
  leaf certificates. The root CA can be exported through the command in
  [Certificates](#certificates).

### Stateful Services

- **PostgreSQL (Bitnami chart)** runs in the `data` namespace. A nightly
  `CronJob` pushes WAL backups to the hostPath defined by
  `LABZ_MOUNT_BACKUPS`.
- **Persistent hostPath volumes** for application storage are
  parameterized through `.env` to align with local disk layout.

### User-Facing Applications

- **AWX** provides Ansible automation inside the `awx` namespace with
  persistent volumes and TLS termination handled by Traefik.
- **Django Multiproject Demo** showcases the platform deployment pipeline,
  including container image preloading via
  `apps/django-multiproject/load-image.sh`.
- **Observability stack** is powered by `kube-prometheus-stack`, exposing
  Grafana, Prometheus, and Alertmanager through Traefik-managed Ingresses.

## Secrets & Credential Management

Sensitive manifests live in the repository as
[SOPS](https://github.com/getsops/sops) files encrypted for the Age
recipient defined in `.sops/.sops.yaml`. To edit or rotate credentials:

1. Export the matching Age private key so SOPS can decrypt locally
   (for example `export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt`).
2. Open the manifest with SOPS (`sops awx/sops-secrets/awx-admin.sops.yaml`
   or `sops data/postgres/sops-secrets/postgres-superuser.yaml`). SOPS
   handles the decrypt/edit/re-encrypt cycle automatically when the editor
   closes.
3. Apply the updated manifest back to the cluster (`kubectl apply -f
   <path-to-secret>`).

### AWX Admin Credentials

The AWX operator expects the `awx-admin` secret to exist before the
instance comes online. When rotating the admin password, generate a new
credential, update the `stringData.password` field in
`awx/sops-secrets/awx-admin.sops.yaml`, apply the manifest, and then
synchronize the running AWX instance:

```bash
kubectl -n awx exec deployment/awx-task -- \
  awx-manage changepassword admin '<new-password>'
```

Bounce the AWX pods if the operator does not reconcile automatically.

### PostgreSQL Superuser

The bootstrap PostgreSQL chart consumes
`data/postgres/sops-secrets/postgres-superuser.yaml` for the
`pg-superuser` secret. When changing the password, ensure the
`stringData.postgres-password` field and the `stringData.database-url`
connection string stay in sync before applying the manifest.

### Grafana Admin Credential Management

Grafana is deployed through the `kube-prometheus-stack` chart. The admin
credentials are stored in the SOPS-encrypted manifest at
`observability/sops-secrets/grafana-admin.yaml`.

#### Retrieve the password

```bash
# Decrypt the manifest and print the admin credentials
sops -d observability/sops-secrets/grafana-admin.yaml \
  | yq '.stringData["admin-user"] + ":" + .stringData["admin-password"]' -r
```

#### Rotate the password

1. Open the manifest with `sops`:
   ```bash
   sops observability/sops-secrets/grafana-admin.yaml
   ```
2. Replace the value under `stringData.admin-password` with a new random
   password. The helper below generates a 32-character value:
   ```bash
   python - <<'PY'
   import secrets, string
   alphabet = string.ascii_letters + string.digits + '!@#$%^&*()-_=+'
   print(''.join(secrets.choice(alphabet) for _ in range(32)))
   PY
   ```
3. Save and exit; `sops` re-encrypts the document automatically.
4. Commit the updated secret and let Flux reconcile, or apply it manually
   if you need the change immediately:
   ```bash
   kubectl apply -f observability/sops-secrets/grafana-admin.yaml
   ```

The chart values file (`observability/kps-values.yaml`) points Grafana at
the `grafana-admin` secret via `grafana.admin.existingSecret`. This keeps
credentials out of Git history while still allowing GitOps workflows to
manage the rendered secret.

## pfSense Media & Network Tasks

pfSense reads configuration overrides from the secondary CD-ROM labelled
`pfSense_config` during its first boot. The ISO lives at
`${WORK_ROOT}/pfsense/config/pfSense-config.iso` (defaults to
`/opt/homelab/pfsense/config/pfSense-config.iso`). When lab addressing or
credentials change, regenerate and reattach the media before starting the
VM:

```bash
./pfsense/pf-config-gen.sh   # rebuild config.xml and the pfSense_config ISO (requires genisoimage or mkisofs)
virsh shutdown ${VM_NAME}    # skip if the VM has never been started
./pfsense/pf-bootstrap.sh    # reattach the refreshed ISO; rerun after edits to .env
```

`pf-bootstrap.sh` swaps the ISO automatically for shut-off domains. If
the VM is running, stop it first or run the `virsh change-media ${VM_NAME}
 sdb ${WORK_ROOT}/pfsense/config/pfSense-config.iso --insert --force --config`
command manually after the shutdown completes. The helper re-reads `.env`
on each invocation, so confirm `PF_INSTALLER_SRC` still references the
installer download before triggering a refresh. Legacy
`PF_SERIAL_INSTALLER_PATH`/`PF_ISO_PATH` entries are still honored when
present (`PF_ISO_PATH` remains the VGA build toggle).

### Enabling NAT Examples

pfSense GUI → **Firewall** → **NAT** → **Port Forward** → edit example →
uncheck **Disable** → **Save** → **Apply**. Then navigate to
**Firewall** → **Rules** → **WAN** → enable the matching pass rule if
present.

## Certificates

Export the internal root CA to trust on client devices:

```bash
kubectl -n cert-manager get secret labz-root-ca-secret -o \
  jsonpath='{.data.ca\.crt}' | base64 -d > labz-root-ca.crt
```

## Environment Variables and Mapping

| Existing var             | Canonical var        | Used by              |
|------------------------- |--------------------- |--------------------- |
| `LAB_DOMAIN_BASE`        | `LABZ_DOMAIN`        | Ingress/hosts        |
| `LAB_CLUSTER_SUB`        | (keep as-is)         | Cluster FQDNs (misc) |
| `METALLB_POOL_START/END` | `LABZ_METALLB_RANGE` | MetalLB AddressPool  |
| `TRAEFIK_LOCAL_IP`       | (derive from VIP)    | Docs only            |
| `PG_BACKUP_HOSTPATH`     | `LABZ_MOUNT_BACKUPS` | Backups              |
| `/srv/*` mounts          | `LABZ_MOUNT_*`       | hostPath PVs         |

## Traefik Dashboard Access

The Traefik dashboard is published at
[https://traefik.labz.home.arpa/dashboard/](https://traefik.labz.home.arpa/dashboard/)
behind the `websecure` entry point. The route terminates TLS with the
`traefik-dashboard-tls` certificate issued by `labz-ca-issuer`, so install
the internal root CA on any workstation before browsing.

Basic authentication protects the dashboard. Use the following
credentials when prompted:

| Username | Password           |
|----------|--------------------|
| `ops`    | `xOps!Traefik2024` |

## Backup & Disaster Recovery

- PostgreSQL backups are scheduled by the CronJob in
  `data/postgres/backup-cron.yaml`.
- HostPath directories are prepared by `scripts/uranus_homelab.sh`, which
  can optionally wipe and recreate volumes for a clean reprovisioning.
- To restore, re-run the bootstrap scripts (`make up`) and re-apply saved
  secrets using Flux or manual `kubectl` commands.

## Extending the Platform

- Add new apps by creating namespaces in `apps/` and referencing them
  inside the main `Makefile` or Flux `kustomizations`.
- Follow the documentation process in [Workflows](workflow.md) to record
  decisions, diagrams, and operational runbooks.
- Use the GitHub Pages deployment to surface the latest diagrams and
  Markdown whenever changes merge into `main`.
