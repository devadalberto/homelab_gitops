SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env
PF_VM_NAME ?= pfsense-uranus

SHELL_SCRIPTS := $(shell git ls-files '*.sh' ':!:pfsense/*')
YAML_FILES := $(shell git ls-files '*.yml' '*.yaml' ':!.github/workflows/*.yml' ':!.github/workflows/*.yaml')
ACTIONLINT_FILES := $(shell git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' ':!.github/workflows/gitops-ci.yml')

.PHONY: help
help:
	@echo "Targets:"
	@echo "  up              - Run full bootstrap: pfSense + Kubernetes + status"
	@echo "  net.ensure      - Ensure WAN/LAN bridges are present"
	@echo "  preflight       - Run host and pfSense preflight checks"
	@echo "  pf.config       - Render pfSense config ISO/assets"
	@echo "  pf.install      - Ensure pfSense VM exists (virt-install)"
	@echo "  pf.ztp          - Run pfSense bootstrap (installer optional if VM exists)"
	@echo "  pf.smoketest    - Run pfSense smoketest"
	@echo "  k8s.bootstrap   - Recreate the homelab Minikube cluster"
	@echo "  k8s.smoketest   - Validate Kubernetes readiness"
	@echo "  status          - Emit current bootstrap status marker"
	@echo "  check.env       - Show key environment values"
	@echo "  lint            - Run shellcheck, shfmt, yamllint, and actionlint"
	@echo "  test            - Execute the Bats test suite"
	@echo "  ci              - Run lint and test checks"

.PHONY: check.env
check.env:
	@echo "Using environment file $(ENV_FILE)"
	@test -f $(ENV_FILE) && grep -E '^(LAN_CIDR|LAN_GW_IP|PF_VM_NAME|PF_LAN_BRIDGE|PF_WAN_BRIDGE|WAN_MODE|WAN_NIC|PF_OSINFO|PF_INSTALLER_SRC|LABZ_METALLB_RANGE|TRAEFIK_LOCAL_IP)=' $(ENV_FILE) || true

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
	@echo "Running homelab host preflight..."
	@chmod +x ./scripts/preflight_and_bootstrap.sh
	@./scripts/preflight_and_bootstrap.sh --env-file "$(ENV_FILE)" --preflight-only
	@echo "Running pfSense preflight..."
	@chmod +x ./scripts/pf-preflight.sh
	@sudo -E ./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"

.PHONY: pf.config
pf.config:
	@echo "Rendering pfSense config from $(ENV_FILE)"
	@sudo -E ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"

.PHONY: pf.install
pf.install:
	@echo "Ensuring pfSense VM exists..."
	@chmod +x ./scripts/pf-vm-install.sh
	@sudo -E ./scripts/pf-vm-install.sh --env-file "$(ENV_FILE)"

.PHONY: pf.ztp
pf.ztp:
	@echo "Running pfSense ZTP..."
	@chmod +x ./scripts/pf-ztp.sh
	@sudo -E ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)" --vm-name "$(PF_VM_NAME)"
	@echo "pfSense ZTP done."

.PHONY: pf.smoketest
pf.smoketest:
	@chmod +x ./scripts/pf-smoketest.sh
	@if [[ -f "$(ENV_FILE)" ]]; then source "$(ENV_FILE)"; else echo "Environment file $(ENV_FILE) not found" >&2; exit 1; fi
	@: "$${PF_LAN_BRIDGE:?PF_LAN_BRIDGE must be set in $(ENV_FILE)}"
	@./scripts/pf-smoketest.sh --env-file "$(ENV_FILE)" --lan-bridge "$$PF_LAN_BRIDGE"

.PHONY: k8s.bootstrap
k8s.bootstrap:
	@echo "Bootstrapping Kubernetes cluster..."
	@chmod +x ./scripts/uranus_nuke_and_bootstrap.sh
	@./scripts/uranus_nuke_and_bootstrap.sh --env-file "$(ENV_FILE)"

.PHONY: k8s.up
k8s.up:
	@$(MAKE) k8s.bootstrap

.PHONY: k8s.smoketest
k8s.smoketest:
	@echo "Running Kubernetes smoketest..."
	@chmod +x ./scripts/k8s-smoketest.sh
	@./scripts/k8s-smoketest.sh --env-file "$(ENV_FILE)"

.PHONY: status
status:
	@chmod +x ./scripts/status.sh
	@./scripts/status.sh --env-file "$(ENV_FILE)"

.PHONY: lint lint.shellcheck lint.shfmt lint.yamllint lint.actionlint
lint: lint.shellcheck lint.shfmt lint.yamllint lint.actionlint

lint.shellcheck:
	@shellcheck --external-sources $(SHELL_SCRIPTS)

lint.shfmt:
	@shfmt -d -i 2 $(SHELL_SCRIPTS)

lint.yamllint:
	@yamllint -c .yamllint $(YAML_FILES)

lint.actionlint:
	@actionlint $(ACTIONLINT_FILES)

.PHONY: test
test:
	@bats --print-output-on-failure -r scripts/tests

.PHONY: ci
ci:
	@$(MAKE) lint
	@$(MAKE) test

.PHONY: up
up: net.ensure preflight pf.config pf.install pf.ztp pf.smoketest k8s.bootstrap k8s.smoketest status
	@echo "Homelab bootstrap complete."
