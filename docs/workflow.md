# Workflows

The Uranus homelab leans on repeatable workflows so bootstrap,
documentation, and day-two automation stay predictable. This page
summarizes the core loops contributors interact with most often.

## Documentation Workflow

The documentation site is generated with MkDocs and the Material theme.
This toolchain converts Markdown content and Mermaid diagrams into a
browsable site.

### Dependencies

| Tool          | Purpose                  | Installation Notes                      |
|---------------|--------------------------|-----------------------------------------|
| Python ≥ 3.9  | MkDocs + plugins         | `pip install -r docs/requirements.txt`  |
| Node.js ≥ 18  | Mermaid CLI              | `npm install -g @mermaid-js/mermaid-cli` *(or invoke via `npx`)* |
| Make          | Automation entry point   | Included on most Linux distros and macOS |

Install the Python dependencies inside a virtual environment to keep the
host interpreter clean.

### Local Authoring

- Edit Markdown under the `docs/` directory. The navigation menu lives in
  `mkdocs.yml`.
- Place Mermaid sources next to the page they support (for example,
  `docs/diagrams/*.mmd`).
- Run `make docs-serve` while iterating. The helper regenerates diagrams
  before launching `mkdocs serve` on `0.0.0.0:8000`, making remote previews
  straightforward.

### Diagram Conventions

- Diagram output defaults to SVG so content stays crisp inside the
  Material theme.
- Keep diagrams focused and reference them from the relevant pages using
  standard Markdown image syntax.
- When diagrams reference Kubernetes objects, use namespace/name notation
  (for example, `awx/awx-operator`).

### Continuous Integration

Every push to `main` runs the same documentation pipeline used locally:

1. Install MkDocs Material, the Mermaid plugin, and Mermaid CLI.
2. Run `make docs` to regenerate diagrams and execute a strict MkDocs
   build.
3. Publish the rendered site to the `gh-pages` branch via `mkdocs gh-deploy`.

Pull requests execute steps 1–2 to validate documentation without
publishing.

### Pre-commit Hook

A [`pre-commit`](https://pre-commit.com/) hook ships with the repository
so contributors can catch stale diagrams before pushing. Install the
framework (`pip install pre-commit`) and enable it:

```bash
pre-commit install
```

On each commit the hook triggers `make docs`. Regenerated SVGs appear as
staged changes when diagrams or Markdown are modified.

## GitOps Reconciliation Flow

Flux controllers watch this repository for new commits and reconcile them
against the cluster. The sequence diagram below summarizes the control
loop that runs whenever manifests or Helm values change.

![GitOps reconciliation sequence](diagrams/gitops-flow.svg)

1. Contributors edit Kubernetes manifests or Helm values and push to the
   `main` branch.
2. Flux's **source-controller** pulls the repository, verifying commit
   signatures if configured.
3. The **kustomize-controller** and **helm-controller** render templates
   and compare them against live cluster state.
4. Drift is corrected by applying the resulting manifests through the
   Kubernetes API server.
5. Events and reconciliation status surface through Prometheus and appear
   inside Grafana dashboards.

## Database and Backup Workflow

Flux manages the PostgreSQL stack under `k8s/data/postgres/`. The
co-located `HelmRepository` pulls the Bitnami index while the
`HelmRelease` pins chart version `16.2.6`, loads overrides from
`data/postgres/pg-values.yaml`, and installs the workload into the `data`
namespace. Backups are reconciled by the same Kustomization via the
hostPath `PersistentVolume`, `PersistentVolumeClaim`, and nightly
`CronJob` that writes `pg_dump` output into the mounted backup share.

- Tune retention or the destination directory by editing
  `data/postgres/backup-cron.yaml` and `data/postgres/backup-pv.yaml`
  before committing changes.
- Database superuser credentials live in
  `data/postgres/sops-secrets/postgres-superuser.yaml`. Update it with
  `sops`, commit the change, and let Flux reconcile so the Helm chart
  picks up the new secret version. The `HelmRelease` consumes the secret
  through the values file and updates the StatefulSet on the next
  reconciliation.
