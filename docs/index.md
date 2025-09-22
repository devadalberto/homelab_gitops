# Homelab GitOps — Uranus

Welcome to the documentation portal for the Uranus homelab GitOps stack. The site is generated with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/) and captures the automation, platform layout, and operational practices that keep the environment reproducible.

## Day-1 Quickstart

```bash
git clone https://github.com/devadalberto/homelab_gitops.git
cd homelab_gitops
cp .env.example .env
# Edit pfSense bridges, LAN settings, and point PF_SERIAL_INSTALLER_PATH at the Netgate installer
make up
```

`.env.example` now highlights only the required pfSense settings (VM name, WAN mode, bridges, installer path, and LAN ranges) so you can focus on the zero-touch workflow. Optional variables for ingress hosts, applications, and chart versions can still live in a private `.env`.

The `make up` target walks the staged automation targets in order—`doctor`, `net.ensure`, `pf.preflight`, `pf.config`, `pf.ztp`, `k8s.bootstrap`, and `status`—to validate host dependencies, render pfSense assets, provision the VM, and stand up Kubernetes with a single command.【F:Makefile†L8-L63】

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
