# Homelab Documentation

## Bitwarden Stack

The Bitwarden manifests under `k8s/apps/bitwarden/` deploy the [Vaultwarden](https://github.com/dani-garcia/vaultwarden) container
image behind Traefik with TLS from `cert-manager`. The stack expects a dedicated
namespace, persistent storage, and a PostgreSQL database managed by the existing
`data/pg` release.

### Secrets

Bitwarden loads its sensitive configuration from the SOPS encrypted secret at
`bitwarden/sops-secrets/bitwarden-env.sops.yaml`. Decrypt or edit the secret with
SOPS and populate at least the following keys:

- `ADMIN_TOKEN` – a strong random value enables the Vaultwarden admin interface.
  You can generate one with `openssl rand -hex 32`.
- `DATABASE_URL` – PostgreSQL connection string used by Vaultwarden. The default
  template points at the Bitnami release (`pg-postgresql.data.svc.cluster.local`)
  using a `bitwarden` database and user. Adjust the credentials to match the
  user you create on the cluster database.

Use the repository age recipient (see `.sops/.sops.yaml`) when creating or
updating the secret, e.g.:

```bash
export SOPS_AGE_RECIPIENTS="age17kdhf2edf7xq9r23zmg9v26rp60fer7tu8xy4u3d2djjqtgt3psqteva54"
sops bitwarden/sops-secrets/bitwarden-env.sops.yaml
```

### Storage

The workload mounts the `bitwarden-data` `PersistentVolumeClaim` provisioned with
5 GiB via the `local-path` storage class. Change the `storageClassName` or
`resources.requests.storage` in `k8s/apps/bitwarden/pvc.yaml` to suit your
cluster’s storage backend and capacity planning.

### Ingress and TLS

Traefik terminates HTTPS for `bitwarden.lab-minikube.labz.home.arpa` using the
`bitwarden-tls` secret issued by the `labz-ca-issuer` `ClusterIssuer`. Update the
hostnames in `k8s/apps/bitwarden/ingress.yaml` and
`k8s/apps/bitwarden/certificate.yaml` if you publish Bitwarden under a different
domain.

### Database preparation

Ensure the PostgreSQL instance contains a database and credentials that match
the `DATABASE_URL` secret. For example, after port-forwarding or `kubectl exec`
into the primary pod you can run:

```sql
CREATE DATABASE bitwarden;
CREATE USER bitwarden WITH ENCRYPTED PASSWORD 'super-secret';
GRANT ALL PRIVILEGES ON DATABASE bitwarden TO bitwarden;
```

Replace the password with the value stored in the SOPS secret to keep Vaultwarden
and the database in sync.
