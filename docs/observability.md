# Observability Operations

## Grafana admin credential management

Grafana is deployed through the `kube-prometheus-stack` chart. The admin
credentials are no longer embedded in the values file; instead they live in the
SOPS-encrypted Secret manifest at
`observability/sops-secrets/grafana-admin.yaml`.

### Prerequisites

1. Install [SOPS](https://github.com/getsops/sops) on your workstation.
2. Import the **Homelab SOPS** GPG key (`06D8D7726588CB103AE9717413BF4A9EA7B7C3F8`)
   from the team credential vault into your local keyring. This key is **not**
   stored in the repository; request access through the normal secure channel if
   it is not already present.

### Retrieve the password

```bash
# Decrypt the manifest and print the admin credentials
sops -d observability/sops-secrets/grafana-admin.yaml \
  | yq '.stringData["admin-user"] + ":" + .stringData["admin-password"]' -r
```

### Rotate the password

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
3. Save and exit; `sops` will re-encrypt the document automatically.
4. Commit the updated secret and let Flux reconcile, or apply it manually if you
   need the change immediately:
   ```bash
   kubectl apply -f observability/sops-secrets/grafana-admin.yaml
   ```

### Why this matters

The chart values file (`observability/kps-values.yaml`) now points Grafana at the
`grafana-admin` Secret via `grafana.admin.existingSecret`. This keeps credentials
out of Git history while still allowing GitOps workflows to manage the rendered
Secret manifest.
