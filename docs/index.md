# Homelab GitOps — Uranus

Welcome to the documentation portal for the Uranus homelab GitOps stack. The site is generated with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) and captures the automation, platform layout, and operational practices that keep the environment reproducible.

## Day-1 Quickstart

```bash
git clone https://github.com/devadalberto/homelab_gitops.git
cd homelab_gitops
cp .env.example .env
# Edit passwords, ranges, mount paths, and set PF_INSTALLER_SRC to the downloaded pfSense installer
make up
```

`.env.example` defaults to the serial image workflow. Update `PF_INSTALLER_SRC` with your local download location so the automation can stage the media automatically before you run `make up`. Legacy `PF_SERIAL_INSTALLER_PATH`/`PF_ISO_PATH` variables remain supported for backwards compatibility (use `PF_ISO_PATH` when opting into the VGA build).

The `make up` target first runs `scripts/preflight_and_bootstrap.sh` in preflight mode so host packages, kernel modules, and firewall rules are ready before Minikube is rebuilt. It then hands control to the combined bootstrap workflow in `scripts/uranus_homelab.sh` for cluster bring-up and application deployment.

If you chose `br0`, the host will reboot once, then resume automatically:
- pfSense VM defined with the `pfSense_config` ISO attached so first boot auto-imports `/opt/homelab/pfsense/config/config.xml`.
- `make up` orchestrates Minikube, MetalLB, Traefik, cert-manager, Postgres, backups, AWX, Observability, Django, and Flux end-to-end.

A deeper walk-through of every subsystem, bootstrap dependency, and GitOps controller lives in the [Reference](reference.md) guide. That page also includes Mermaid sequence/state diagrams that are rendered as part of the documentation build.

## Platform Highlights

![Homelab component overview](diagrams/homelab-overview.svg)

- **Network & Edge** — pfSense CE provides DHCP/DNS/NAT for the homelab VLAN, MetalLB advertises the `10.10.0.0/24` LoadBalancer range, and Traefik terminates TLS with certificates issued by cert-manager.
- **Cluster Runtime** — Minikube forms the Kubernetes control plane while Flux continuously reconciles manifests and Helm releases stored in this repository.
- **Stateful Services** — Bitnami PostgreSQL runs in the `data` namespace with nightly WAL backups pushed to the hostPath defined in `.env`.
- **User-Facing Applications** — AWX, the Django multiproject demo, and the kube-prometheus-stack observability suite are delivered through the same GitOps pipeline.

## Where to Go Next

- Follow the [Workflow](workflow.md) guide for GitOps reconciliation details, automation entry points, and documentation tooling expectations.
- Consult the [Troubleshooting](troubleshooting.md) runbooks when bootstrap or day-2 operations need deeper investigation.
- Use the [Reference](reference.md) for credentials management, pfSense refresh procedures, backup policies, and the project changelog.
