# Automation

## Database and Backup Workflow

Flux now manages the PostgreSQL stack under `k8s/data/postgres/`. The co-located
`HelmRepository` pulls the Bitnami index while the `HelmRelease` pins chart version
`15.5.32`, loads overrides from `data/postgres/pg-values.yaml`, and installs the
workload into the `data` namespace. Backups are also reconciled by the same
Kustomization via the hostPath `PersistentVolume`, `PersistentVolumeClaim`, and
nightly `CronJob` that execute `pg_dump` into the mounted backup share.

- Tune retention or the destination directory by editing
  `data/postgres/backup-cron.yaml` and `data/postgres/backup-pv.yaml` before
  committing changes.

### Secrets

Database superuser credentials live in
`data/postgres/sops-secrets/postgres-superuser.yaml`. Update it with `sops`, commit
the change, and let Flux reconcile so the Helm chart picks up the new secret
version. The HelmRelease consumes the secret through the values file and updates
the StatefulSet on the next reconciliation.
