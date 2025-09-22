SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env
PF_VM_NAME ?= pfsense-uranus
BATS ?= tests/vendor/bats-core/bin/bats

.PHONY: help
help:
	@echo "Targets:"
	@echo "  test            - Run repository test suite"
	@echo "  up              - Run full bootstrap: pfSense + Kubernetes + status"
	@echo "  net.ensure      - Ensure WAN/LAN bridges are present"
	@echo "  preflight       - Ensure pfSense VM is running & IPs sane"
	@echo "  pf.config       - Render pfSense config ISO/assets"
	@echo "  pf.install      - Stage installer media and run pf-ztp (virt-install + wiring)"
	@echo "  pf.ztp          - Re-run pf-ztp to refresh installer/media wiring"
	@echo "  pf.smoketest    - Run pfSense smoketest"
	@echo "  k8s.up          - Prepare kubectl context for the homelab cluster"
	@echo "  k8s.smoketest   - Validate Kubernetes readiness"
	@echo "  k8s.bootstrap   - Run k8s.up and k8s.smoketest together"
	@echo "  status          - Emit current bootstrap status marker"
	@echo "  check.env       - Show key environment values"

.PHONY: check.env
check.env:
	@echo "Using environment file $(ENV_FILE)"
	@test -f $(ENV_FILE) && grep -E '^(LAN_CIDR|LAN_GW_IP|PF_VM_NAME|PF_LAN_BRIDGE|PF_WAN_BRIDGE|WAN_MODE|WAN_NIC|PF_OSINFO|PF_SERIAL_INSTALLER_PATH|LABZ_METALLB_RANGE|TRAEFIK_LOCAL_IP)=' $(ENV_FILE) || true

.PHONY: net.ensure
net.ensure:
	@echo "Ensuring pfSense network bridges exist..."
	@chmod +x ./scripts/net-ensure-bridge.sh
	@if [[ -f "$(ENV_FILE)" ]]; then source "$(ENV_FILE)"; else echo "Environment file $(ENV_FILE) not found" >&2; exit 1; fi
	@: "$${PF_WAN_BRIDGE:?PF_WAN_BRIDGE must be set in $(ENV_FILE)}"
	@: "$${PF_LAN_BRIDGE:?PF_LAN_BRIDGE must be set in $(ENV_FILE)}"
	@./scripts/net-ensure-bridge.sh "$$PF_WAN_BRIDGE"
	@./scripts/net-ensure-bridge.sh "$$PF_LAN_BRIDGE"

.PHONY: preflight
preflight:
	@echo "Running pfSense preflight..."
	@chmod +x ./scripts/pf-preflight.sh
	@./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"

.PHONY: pf.config
pf.config:
	@echo "Rendering pfSense config from $(ENV_FILE)"
	@sudo ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"

.PHONY: pf.install
pf.install:
	@echo "Preparing pfSense installer media..."
	@chmod +x ./scripts/pf-installer-prepare.sh ./scripts/pf-ztp.sh
	@sudo ./scripts/pf-installer-prepare.sh --env-file "$(ENV_FILE)"
	@echo "Ensuring pfSense VM and bootstrap media via pf-ztp..."
	@sudo ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"

.PHONY: pf.ztp
pf.ztp:
	@echo "Running pfSense ZTP..."
	@chmod +x ./scripts/pf-ztp.sh
	@sudo ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"
	@echo "pfSense ZTP done."

.PHONY: pf.smoketest
pf.smoketest:
	@chmod +x ./scripts/pf-smoketest.sh
	@if [[ -f "$(ENV_FILE)" ]]; then source "$(ENV_FILE)"; else echo "Environment file $(ENV_FILE) not found" >&2; exit 1; fi
	@: "$${PF_LAN_BRIDGE:?PF_LAN_BRIDGE must be set in $(ENV_FILE)}"
	@./scripts/pf-smoketest.sh --env-file "$(ENV_FILE)" --lan-bridge "$$PF_LAN_BRIDGE"

.PHONY: k8s.up
k8s.up:
	@echo "Configuring Kubernetes context..."
	@chmod +x ./scripts/k8s-up.sh
	@./scripts/k8s-up.sh

.PHONY: k8s.smoketest
k8s.smoketest:
	@echo "Running Kubernetes smoketest..."
	@chmod +x ./scripts/k8s-smoketest.sh
	@./scripts/k8s-smoketest.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.bootstrap
k8s.bootstrap: k8s.up k8s.smoketest
	@echo "Kubernetes bootstrap complete."

.PHONY: status
status:
	@chmod +x ./scripts/resume-state.sh
	@./scripts/resume-state.sh --env-file "$(ENV_FILE)"

.PHONY: up
up: net.ensure preflight pf.config pf.install pf.smoketest k8s.up k8s.smoketest status
	@echo "Homelab bootstrap complete."
.PHONY: test
test:
	@echo "Running Bats test suite..."
	@$(BATS) tests/bats
	@./scripts/tests/retry_test.sh

