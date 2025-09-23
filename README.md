# Homelab GitOps

Homelab GitOps bootstraps the Uranus homelab's Minikube-based platform and deploys the core applications managed through Flux so the environment can be rebuilt from a clean Ubuntu host with predictable automation entrypoints.【F:scripts/preflight_and_bootstrap.sh†L400-L520】【F:scripts/uranus_homelab_apps.sh†L511-L569】 pfSense automation is temporarily disabled while the firewall workflow is refactored, so the current focus is on host preflight, Kubernetes bootstrap, and application deployment.

## Quickstart

> pfSense zero-touch provisioning is paused while the firewall automation is reworked. The steps below concentrate on the Minikube-based application stack.

### Prerequisites

* Ubuntu 22.04 LTS (or another apt-based distribution) with `apt-get`/`dpkg` available so the helper scripts can install required packages and Docker components.【F:scripts/host-prep.sh†L368-L416】
* A user with `sudo` privileges; the preflight helpers rely on elevated access for package installation, kernel/network tuning, and service restarts.【F:scripts/preflight_and_bootstrap.sh†L156-L166】【F:scripts/preflight_and_bootstrap.sh†L521-L666】
* Docker Engine with the Compose plugin so the Minikube driver and supporting tooling are available locally.【F:scripts/host-prep.sh†L384-L416】【F:scripts/preflight_and_bootstrap.sh†L625-L631】

### Steps

1. Copy the sample environment file and define the Kubernetes/application values required by the Uranus helpers:

   ```bash
   cp .env.example .env
   ```

   Set `LABZ_TRAEFIK_HOST`, `LABZ_NEXTCLOUD_HOST`, `LABZ_JELLYFIN_HOST`, `LABZ_METALLB_RANGE`, `LABZ_POSTGRES_DB`, `LABZ_POSTGRES_USER`, `LABZ_POSTGRES_PASSWORD`, `LABZ_REDIS_PASSWORD`, `LABZ_PHP_UPLOAD_LIMIT`, `LABZ_MOUNT_BACKUPS`, `LABZ_MOUNT_MEDIA`, `LABZ_MOUNT_NEXTCLOUD`, and `PG_STORAGE_SIZE` so the deployment scripts know where to publish ingress endpoints, how to size persistent storage, and which host paths to prepare.【F:scripts/uranus_homelab_apps.sh†L511-L569】
2. Run the aggregated workflow after the environment file is in place:

   ```bash
   make up ENV_FILE=./.env
   ```

   The helper orchestrates network discovery, MetalLB configuration, Minikube bootstrap, and the Flux-managed application stack in one pass.【F:scripts/preflight_and_bootstrap.sh†L400-L520】【F:scripts/uranus_homelab_one.sh†L320-L364】【F:scripts/uranus_homelab_apps.sh†L511-L569】
3. Inspect the resulting environment and grab the Traefik load-balancer IP/hostnames for reference:

   ```bash
   make status ENV_FILE=./.env
   ```

   The status helper replays the context-preflight summaries so you can confirm the MetalLB pool, Traefik IP, and published service URLs without mutating the cluster.【F:scripts/status.sh†L1-L40】
4. Create a DNS or hosts-file entry that maps `${NEXTCLOUD_HOST}` to the load-balancer address printed by the status summary so browsers resolve the internal certificate correctly.【F:scripts/preflight_and_bootstrap.sh†L404-L447】【F:scripts/uranus_homelab_apps.sh†L565-L569】 pfSense host overrides, Pi-hole, or a local `/etc/hosts` entry all work while the firewall automation remains offline.

## Cluster Status & Next Steps

1. Confirm the `.env` file you copied from `.env.example` is still aligned with your target hostnames, MetalLB range, and storage mounts; the status helper reads the same `ENV_FILE=./.env` values that drove the initial bootstrap so the summary matches your configuration choices.【F:scripts/uranus_homelab_apps.sh†L511-L569】
2. Wait for `make up` to finish its Minikube provisioning and allow Flux to reconcile the manifests for the platform add-ons and applications before pulling a status snapshot. Early checks may show components as pending while Helm releases come online.【F:scripts/preflight_and_bootstrap.sh†L400-L520】【F:scripts/uranus_homelab_one.sh†L320-L364】
3. Re-run the status helper whenever you need to verify cluster health or gather the deployment summary:

   ```bash
   make status ENV_FILE=./.env
   ```

   The output recaps the context-preflight details, including the active Minikube context, Flux reconciliation status, MetalLB pool, and the Traefik load-balancer IP/hostnames that must be published in DNS.【F:scripts/status.sh†L1-L40】
4. Use the printed Traefik address to update DNS, pfSense overrides, or local hosts files so `${LABZ_TRAEFIK_HOST}`, `${LABZ_NEXTCLOUD_HOST}`, and `${LABZ_JELLYFIN_HOST}` resolve to the load balancer while certificates issue and browsers trust the endpoints.【F:scripts/preflight_and_bootstrap.sh†L404-L447】【F:scripts/uranus_homelab_apps.sh†L565-L569】
5. Loop through `make status` until Flux reports healthy reconciliations and the services list shows each application endpoint as ready; repeat the check after changes or reboots to confirm the cluster returned to a healthy baseline before handing it back to users.【F:scripts/status.sh†L1-L40】

## Environment configuration

The helper scripts read a `.env` file to learn where to publish ingress, how to size persistent volumes, and where to mount application data. Adjust the following keys before running the workflow:

