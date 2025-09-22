# Homelab GitOps

Homelab GitOps provisions a pfSense-backed virtualization stack, renders the pfSense configuration bundle, and bootstraps a Kubernetes control plane with supporting services so the lab can be rebuilt from a clean host with a consistent set of make targets.【F:scripts/pf-ztp.sh†L1-L120】【F:scripts/k8s-up.sh†L21-L33】【F:pfsense/pf-config-gen.sh†L1-L120】 The automation is organized as discrete stages to make validation, recovery, and iterative development easier.

## Bootstrap workflow

Run the aggregated workflow once `.env` has been populated with your site-specific values:

```bash
make up ENV_FILE=./.env
```

`make up` walks through host diagnostics, network validation, pfSense configuration regeneration, zero-touch provisioning, cluster bootstrap, and a status summary so the lab moves from bare-metal to ready-for-use in one command.【F:Makefile†L8-L63】 Each stage is still available as an individual target for troubleshooting or day-two maintenance.

## Environment configuration

1. Copy the example environment and edit it for your installation:

   ```bash
   cp .env.example .env
   ```

2. Populate the required keys in `.env`:
   * `PF_VM_NAME` – libvirt domain name of the pfSense VM to validate and manage.【F:.env.example†L1-L9】【F:scripts/pf-preflight.sh†L126-L200】
   * `WAN_MODE` – `br0` manages a Linux bridge for the WAN uplink, while other values (for example `macvtap`) skip bridge creation.【F:.env.example†L4-L6】【F:scripts/net-ensure.sh†L62-L115】
   * `PF_WAN_BRIDGE` and `PF_LAN_BRIDGE` – bridge devices that back the pfSense WAN/LAN interfaces.【F:.env.example†L4-L9】【F:scripts/net-ensure.sh†L99-L150】
   * `PF_SERIAL_INSTALLER_PATH` – absolute path to the downloaded Netgate serial installer image used during provisioning.【F:.env.example†L11-L12】【F:scripts/pf-preflight.sh†L126-L183】
   * `LAN_CIDR`, `LAN_GW_IP`, `LAN_DHCP_FROM`, and `LAN_DHCP_TO` – LAN subnet and DHCP scope enforced during preflight validation.【F:.env.example†L14-L18】【F:scripts/pf-preflight.sh†L161-L184】

These variables give the automation everything it needs to lay down bridges, verify addressing, and attach the pfSense media. Optional knobs (application hosts, chart versions, and storage paths) can still be provided via a private `.env` but are intentionally omitted from the public example.

## Make targets

* `make doctor` – inventories required tooling (bash, curl, git, libvirt, Kubernetes CLIs, and more) so host gaps are obvious before provisioning.【F:Makefile†L17-L33】【F:scripts/doctor.sh†L25-L124】
* `make net.ensure` – confirms the WAN and LAN bridges exist (creating them when `NET_CREATE=1`) ahead of pfSense bring-up.【F:Makefile†L17-L42】【F:scripts/net-ensure.sh†L1-L166】
* `make pf.preflight` – validates pfSense prerequisites, LAN addressing, and optional MetalLB ranges using the staged environment file.【F:Makefile†L38-L44】【F:scripts/pf-preflight.sh†L1-L248】
* `make pf.config` – rebuilds the pfSense `config.xml` and ISO artifacts under sudo so zero-touch provisioning pulls in the latest values.【F:Makefile†L46-L48】【F:pfsense/pf-config-gen.sh†L1-L120】
* `make pf.ztp` – applies the regenerated assets, ensures the qcow2 disk exists, and wires the VM peripherals for unattended provisioning.【F:Makefile†L50-L53】【F:scripts/pf-ztp.sh†L101-L200】
* `make k8s.bootstrap` – seeds Kubernetes, installs platform add-ons, and reconciles the GitOps controllers that manage the workloads.【F:Makefile†L55-L58】【F:scripts/k8s-up.sh†L21-L120】
* `make status` – prints the effective environment, libvirt domain state, and Kubernetes readiness checks for quick health summaries.【F:Makefile†L60-L61】【F:scripts/status.sh†L1-L132】
* `make clean` – removes cached artifacts, generated pfSense assets, and other build products to reclaim disk or reset the lab state.【F:Makefile†L63-L64】【F:scripts/clean.sh†L1-L120】

## Acceptance steps

Use the staged targets individually when validating a fresh environment or confirming a change:

1. `make doctor` – capture dependency issues on the host before attempting virtualization or Kubernetes work.【F:scripts/doctor.sh†L25-L124】
2. `NET_CREATE=1 make net.ensure` – create or repair the WAN/LAN bridges so pfSense attaches to the expected interfaces.【F:scripts/net-ensure.sh†L62-L166】
3. `make pf.preflight` – verify LAN addressing, DHCP scope, pfSense domain availability, and installer media before mutating state.【F:scripts/pf-preflight.sh†L103-L211】
4. `sudo make pf.config` – render `config.xml` and the `pfSense_config` ISO with the latest `.env` values.【F:pfsense/pf-config-gen.sh†L1-L120】
5. `sudo make pf.ztp` – run the zero-touch provisioning helper to align the pfSense VM definition with the regenerated assets.【F:scripts/pf-ztp.sh†L101-L330】
6. `make k8s.bootstrap` – provision Minikube, MetalLB, Traefik, cert-manager, and the GitOps controllers that reconcile the app stack.【F:scripts/k8s-up.sh†L21-L200】
7. `make status` – confirm virsh, kubectl, and ingress summaries look healthy before handing the environment over to users.【F:scripts/status.sh†L1-L132】
8. `make clean` – optional teardown step that removes generated assets when acceptance is complete or you need to rerun the workflow from scratch.【F:scripts/clean.sh†L1-L120】

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
* The zero-touch provisioning helper invokes pfSense virtualization operations with `sudo`; review `.env` carefully before running so the libvirt changes and bridge rewrites are intentional.【F:scripts/pf-ztp.sh†L1-L84】
