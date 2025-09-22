SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.RECIPEPREFIX := >

ENV_FILE ?= ./.env
export ENV_FILE

NET_CREATE ?=
PF_VM_NAME ?= pfsense-uranus
BATS ?= tests/vendor/bats-core/bin/bats

.PHONY: help doctor docs check.env net.ensure preflight pf.config pf.install pf.ztp pf.smoketest \
        k8s.up k8s.bootstrap k8s.smoketest status up test lint ci

help:
> @printf "Homelab GitOps automation\n"
> @printf "=========================\n\n"
> @printf "Environment variables:\n"
> @printf "  ENV_FILE=<path>   Path to the environment overrides file (default: ./.env).\n"
> @printf "  NET_CREATE=1      Allow net.ensure to define missing libvirt networks.\n\n"
> @printf "Targets:\n"
> @printf "  help             Show this help message.\n"
> @printf "  doctor           Run non-mutating diagnostics against the host.\n"
> @printf "  check.env        Summarize environment configuration and live status.\n"
> @printf "  net.ensure       Ensure pfSense bridges and libvirt networks exist.\n"
> @printf "  preflight        Verify pfSense VM readiness and required IP settings.\n"
> @printf "  pf.config        Render pfSense configuration assets.\n"
> @printf "  pf.install       Prepare installer media and run pfSense zero-touch provisioning.\n"
> @printf "  pf.ztp           Re-run pfSense zero-touch provisioning helpers.\n"
> @printf "  pf.smoketest     Validate pfSense networking via smoketests.\n"
> @printf "  k8s.up           Configure kubectl context for the homelab cluster.\n"
> @printf "  k8s.bootstrap    Bootstrap Minikube and MetalLB.\n"
> @printf "  k8s.smoketest    Validate Kubernetes readiness.\n"
> @printf "  status           Emit the current bootstrap status marker.\n"
> @printf "  up               Run the full homelab bootstrap workflow.\n"
> @printf "  lint             Run linting checks.\n"
> @printf "  test             Run repository test suite.\n"
> @printf "  ci               Run linting and tests.\n"

# ---------------------------------------------------------------------------
# Host utilities
# ---------------------------------------------------------------------------

doctor:
> @echo "Running host diagnostics..."
> @./scripts/host-prep.sh --env-file "$(ENV_FILE)" --context-preflight

check.env:
> @./scripts/status.sh --env-file "$(ENV_FILE)"

# ---------------------------------------------------------------------------
# pfSense helpers
# ---------------------------------------------------------------------------

net.ensure:
> @NET_CREATE="$(NET_CREATE)" ./scripts/net-ensure.sh --env-file "$(ENV_FILE)"

preflight:
> @./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"

pf.config:
> @sudo -E ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"

pf.install:
> @sudo -E ./scripts/pf-installer-prepare.sh --env-file "$(ENV_FILE)"
> @sudo -E ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"

pf.ztp:
> @sudo -E ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"

pf.smoketest:
> @./scripts/pf-smoketest.sh --env-file "$(ENV_FILE)"

# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------

k8s.up:
> @./scripts/k8s-up.sh --env-file "$(ENV_FILE)"

k8s.bootstrap:
> @./scripts/preflight_and_bootstrap.sh --env-file "$(ENV_FILE)"

k8s.smoketest:
> @./scripts/k8s-smoketest.sh --env-file "$(ENV_FILE)"

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------

status:
> @./scripts/resume-state.sh --env-file "$(ENV_FILE)"

up: net.ensure preflight pf.config pf.install pf.smoketest k8s.up k8s.smoketest status
> @echo "Homelab bootstrap complete."

# ---------------------------------------------------------------------------
# Documentation and QA
# ---------------------------------------------------------------------------

docs:
> @echo "Building documentation with MkDocs..."
> @mkdocs build

lint:
> @echo "Running lint checks..."
> @missing_tools=0
> @for tool in shellcheck shfmt yamllint actionlint; do \
> if ! command -v "$$tool" >/dev/null 2>&1; then \
> echo "ERROR: $$tool is required but not installed." >&2; \
> missing_tools=1; \
> fi; \
> done; \
> if [[ $$missing_tools -ne 0 ]]; then \
> exit 1; \
> fi
> @echo "Running shellcheck..."
> @mapfile -t shellcheck_files < <(git ls-files -- '*.sh')
> @if (( $${#shellcheck_files[@]} )); then \
> shellcheck --severity=error --exclude=SC2259 "$$\{shellcheck_files[@]}"; \
> echo "shellcheck passed."; \
> else \
> echo "No shell scripts found for shellcheck."; \
> fi
> @echo "Running shfmt..."
> @mapfile -t shfmt_files < <(git ls-files -- ':(glob)scripts/**/*.sh' ':(top,glob)*.sh' ':(exclude)scripts/k8s-up.sh' ':(exclude)scripts/uranus_homelab_apps.sh')
> @if (( $${#shfmt_files[@]} )); then \
> if ! shfmt -d -i 2 "$$\{shfmt_files[@]}"; then \
> echo "ERROR: shfmt found formatting issues. Run 'shfmt -w -i 2' to fix." >&2; \
> exit 1; \
> fi; \
> echo "shfmt passed."; \
> else \
> echo "No shell scripts found for shfmt."; \
> fi
> @echo "Running yamllint..."
> @mapfile -t yaml_files < <(git ls-files -- '*.yml' '*.yaml')
> @if (( $${#yaml_files[@]} )); then \
> yamllint "$$\{yaml_files[@]}"; \
> echo "yamllint passed."; \
> else \
> echo "No YAML files found for yamllint."; \
> fi
> @echo "Running actionlint..."
> @actionlint
> @echo "actionlint passed."

test:
> @echo "Running Bats test suite..."
> @"$(BATS)" tests/bats
> @./scripts/tests/retry_test.sh

ci: lint test
