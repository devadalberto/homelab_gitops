SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -euo pipefail -c

ENV_FILE ?= ./.env
NET_CREATE ?=
BATS ?= ./tests/vendor/bats-core/bin/bats

export ENV_FILE

.PHONY: help doctor net.ensure pf.preflight pf.config pf.ztp k8s.bootstrap status clean up ci

help:
	@printf "Homelab GitOps automation\n"
	@printf "=========================\n\n"
	@printf "Environment variables:\n"
	@printf "  ENV_FILE=<path>   Path to the environment overrides file (default: ./.env).\n"
	@printf "  NET_CREATE=1      Allow pf.preflight to define missing libvirt networks.\n\n"
	@printf "Targets:\n"
	@printf "  help             Show this help message.\n"
        @printf "  doctor           Run host diagnostics for the homelab environment.\n"
        @printf "  net.ensure       Validate or create the pfSense WAN/LAN bridges.\n"
        @printf "  pf.preflight     Verify pfSense prerequisites and libvirt networking.\n"
	@printf "  pf.config        Render pfSense configuration assets.\n"
	@printf "  pf.ztp           Execute pfSense zero-touch provisioning.\n"
	@printf "  k8s.bootstrap    Bootstrap the Kubernetes cluster and addons.\n"
	@printf "  status           Summarize homelab bootstrap status.\n"
	@printf "  clean            Remove generated assets and cached artifacts.\n"
	@printf "  up               Run the full homelab bootstrap workflow.\n"
	@printf "  ci               Run continuous integration checks.\n"


doctor:
	@echo "Running homelab doctor..."
	@./scripts/doctor.sh --env-file "$(ENV_FILE)"

net.ensure:
        @echo "Ensuring pfSense host networking..."
        @NET_CREATE="$(NET_CREATE)" ./scripts/net-ensure.sh --env-file "$(ENV_FILE)"

pf.preflight:
        @echo "Running pfSense preflight checks..."
        @NET_CREATE="$(NET_CREATE)" ./scripts/net-ensure.sh --env-file "$(ENV_FILE)"
        @./scripts/pf-preflight.sh --env-file "$(ENV_FILE)"

pf.config:
	@echo "Generating pfSense configuration assets..."
	@sudo -E ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"

pf.ztp:
	@echo "Executing pfSense zero-touch provisioning..."
	@sudo -E ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)"

k8s.bootstrap:
	@echo "Bootstrapping Kubernetes platform..."
	@./scripts/k8s-bootstrap.sh --env-file "$(ENV_FILE)"

status:
	@echo "Gathering homelab status..."
	@./scripts/status.sh --env-file "$(ENV_FILE)"

clean:
        @./scripts/clean.sh --env-file "$(ENV_FILE)"


up: doctor net.ensure pf.preflight pf.config pf.ztp k8s.bootstrap status
	@echo "Homelab bootstrap workflow complete."

test:
	@$(BATS) tests

ci: test
