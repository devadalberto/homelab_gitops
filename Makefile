# IMPORTANT: This file uses TAB characters for all recipe lines.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env

.PHONY: help up down status preflight k8s.bootstrap k8s.clean apps.nextcloud apps.nextcloud.reinstall apps.jellyfin labz.dns

help:
	@printf '%s\n' 'Targets:'
	@printf '  %-28s%s\n' 'up' 'Run preflight, bootstrap Kubernetes, and deploy Nextcloud.'
	@printf '  %-28s%s\n' 'down' 'Tear down Kubernetes resources.'
	@printf '  %-28s%s\n' 'status' 'Summarize the environment state.'
	@printf '  %-28s%s\n' 'preflight' 'Run host and configuration validation.'
	@printf '  %-28s%s\n' 'k8s.bootstrap' 'Bootstrap the Kubernetes cluster.'
	@printf '  %-28s%s\n' 'k8s.clean' 'Remove the Kubernetes cluster profile.'
	@printf '  %-28s%s\n' 'apps.nextcloud' 'Deploy or upgrade Nextcloud.'
	@printf '  %-28s%s\n' 'apps.jellyfin' 'Summarize Jellyfin DNS requirements.'
	@printf '  %-28s%s\n' 'apps.nextcloud.reinstall' 'Force reinstallation of Nextcloud.'
	@printf '  %-28s%s\n' 'labz.dns' 'Group Kubernetes bootstrapping and LABZ app DNS helpers.'
	@printf '\nUse ENV_FILE=<path> to point at a custom environment file.\n'

LABZ_DNS_TARGETS := k8s.bootstrap apps.nextcloud apps.jellyfin

.PHONY: preflight
preflight:
	./scripts/preflight.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.bootstrap
k8s.bootstrap:
	./scripts/k8s-bootstrap.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.clean
k8s.clean:
	./scripts/k8s-bootstrap.sh --env-file "$(ENV_FILE)" --clean

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
labz.dns: $(LABZ_DNS_TARGETS)

.PHONY: up
up: preflight labz.dns

# Legacy pfSense automation (disabled by default)
# .PHONY: pf.preflight pf.config pf.ztp
# pf.preflight:
# 	./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"
# pf.config:
# 	sudo ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"
# pf.ztp:
# 	sudo ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"