* `LABZ_TRAEFIK_HOST`, `LABZ_NEXTCLOUD_HOST`, and `LABZ_JELLYFIN_HOST` – hostnames served by Traefik for the dashboard, Nextcloud, and Jellyfin. They appear in the deployment summary so you can add DNS overrides as needed.【F:scripts/uranus_homelab_apps.sh†L511-L569】
* `LABZ_METALLB_RANGE` – the IP range allocated to MetalLB. The preflight helper confirms or derives this pool and selects a Traefik load-balancer IP from it.【F:scripts/preflight_and_bootstrap.sh†L404-L447】
* `LABZ_POSTGRES_DB`, `LABZ_POSTGRES_USER`, `LABZ_POSTGRES_PASSWORD`, `LABZ_REDIS_PASSWORD`, and `LABZ_PHP_UPLOAD_LIMIT` – credentials and tunables consumed by the packaged charts for PostgreSQL, Redis, and Nextcloud.【F:scripts/uranus_homelab_apps.sh†L511-L563】
* `LABZ_MOUNT_BACKUPS`, `LABZ_MOUNT_MEDIA`, `LABZ_MOUNT_NEXTCLOUD`, and `PG_STORAGE_SIZE` – host paths and capacity used to provision persistent volumes for PostgreSQL backups, Jellyfin media, and Nextcloud data.【F:scripts/uranus_homelab_apps.sh†L511-L569】

The pfSense-oriented variables that still exist in `.env.example` can remain untouched until the firewall automation is re-enabled; they are ignored by the current Quickstart workflow.

## Operational targets

* `make up` – wraps the host preflight, MetalLB alignment, Minikube bootstrap, and Flux application deployment helpers in a single command for day-one provisioning.【F:scripts/preflight_and_bootstrap.sh†L400-L520】【F:scripts/uranus_homelab_one.sh†L320-L364】【F:scripts/uranus_homelab_apps.sh†L511-L569】
* `make status` – replays the context-preflight summaries so you can review the detected MetalLB range, Traefik IP, and published application hostnames without mutating the cluster.【F:scripts/status.sh†L1-L40】
* `make clean` – clears generated artifacts under `/opt/homelab` when you need to retry a run from scratch.【F:scripts/clean.sh†L1-L6】

The individual helper scripts remain available for troubleshooting or iterative work:

* `scripts/preflight_and_bootstrap.sh --context-preflight` – collect network details, confirm the MetalLB pool, and review the stored state without modifying the host.【F:scripts/preflight_and_bootstrap.sh†L404-L447】【F:scripts/preflight_and_bootstrap.sh†L920-L940】
* `scripts/uranus_homelab_one.sh --context-preflight` – validate Helm repository access and confirm the MetalLB/Traefik configuration used by the core add-ons.【F:scripts/uranus_homelab_one.sh†L320-L364】
* `scripts/uranus_homelab_apps.sh --context-preflight` – print the application context summary so you can verify hostnames, storage paths, and credentials before deploying changes.【F:scripts/uranus_homelab_apps.sh†L511-L569】

## Acceptance steps

Use the core targets to validate a fresh environment or confirm a change:

1. `make up` – run the end-to-end workflow to rebuild Minikube, configure MetalLB, and deploy the Flux-managed applications.【F:scripts/preflight_and_bootstrap.sh†L400-L520】【F:scripts/uranus_homelab_apps.sh†L511-L569】
2. `make status` – re-run the context summaries to capture the MetalLB pool, Traefik IP, and published service hostnames.【F:scripts/status.sh†L1-L40】
3. Update DNS or `/etc/hosts` so `${NEXTCLOUD_HOST}` resolves to the Traefik load-balancer IP before handing the environment to end users.【F:scripts/preflight_and_bootstrap.sh†L404-L447】【F:scripts/uranus_homelab_apps.sh†L565-L569】

## Linting

Install [`pre-commit`](https://pre-commit.com/) to mirror the repository linting locally:

```bash
pip install pre-commit
pre-commit install
```

Running `pre-commit run --all-files` executes the default suite:

* [`shellcheck`](https://www.shellcheck.net/) for shell safety checks.
* [`shfmt`](https://github.com/mvdan/sh) to keep shell formatting consistent.
* [`yamllint`](https://yamllint.readthedocs.io/) for YAML manifests.
* [`markdownlint-cli2`](https://github.com/DavidAnson/markdownlint-cli2) for Markdown style across `README.md` and the `docs/` tree.
* `scripts/check-libvirt-no-video.sh` to block `<video>` devices from libvirt domain XML definitions so headless guests stay headless.【F:scripts/check-libvirt-no-video.sh†L1-L38】

Documentation builds still run through `make docs`/`make docs-serve` when you need to regenerate diagrams or preview the site locally.【F:docs/workflow.md†L38-L56】

## Security notes

* Repository secrets are stored as SOPS-encrypted manifests; export `SOPS_AGE_KEY_FILE` with the matching Age private key before editing them with the `sops` CLI and reapply the manifests after changes.【F:docs/index.md†L1-L40】
* Keep the Age private key outside of version control and decrypt secrets only on trusted hosts; the automation expects the key path via `SOPS_AGE_KEY_FILE` when reconciling with Flux.【F:docs/reference.md†L36-L46】
* The preflight and bootstrap helpers invoke privileged operations (APT installs, kernel module loads, `ufw` adjustments, and Docker restarts); review `.env` carefully before running so the host changes are intentional.【F:scripts/preflight_and_bootstrap.sh†L521-L666】
