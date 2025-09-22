# Workflow

This guide explains how changes move from a developer workstation into the Uranus homelab along with the tooling that keeps documentation and automation reproducible.

## GitOps Control Loop

Flux controllers continuously reconcile the repository against the running cluster. The sequence diagram below summarizes the control flow whenever a manifest or Helm values file changes.

![GitOps reconciliation sequence](diagrams/gitops-flow.svg)

1. Developers edit Kubernetes manifests or Helm values and push to `main`.
2. Flux's **source-controller** pulls the repository, verifying commit signatures if configured.
3. The **kustomize-controller** and **helm-controller** render templates and compare them against the live cluster state.
4. Drift is corrected by applying the resulting manifests through the Kubernetes API server.
5. Events and reconciliation status are exported via Prometheus and surfaced inside Grafana dashboards.

## Application Automation

Flux manages the PostgreSQL stack under `k8s/data/postgres/`. The co-located `HelmRepository` pulls the Bitnami index while the `HelmRelease` pins chart version `16.2.6`, loads overrides from `data/postgres/pg-values.yaml`, and installs the workload into the `data` namespace. Backups are reconciled by the same Kustomization via the hostPath `PersistentVolume`, `PersistentVolumeClaim`, and nightly `CronJob` that execute `pg_dump` into the mounted backup share.

- Tune retention or the destination directory by editing `data/postgres/backup-cron.yaml` and `data/postgres/backup-pv.yaml` before committing changes.
- Database superuser credentials live in `data/postgres/sops-secrets/postgres-superuser.yaml`. Update the manifest with `sops`, commit the change, and let Flux reconcile so the Helm chart picks up the new secret version.

## Documentation Workflow

The repository uses MkDocs with the Material theme to convert Markdown content and Mermaid diagrams into a browsable site. Contributors should mirror the tooling described below when authoring updates.

### Dependencies

| Tool | Purpose | Installation Notes |
|------|---------|--------------------|
| Python ≥ 3.9 | MkDocs + plugins | `pip install -r docs/requirements.txt` |
| Node.js ≥ 18 | Mermaid CLI | `npm install -g @mermaid-js/mermaid-cli` *(optional when using `npx`)* |
| Make | Automation entry point | Included on most Linux distros and macOS |

Install the Python packages inside a virtual environment to avoid polluting system interpreters.

### Local Authoring

- Edit Markdown under the `docs/` directory. The navigation menu is defined in `mkdocs.yml`.
- Place Mermaid sources next to the page they support (for example, `docs/diagrams/*.mmd`).
- Run `make docs-serve` while iterating. This regenerates all diagrams, starts `mkdocs serve`, and binds to `0.0.0.0:8000` for remote previews.

#### Diagram Conventions

- Output format defaults to SVG so diagrams remain crisp when zoomed inside the Material theme.
- Keep diagrams focused and reference them from the relevant pages using standard Markdown image syntax.
- When diagrams reference Kubernetes objects, stick to namespace/name notation (e.g., `awx/awx-operator`).

### Continuous Integration

GitHub Actions execute the following steps on every push to `main`:

1. Install MkDocs Material, the Mermaid plugin, and Mermaid CLI dependencies.
2. Run `make docs` to regenerate all diagrams and ensure the MkDocs build succeeds with `--strict` mode.
3. Deploy the rendered site to the `gh-pages` branch via `mkdocs gh-deploy`.

Pull requests run through steps 1-2 to validate documentation without publishing.

### Pre-commit Hook

Install [`pre-commit`](https://pre-commit.com/) to mirror the repository linting locally:

```bash
pip install pre-commit
pre-commit install
```

Running `pre-commit run --all-files` executes shellcheck, shfmt, yamllint, markdownlint, and a guard that rejects libvirt domain XMLs containing `<video>` devices so headless guests are preserved.【F:.pre-commit-config.yaml†L2-L24】【F:scripts/check-libvirt-no-video.sh†L1-L38】 Re-run `make docs` or `make docs-serve` whenever content or diagrams change; those targets remain the supported path to regenerate the site during reviews.【F:Makefile†L77-L96】
