#!/usr/bin/env bash
set -euo pipefail
kubectl apply -n awx -f https://raw.githubusercontent.com/ansible/awx-operator/2.19.1/deploy/awx-operator.yaml
kubectl rollout status deployment/awx-operator-controller-manager -n awx --timeout=180s || true
