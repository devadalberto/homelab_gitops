# Flux Bootstrap Notes

1. Ensure kubectl context points to minikube:
   kubectl config use-context minikube

2. Verify cluster:
   kubectl get nodes -o wide

3. Flux install (installs the CLI and the controllers in the cluster):
   * Option A - manual, pinned, and checksum verified:

     ```sh
     FLUX_VERSION=2.3.0
     FLUX_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
     FLUX_ARCH=amd64 # use arm64 for Apple Silicon, etc.
     curl -fsSLO "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_${FLUX_OS}_${FLUX_ARCH}.tar.gz"
     curl -fsSLO "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_checksums.txt"
     awk -v file="flux_${FLUX_VERSION}_${FLUX_OS}_${FLUX_ARCH}.tar.gz" '$2 == file {print; found=1} END {if (!found) exit 1}' \
       "flux_${FLUX_VERSION}_checksums.txt" > "flux_${FLUX_VERSION}_${FLUX_OS}_${FLUX_ARCH}.tar.gz.sha256"
     sha256sum --check "flux_${FLUX_VERSION}_${FLUX_OS}_${FLUX_ARCH}.tar.gz.sha256" # use `shasum -a 256 -c` on macOS
     tar -xzf "flux_${FLUX_VERSION}_${FLUX_OS}_${FLUX_ARCH}.tar.gz"
     sudo install -m 0755 flux /usr/local/bin/flux
     ```

     Verify with `flux version --client --short` and then run `flux check --pre`.

   * Option B - automated script (performs the same verified install and ensures the target cluster path exists; override with `CLUSTER_PATH=...` if needed):

     ```sh
     ./flux/install.sh
     ```

4. Configure Flux to sync this repository path:
   * Update `clusters/minikube/flux-system/gotk-sync.yaml` with your repository URL (adjust the sync path and/or the `CLUSTER_PATH` variable if you store manifests elsewhere).
   * Apply the bootstrap manifests:

     ```sh
     kubectl apply -k clusters/minikube/flux-system
     ```

   * Confirm the sync objects once they are ready:

     ```sh
     flux get kustomizations
     ```

5. Commit and push Kubernetes manifests as you go; Flux will reconcile `clusters/minikube` automatically.
