# Flux Bootstrap Notes

1. Ensure kubectl context points to minikube:
   kubectl config use-context minikube

2. Verify cluster:
   kubectl get nodes -o wide

3. Flux install (option A - manual):
   curl -s https://fluxcd.io/install.sh | sudo bash
   flux check --pre

4. Flux bootstrap (example with GitHub):
   flux bootstrap github \
     --owner YOUR_GH_USER \
     --repository homelab_gitops \
     --branch main \
     --path clusters/minikube

5. Commit and push k8s manifests as you go; Flux will reconcile.
