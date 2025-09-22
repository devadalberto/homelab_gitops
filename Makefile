# IMPORTANT: This file uses TAB characters for all recipe lines.

SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env
BATS ?= tests/vendor/bats-core/bin/bats

.PHONY: help
help:
	@echo "Targets:"
	@echo "  doctor          - Verify host tooling and print required .env keys"
	@echo "  net.ensure      - Ensure WAN/LAN bridges exist (NET_CREATE=1 to create)"
	@echo "  pf.preflight    - Validate .env (bridges, LAN, DHCP, installer media)"
	@echo "  pf.config       - Render pfSense config.xml and config ISO"
	@echo "  pf.ztp          - Attach media/seed pfSense VM"
	@echo "  k8s.bootstrap   - Bring up Minikube/core addons/Flux"
	@echo "  status          - Summarize VM and K8s readiness"
	@echo "  clean           - Remove generated artifacts"
	@echo "  up              - Full bootstrap: doctor → net.ensure → pf.preflight → pf.config → pf.ztp → k8s.bootstrap → status"

.PHONY: doctor
doctor:
	./scripts/doctor.sh --env-file "$(ENV_FILE)"

.PHONY: net.ensure
net.ensure:
	NET_CREATE=${NET_CREATE:-0} ./scripts/net-ensure.sh --env-file "$(ENV_FILE)"

.PHONY: pf.preflight
pf.preflight:
	./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"

.PHONY: pf.config
pf.config:
	sudo ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"

.PHONY: pf.ztp
pf.ztp:
	sudo ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.bootstrap
k8s.bootstrap:
	./scripts/k8s-up.sh --env-file "$(ENV_FILE)"

.PHONY: status
status:
	./scripts/status.sh --env-file "$(ENV_FILE)"

.PHONY: clean
clean:
	./scripts/clean.sh --env-file "$(ENV_FILE)"

.PHONY: up
up:
	@echo "Using environment file $(ENV_FILE)"
	make doctor ENV_FILE="$(ENV_FILE)"
	NET_CREATE=1 make net.ensure ENV_FILE="$(ENV_FILE)"
	make pf.preflight ENV_FILE="$(ENV_FILE)"
	sudo make pf.config ENV_FILE="$(ENV_FILE)"
	sudo make pf.ztp ENV_FILE="$(ENV_FILE)"
	make k8s.bootstrap ENV_FILE="$(ENV_FILE)"
	make status ENV_FILE="$(ENV_FILE)"
