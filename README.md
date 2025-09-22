# Homelab GitOps

[![GitOps CI](https://github.com/devadalberto/homelab_gitops/actions/workflows/gitops-ci.yml/badge.svg)](https://github.com/devadalberto/homelab_gitops/actions/workflows/gitops-ci.yml)
[![Documentation](https://github.com/devadalberto/homelab_gitops/actions/workflows/docs.yml/badge.svg)](https://github.com/devadalberto/homelab_gitops/actions/workflows/docs.yml)

Homelab GitOps automates a pfSense-backed Minikube environment by chaining host preflight checks, pfSense zero-touch provisioning, and Kubernetes bootstrap before layering networking add-ons such as MetalLB, cert-manager, and Traefik alongside application stacks including PostgreSQL, Redis, Nextcloud, and Jellyfin through composable scripts.【F:scripts/uranus_homelab.sh†L204-L272】【F:scripts/uranus_homelab_one.sh†L214-L273】【F:scripts/uranus_homelab_apps.sh†L265-L356】

## Quickstart

1. Copy the sample environment file and edit it with your site-specific values:

   ```bash
   cp .env.example .env
   ```

2. Prepare the host tooling and networking prerequisites:

   ```bash
   ./scripts/host-prep.sh --env-file ./.env
   ```

   The host preparation routine installs virtualization dependencies, configures libvirt bridges, and validates Docker, Kubernetes CLIs, Helm, Minikube, and SOPS before handing off to the pfSense workflow.【F:scripts/host-prep.sh†L36-L599】

3. Download the pfSense CE **serial** installer and point `PF_INSTALLER_SRC` at the archive so validation succeeds; the automation expects the serial build so the pfSense VM can boot headlessly via its console.【F:.env.example†L53-L68】【F:scripts/host-prep.sh†L268-L316】【F:scripts/pf-vm-install.sh†L165-L196】【F:scripts/pf-vm-install.sh†L265-L295】

4. Launch the consolidated pipeline:

   ```bash
   ./scripts/uranus_homelab.sh --env-file ./.env --assume-yes
   ```

   The wrapper first runs the preflight and installer alignment (`scripts/preflight_and_bootstrap.sh`), then executes pfSense zero-touch provisioning, the Minikube bootstrap, networking add-ons, and application deployment sequentially. By default the pfSense helper reuses the `br0` bridge for both WAN and LAN unless you override `PF_LAN_BRIDGE`; if you pick a different LAN bridge, the automation raises it automatically so the VM cabling stays consistent.【F:scripts/uranus_homelab.sh†L204-L272】【F:scripts/pf-vm-install.sh†L101-L145】

## Prerequisites

* Prepare an Ubuntu host (or derivative) with virtualization, libvirt, Docker, Kubernetes CLIs, and other tooling by running `./scripts/host-prep.sh --env-file ./.env`. The script installs the required APT packages, ensures Docker, kubectl, Helm, Minikube, and SOPS are available, wires up libvirt, and can create the pfSense LAN bridge if it is missing.【F:scripts/host-prep.sh†L36-L599】
* Download the pfSense CE **serial** installer in advance and point `PF_INSTALLER_SRC` at the archive so validation passes during preflight; the helper flags non-serial images so the headless workflow stays aligned with the VM's serial console.【F:.env.example†L53-L68】【F:scripts/host-prep.sh†L268-L316】【F:scripts/pf-vm-install.sh†L265-L295】
* Keep the pfSense LAN bridge settings (`PF_LAN_BRIDGE`/`PF_LAN_LINK`) aligned with the actual host interface names; the host-prep routine checks the values and can create the bridge automatically when it is absent.【F:scripts/host-prep.sh†L207-L264】【F:scripts/host-prep.sh†L576-L599】

## Configuration

1. Copy the sample environment file and edit it with your site-specific values:
   
   ```bash
   cp .env.example .env
   ```

2. Update the following sections in `.env`:
   * **Domain and ingress hosts** (`LABZ_DOMAIN`, `LABZ_TRAEFIK_HOST`, `LABZ_NEXTCLOUD_HOST`, `LABZ_JELLYFIN_HOST`).【F:.env.example†L1-L4】
   * **HostPath mounts and working directories** (`LABZ_MOUNT_BACKUPS`, `LABZ_MOUNT_MEDIA`, `LABZ_MOUNT_NEXTCLOUD`, `WORK_ROOT`, `PG_BACKUP_HOSTPATH`).【F:.env.example†L6-L8】【F:.env.example†L55-L59】
   * **Minikube profile sizing and Kubernetes version** (`LABZ_MINIKUBE_PROFILE`, CPU, memory, disk, driver, and version pins).【F:.env.example†L10-L22】
   * **LAN addressing and MetalLB pool** (`LAN_CIDR`, gateway, DHCP scope, `LABZ_METALLB_RANGE`, and `METALLB_POOL_START/END`). After edits, regenerate the Flux manifest so GitOps and bootstrap flows share the same VIP range:
     
     ```bash
     ./scripts/render_metallb_pool_manifest.sh --env-file ./.env
     ```
     【F:.env.example†L24-L33】【F:scripts/render_metallb_pool_manifest.sh†L1-L70】
   * **Application credentials and limits** (`LABZ_POSTGRES_DB`, `LABZ_POSTGRES_USER`, `LABZ_POSTGRES_PASSWORD`, `LABZ_REDIS_PASSWORD`, `LABZ_PHP_UPLOAD_LIMIT`).【F:.env.example†L35-L40】
   * **pfSense and infrastructure parameters** (WAN NIC/mode, VM name, bridge hints, QCOW2 size, installer paths, cluster subdomain, Traefik VIP, and flags such as `PF_HEADLESS`).【F:.env.example†L42-L68】

## Useful targets

* `make up` – runs the pfSense preflight, regenerates the config ISO, ensures the VM exists, and invokes the pfSense bootstrap helper in sequence.【F:Makefile†L8-L55】
* `make preflight` – executes the pfSense preflight script against the selected environment file.【F:Makefile†L24-L28】
* `make pf.config` – rebuilds `config.xml` and the `pfSense_config` ISO under `sudo` based on `.env` values.【F:Makefile†L30-L33】
* `make pf.install` – creates or updates the libvirt VM definition using `scripts/pf-vm-install.sh`.【F:Makefile†L35-L39】
* `make pf.ztp` – runs the pfSense bootstrap script in headless mode.【F:Makefile†L41-L46】
* `make smoketest` – launches the pfSense smoketest routine to validate DHCP, NAT, and reachability checks.【F:Makefile†L48-L51】【F:scripts/pf-smoketest.sh†L49-L63】
* `make check.env` – prints the active environment file and key variables for a quick sanity check.【F:Makefile†L19-L22】

## Quick checks

* `./scripts/preflight_and_bootstrap.sh --env-file ./.env --context-preflight` captures a non-mutating view of detected networking, packages, and installer state before any changes are applied.【F:scripts/preflight_and_bootstrap.sh†L51-L75】【F:scripts/host-prep.sh†L320-L403】
* `./scripts/preflight_and_bootstrap.sh --env-file ./.env --preflight-only` runs the full host remediation sequence (sysctls, iptables mode, optional Minikube restart) without launching the cluster bootstrap.【F:scripts/preflight_and_bootstrap.sh†L51-L76】【F:scripts/preflight_and_bootstrap.sh†L800-L887】
* `make check.env` confirms the expected LAN, MetalLB, and installer values are present in the environment file.【F:Makefile†L19-L22】
* `make smoketest` (or `./scripts/pf-smoketest.sh --env-file ./.env`) validates the pfSense domain, LAN bridge, DHCP, and WAN reachability probes.【F:Makefile†L48-L51】【F:scripts/pf-smoketest.sh†L49-L117】
* `./scripts/k8s-smoketest.sh --env-file ./.env` switches kubectl to the Minikube context and ensures node readiness once the cluster is online.【F:scripts/k8s-smoketest.sh†L35-L199】

## Security notes

* Repository secrets are stored as SOPS-encrypted manifests; export `SOPS_AGE_KEY_FILE` with the matching Age private key before editing them with the `sops` CLI and reapply the manifests after changes.【F:docs/index.md†L26-L40】
* Keep the Age private key outside of version control and decrypt secrets only on trusted hosts; the automation expects the key path via `SOPS_AGE_KEY_FILE` when reconciling with Flux.【F:docs/architecture.md†L46-L47】
* The orchestration wrapper invokes the pfSense zero-touch provisioning script with `sudo`; review `.env` carefully before running so the virtualization changes and network rewrites are intentional.【F:scripts/uranus_homelab.sh†L220-L259】
