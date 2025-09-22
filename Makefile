SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

ENV_FILE ?= ./.env
PF_VM_NAME ?= pfsense-uranus
SITE_DIR ?= site

.PHONY: help
help:
	@echo "Targets:"
	@echo "  docs            - Build MkDocs documentation"
	@echo "  docs-serve      - Serve MkDocs documentation locally"
	@echo "  lint            - Run repository linters via pre-commit"
	@echo "  test            - Execute shell library tests"
	@echo "  ci              - Run lint and test suites"
	@echo "  up              - Run full bootstrap: pfSense + Kubernetes + status"
	@echo "  net.ensure      - Ensure WAN/LAN bridges are present"
	@echo "  preflight       - Ensure pfSense VM is running & IPs sane"
	@echo "  pf.config       - Render pfSense config ISO/assets"
	@echo "  pf.install      - Ensure pfSense VM exists (virt-install)"
	@echo "  pf.ztp          - Run pfSense bootstrap (installer optional if VM exists)"
	@echo "  pf.smoketest    - Run pfSense smoketest"
	@echo "  k8s.up          - Prepare kubectl context for the homelab cluster"
	@echo "  k8s.smoketest   - Validate Kubernetes readiness"
	@echo "  status          - Emit current bootstrap status marker"
	@echo "  check.env       - Show key environment values"

.PHONY: docs
docs:
	@command -v mkdocs >/dev/null 2>&1 || { echo "mkdocs not found. Install Python dependencies with 'pip install -r docs/requirements.txt'." >&2; exit 1; }
	@echo "Building MkDocs documentation into $(SITE_DIR)..."
	@mkdocs build --strict --clean --site-dir "$(SITE_DIR)"

.PHONY: docs-serve
docs-serve:
	@command -v mkdocs >/dev/null 2>&1 || { echo "mkdocs not found. Install Python dependencies with 'pip install -r docs/requirements.txt'." >&2; exit 1; }
	@mkdocs serve --dev-addr=0.0.0.0:8000

.PHONY: lint
lint:
	@command -v pre-commit >/dev/null 2>&1 || { echo "pre-commit not found. Install it with 'pip install pre-commit'." >&2; exit 1; }
	@pre-commit run --all-files --show-diff-on-failure

.PHONY: test
test:
	@./scripts/tests/retry_test.sh

.PHONY: ci
ci: lint test
	@echo "All CI checks completed successfully."

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
	@echo "Running pfSense preflight..."
	@chmod +x ./scripts/pf-preflight.sh
	@./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"

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

.PHONY: status
status:
	@chmod +x ./scripts/resume-state.sh
	@./scripts/resume-state.sh --env-file "$(ENV_FILE)"

.PHONY: up
up: net.ensure preflight pf.config pf.install pf.ztp pf.smoketest k8s.up k8s.smoketest status
	@echo "Homelab bootstrap complete."
