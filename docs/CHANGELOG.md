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
