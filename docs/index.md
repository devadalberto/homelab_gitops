# Homelab GitOps — Uranus

Welcome to the Uranus homelab GitOps stack. The documentation site is
built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/)
and walks new operators through the bootstrap experience while retaining
runbooks for day-two operations.

## Day-1 Quickstart

```bash
git clone https://github.com/devadalberto/homelab_gitops.git
cd homelab_gitops
cp .env.example .env
# Edit passwords, ranges, mount paths, and set PF_INSTALLER_SRC to the downloaded pfSense installer (legacy PF_SERIAL_INSTALLER_PATH/PF_ISO_PATH remain fallbacks)
make up
```

`.env.example` defaults to the serial image workflow. Update
`PF_INSTALLER_SRC` with your local download location so the automation can
stage the media automatically before you run `make up`. Legacy
`PF_SERIAL_INSTALLER_PATH`/`PF_ISO_PATH` variables remain supported for
backwards compatibility (use `PF_ISO_PATH` when opting into the VGA
build).

The `make up` target first runs `scripts/preflight_and_bootstrap.sh` in
preflight mode so host packages, kernel modules, and firewall rules are
ready before Minikube is rebuilt. It then hands control to the combined
bootstrap workflow in `scripts/uranus_homelab.sh` for cluster bring-up and
application deployment.

If you chose `br0`, the host will reboot once, then resume automatically:

- pfSense VM defined with the `pfSense_config` ISO attached so first boot
  auto-imports `/opt/homelab/pfsense/config/config.xml`.
- `make up` orchestrates Minikube, MetalLB, Traefik, cert-manager,
  Postgres, backups, AWX, Observability, Django, and Flux end-to-end.

## Stack Highlights

- **pfSense CE** supplies DHCP, DNS, and outbound NAT for the homelab
  VLAN. Firewall port-forward examples remain disabled by default so
  operators can opt in to each exposure after validating policies.
- **MetalLB** advertises LoadBalancer services within the `10.10.0.0/24`
  range published by pfSense. The values are templated through `.env` so
  addresses stay portable between labs.
- **Traefik** terminates TLS using certificates issued by the internal
  cert-manager hierarchy and provides a default ingress class for
  workloads.
- **Minikube** forms the base Kubernetes control plane. Bootstrap scripts
  configure container runtimes, storage classes, and hostPath directories
  aligned with the repository layout.
- **Flux** reconciles Helm releases and Kubernetes manifests stored in
  this Git repository, ensuring the cluster continuously converges toward
  the desired state.
- **Stateful services** such as PostgreSQL, AWX, Django, and the
  observability stack run with predefined namespaces, secrets, and
  persistent storage definitions so they are ready immediately after
  bootstrap.

## Where to Go Next

- Review the [Workflows](workflow.md) page for GitOps, database backup,
  and documentation automation details.
- Consult the [Operations Reference](reference.md) for architecture
  diagrams, credential management runbooks, pfSense media rotation, and
  service-specific notes.
- Start with [Troubleshooting](troubleshooting.md) when diagnosing
  pfSense provisioning, MetalLB advertisement, or service availability
  issues.
