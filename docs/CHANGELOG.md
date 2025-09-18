## 2025-09-19T00:00:00.000000Z
- Split GitHub Actions into a dedicated static analysis job that runs ShellCheck, yamllint, and kubeconform with cached tool downloads for faster feedback.
- Added `scripts/run-lint-suite.sh` plus a `make lint` target so contributors can reproduce the CI linting locally.
- Documented the lint workflow and prerequisites in the README to keep manifest and script validation consistent across environments.

## 2025-09-18T00:00:00.000000Z
- Recorded current release cadence and pinned the GitOps stack to the n-1 builds exercised in testing: Kubernetes v1.31.3, MetalLB 0.14.7, Traefik 27.0.2, cert-manager 1.16.3, Bitnami PostgreSQL 16.2.6, kube-prometheus-stack 65.5.0, and AWX operator 2.20.0.
- Updated the Flux CLI bootstrap helper to install v2.3.0 so local environments reconcile with the same binary verified in automation.
- Refreshed documentation to note the latest upstream versions alongside the pinned releases for easier future upgrades.

## 2025-09-17T08:00:00.000000Z
- Pin Flux-managed chart versions to the builds exercised in automation: MetalLB 0.14.5, cert-manager 1.15.3, and Traefik 26.0.0.
- Document the Helm chart upgrade workflow (bump `k8s/addons/*/release.yaml`, stage with `make up`/`scripts/uranus_homelab_one.sh`, then update docs) to keep production in lockstep with staging.
- Wire Flux `dependsOn` for Traefik so upgrades wait on MetalLB and cert-manager health, surfacing dependency issues earlier.

## 2025-09-10T04:47:38.065634Z
- Restructured repo to modular stages (Makefile).
- Added bootstrap.sh with br0 default + safe reboot/resume.
- pfSense CE 2.8.0 ISO URL; config.xml generator with labz domain + NAT examples (disabled).
- Minikube + MetalLB + Traefik + cert-manager internal CA.
- Postgres with 7-day nightly backups to hostPath.
- AWX (small), kube-prometheus-stack, Django multiproject app.
- Flux controllers installed (no remote Git).
