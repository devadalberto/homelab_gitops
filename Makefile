# IMPORTANT: This file uses TAB characters for all recipe lines.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env

.PHONY: help up down status preflight k8s.bootstrap k8s.clean dns.ensure route.ensure pv.mount apps.nextcloud apps.nextcloud.reinstall apps.jellyfin labz.dns

help:
	@printf '%s\n' 'Targets:'
	@printf '  %-28s%s\n' 'up' 'Run preflight, bootstrap Kubernetes, and execute network/app automation.'
	@printf '  %-28s%s\n' 'down' 'Tear down Kubernetes resources.'
	@printf '  %-28s%s\n' 'status' 'Summarize the environment state.'
	@printf '  %-28s%s\n' 'preflight' 'Run host and configuration validation.'
	@printf '  %-28s%s\n' 'k8s.bootstrap' 'Bootstrap the Kubernetes cluster.'
	@printf '  %-28s%s\n' 'k8s.clean' 'Remove the Kubernetes cluster profile.'
	@printf '  %-28s%s\n' 'dns.ensure' 'Configure pfSense DNS overrides for LABZ hosts.'
	@printf '  %-28s%s\n' 'route.ensure' 'Verify pfSense bridge prerequisites on the host.'
	@printf '  %-28s%s\n' 'pv.mount' 'Review hostPath context for persistent volumes.'
	@printf '  %-28s%s\n' 'apps.nextcloud' 'Deploy or upgrade Nextcloud.'
	@printf '  %-28s%s\n' 'apps.jellyfin' 'Deploy Jellyfin and supporting workloads.'
	@printf '  %-28s%s\n' 'apps.nextcloud.reinstall' 'Force reinstallation of Nextcloud.'
	@printf '  %-28s%s\n' 'labz.dns' 'Group cluster bootstrap, networking, and app automation.'
	@printf '\nUse ENV_FILE=<path> to point at a custom environment file.\n'

LABZ_DNS_TARGETS := dns.ensure route.ensure pv.mount apps.jellyfin

.PHONY: preflight
preflight:
	./scripts/preflight.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.bootstrap
k8s.bootstrap:
	./scripts/k8s-bootstrap.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.clean
k8s.clean:
	./scripts/k8s-bootstrap.sh --env-file "$(ENV_FILE)" --clean

.PHONY: dns.ensure
dns.ensure:
	./scripts/dns-pfsense.sh --env-file "$(ENV_FILE)"

.PHONY: route.ensure
route.ensure:
	./scripts/net-ensure.sh --env-file "$(ENV_FILE)"

.PHONY: pv.mount
pv.mount:
	./scripts/uranus_homelab_apps.sh --env-file "$(ENV_FILE)" --context-preflight

.PHONY: apps.nextcloud
apps.nextcloud:
	./scripts/apps-nextcloud.sh --env-file "$(ENV_FILE)"

.PHONY: apps.jellyfin
apps.jellyfin:
	./scripts/apps-jellyfin.sh --env-file "$(ENV_FILE)"


.PHONY: apps.nextcloud.reinstall
apps.nextcloud.reinstall:
	./scripts/apps-nextcloud.sh --env-file "$(ENV_FILE)" --reinstall

.PHONY: status
status:
	@bash ./scripts/status.sh

.PHONY: down
down: k8s.clean

.PHONY: labz.dns
labz.dns: k8s.bootstrap $(LABZ_DNS_TARGETS)

.PHONY: up
up: preflight k8s.bootstrap dns.ensure route.ensure pv.mount apps.jellyfin

# Legacy pfSense automation (disabled by default)
# .PHONY: pf.preflight pf.config pf.ztp
# pf.preflight:
# 	./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"
# pf.config:
# 	sudo ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"
# pf.ztp:
# 	sudo ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"

k8s.storage.apply:
	kubectl apply -f k8s/base/storageclass.yaml
	kubectl create ns data --dry-run=none -o yaml | kubectl apply -f - || true
	kubectl create ns django --dry-run=none -o yaml | kubectl apply -f - || true
	kubectl create ns minecraft --dry-run=none -o yaml | kubectl apply -f - || true
	kubectl apply -f k8s/storage/postgres-hostpath.yaml
	kubectl apply -f k8s/storage/django-media-hostpath.yaml
	kubectl apply -f k8s/storage/minecraft-hostpath.yaml

k8s.metallb.apply:
	kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.3/config/manifests/metallb-native.yaml
	kubectl -n metallb-system rollout status deploy/controller --timeout=120s
	kubectl apply -f k8s/addons/metallb/ip-pool.yaml

k8s.traefik.apply:
	kubectl create ns traefik --dry-run=none -o yaml | kubectl apply -f - || true
	helm repo add traefik https://traefik.github.io/charts
	helm repo update
	helm upgrade --install traefik traefik/traefik -n traefik -f k8s/traefik/values.yaml

k8s.cert.apply:
	kubectl apply -f k8s/cert-manager/cm-internal-ca.yaml

apps.django.apply:
	kubectl apply -f k8s/apps/django-hello/namespace.yaml
	kubectl apply -f k8s/apps/django-hello/deployment.yaml
	kubectl apply -f k8s/apps/django-hello/service.yaml
	kubectl apply -f k8s/apps/django-hello/certificate.yaml
	kubectl apply -f k8s/apps/django-hello/ingress.yaml

apps.minecraft.apply:
	kubectl apply -f k8s/apps/minecraft/namespace.yaml
	kubectl apply -f k8s/apps/minecraft/deployment.yaml
	kubectl apply -f k8s/apps/minecraft/service.yaml

apps.nextcloud.ingress.apply:
	kubectl apply -f k8s/apps/nextcloud/ingress.yaml

up.phase1_4:
	./scripts/minikube-up.sh
	$(MAKE) k8s.storage.apply
	$(MAKE) k8s.metallb.apply
	$(MAKE) k8s.traefik.apply
	$(MAKE) k8s.cert.apply
	$(MAKE) apps.django.apply
	$(MAKE) apps.minecraft.apply
	$(MAKE) apps.nextcloud.ingress.apply
