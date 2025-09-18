# Flux Bootstrap Notes

1. Ensure kubectl context points to minikube:
   kubectl config use-context minikube

2. Verify cluster:
   kubectl get nodes -o wide

3. Flux install:
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

   * Option B - automated script (performs the same verified install):

     ```sh
     ./flux/install.sh
     ```

4. Flux bootstrap (example with GitHub):
   flux bootstrap github \
     --owner YOUR_GH_USER \
     --repository homelab_gitops \
     --branch main \
     --path clusters/minikube

5. Commit and push k8s manifests as you go; Flux will reconcile.
