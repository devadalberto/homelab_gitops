# Architecture

The Uranus homelab stitches together on-premises virtualization, Kubernetes tooling, and GitOps pipelines so that every environment can be reproduced deterministically. The following overview diagram highlights the primary subsystems and the traffic flow between them.

![Homelab component overview](diagrams/homelab-overview.svg)

## Platform Layers

### Network & Edge

- **pfSense CE** supplies DHCP, DNS, and outbound NAT for the homelab VLAN. Firewall port-forward examples remain disabled by default so operators can opt in to each exposure after validating policies.
- **MetalLB** advertises LoadBalancer services within the `10.10.0.0/24` range published by pfSense. The values are templated via environment variables inside `.env` to keep addresses portable between labs.
- **Traefik** terminates TLS using certificates issued by the internal cert-manager hierarchy and provides a default ingress class for workloads.

### Cluster Runtime

- **Minikube** forms the base Kubernetes control plane. Bootstrap scripts configure container runtimes, storage classes, and hostPath directories aligned with the repository layout.
- **Flux** reconciles Helm releases and Kubernetes manifests stored in this Git repository, ensuring the cluster continuously converges towards the desired state.
- **Cert-Manager** provisions a root Certificate Authority and application leaf certs. The root CA can be exported through the command in the [Quickstart](index.md#internal-ca).

### Stateful Services

- **PostgreSQL (Bitnami chart)** runs in the `data` namespace. A nightly CronJob pushes WAL backups to the hostPath defined by `LABZ_MOUNT_BACKUPS`.
- **Persistent hostPath volumes** for application storage are parameterized through `.env` to align with local disk layout.

### User-Facing Applications

- **AWX** provides Ansible automation inside the `awx` namespace with persistent volumes and TLS termination handled by Traefik.
- **Django Multiproject Demo** showcases the platform deployment pipeline, including container image preloading via `apps/django-multiproject/load-image.sh`.
- **Observability stack** is powered by `kube-prometheus-stack`, exposing Grafana, Prometheus, and Alertmanager through Traefik-managed Ingresses.

## GitOps Flow

Flux controllers watch the repository for new commits and reconcile them against the cluster. The sequence diagram below summarizes the control loop when an operator changes a manifest or Helm values file.

![GitOps reconciliation sequence](diagrams/gitops-flow.svg)

1. Developers edit Kubernetes manifests/Helm values and push to the `main` branch.
2. Flux's **source-controller** pulls the repository, verifying commit signatures if configured.
3. The **kustomize-controller** and **helm-controller** render templates and compare them against the live cluster state.
4. Drift is corrected by applying the resulting manifests through the Kubernetes API server.
5. Events and reconciliation status are exported via Prometheus and surfaced inside Grafana dashboards.

## Secrets & Certificates

- SOPS/AGE secret placeholders live in the repo (`.sops/`). Actual encrypted files should be stored separately and decrypted only on trusted hosts.
- Export `SOPS_AGE_KEY_FILE` (for example, `export SOPS_AGE_KEY_FILE="$PWD/.sops/age.key"`) before invoking `sops` locally or running Flux bootstrap scripts so the controllers mount the same private key during reconciliation.
- Cert-manager manages a two-tier CA (root + intermediate). Root certificates are available as Kubernetes secrets and can be exported for browser/device trust.
- Traefik ingress routes always reference TLS secrets; the repo defaults to the internal CA but can be swapped for ACME with external DNS integration.

## Backup & Disaster Recovery

- PostgreSQL backups are scheduled by the CronJob in `data/postgres/backup-cron.yaml`.
- HostPath directories are prepared by `scripts/uranus_homelab.sh`, which can optionally wipe and recreate volumes for a clean re-provisioning.
- To restore, re-run the bootstrap scripts (`make up`) and re-apply the saved secrets using Flux or manual `kubectl` commands.

## Extending the Platform

- Add new apps by creating namespaces in `apps/` and referencing them inside the main `Makefile` or Flux `kustomizations`.
- Leverage the documentation pipeline described in [Documentation Workflow](docs-workflow.md) to record decisions, diagrams, and operational runbooks.
- Use the GitHub Pages deployment to surface the latest diagrams and Markdown whenever changes merge into `main`.
