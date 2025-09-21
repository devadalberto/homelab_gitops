SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env
PF_VM_NAME ?= pfsense-uranus

.PHONY: help
help:
	@echo "Targets:"
	@echo "  up            - Preflight, render pf config, ensure VM exists, run ZTP"
	@echo "  preflight     - Ensure pfSense VM is running & IPs sane"
	@echo "  pf.install    - Ensure pfSense VM exists (virt-install)"
	@echo "  pf.ztp        - Run pfSense bootstrap (installer optional if VM exists)"
	@echo "  pf.config     - Render pfSense config ISO/assets"
	@echo "  check.env     - Show key environment values"

.PHONY: check.env
check.env:
	@echo "Using environment file $(ENV_FILE)"
	@test -f $(ENV_FILE) && grep -E '^(LAN_CIDR|LAN_GW_IP|PF_VM_NAME|PF_LAN_BRIDGE|PF_WAN_BRIDGE|WAN_MODE|WAN_NIC|PF_OSINFO|PF_INSTALLER_SRC|LABZ_METALLB_RANGE|TRAEFIK_LOCAL_IP)=' $(ENV_FILE) || true

.PHONY: preflight
preflight:
	@echo "Running pfSense preflight..."
	@chmod +x ./scripts/pf-preflight.sh
	@./scripts/pf-preflight.sh "$(ENV_FILE)"

.PHONY: pf.config
pf.config:
	@echo "Rendering pfSense config from $(ENV_FILE)"
	@sudo ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"

.PHONY: pf.install
pf.install:
	@echo "Ensuring pfSense VM exists..."
	@chmod +x ./scripts/pf-vm-install.sh
	@./scripts/pf-vm-install.sh --env-file "$(ENV_FILE)"

.PHONY: pf.ztp
pf.ztp:
	@echo "Running pfSense ZTP..."
	@chmod +x ./pfsense/pf-bootstrap.sh
	@sudo ./pfsense/pf-bootstrap.sh --env-file "$(ENV_FILE)" --headless
	@echo "pfSense ZTP done."

.PHONY: up
up: preflight pf.config pf.install pf.ztp
	@echo "Homelab bootstrap complete."
