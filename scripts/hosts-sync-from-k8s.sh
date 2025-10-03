#!/usr/bin/env bash
set -euo pipefail
TRA=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
MC=$(kubectl -n minecraft get svc mc -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
sudo sed -i -E '/\btraefik\.home\.arpa\b/d;/\bdjango\.home\.arpa\b/d;/\bnextcloud\.home\.arpa\b/d;/\bminecraft\.home\.arpa\b/d' /etc/hosts
echo "$TRA traefik.home.arpa django.home.arpa nextcloud.home.arpa" | sudo tee -a /etc/hosts >/dev/null
if [ -n "${MC:-}" ]; then echo "$MC minecraft.home.arpa" | sudo tee -a /etc/hosts >/dev/null; fi
