SHELL := /bin/bash

REPO_ROOT := $(CURDIR)

# Detect the environment file once so all targets share the same configuration.
ifeq ($(origin ENV_FILE), undefined)
ENV_FILE := $(firstword $(wildcard $(REPO_ROOT)/.env) $(wildcard $(REPO_ROOT)/.env.example))
endif
ifeq ($(ENV_FILE),)
$(error No environment file found. Set ENV_FILE=/path/to/.env or copy .env.example to .env.)
endif
ENV_FILE := $(abspath $(ENV_FILE))
ifeq (,$(wildcard $(ENV_FILE)))
$(error Environment file '$(ENV_FILE)' not found. Set ENV_FILE to an existing file.)
endif

ASSUME_YES ?= true
DELETE_EXISTING ?= true
HOLD_PORT_FORWARD ?= false

TRUE_VALUES := 1 true yes on
ASSUME_YES_NORMALIZED := $(shell printf '%s' "$(ASSUME_YES)" | tr '[:upper:]' '[:lower:]')
DELETE_EXISTING_NORMALIZED := $(shell printf '%s' "$(DELETE_EXISTING)" | tr '[:upper:]' '[:lower:]')
HOLD_PORT_FORWARD_NORMALIZED := $(shell printf '%s' "$(HOLD_PORT_FORWARD)" | tr '[:upper:]' '[:lower:]')

ASSUME_ARG := $(if $(filter $(TRUE_VALUES),$(ASSUME_YES_NORMALIZED)),--assume-yes,)
DELETE_ARG := $(if $(filter $(TRUE_VALUES),$(DELETE_EXISTING_NORMALIZED)),--delete-previous-environment,)
HOLD_PORT_FORWARD_ARG := $(if $(filter $(TRUE_VALUES),$(HOLD_PORT_FORWARD_NORMALIZED)),--hold-port-forward,)

ENV_ARG := --env-file $(ENV_FILE)
COMMON_ARGS := $(ENV_ARG) $(ASSUME_ARG)

KUBECTL ?= kubectl
FLUX ?= flux
PRECOMMIT ?= pre-commit
MINIKUBE ?= minikube

MINIKUBE_PROFILE ?= $(strip $(shell sed -n 's/^LABZ_MINIKUBE_PROFILE=//p' "$(ENV_FILE)" | tail -n 1))
ifeq ($(MINIKUBE_PROFILE),)
MINIKUBE_PROFILE := labz
endif

PF_VM_NAME ?= $(strip $(shell sed -n 's/^PF_VM_NAME=//p' "$(ENV_FILE)" | tail -n 1))
ifeq ($(PF_VM_NAME),)
PF_VM_NAME := $(strip $(shell sed -n 's/^VM_NAME=//p' "$(ENV_FILE)" | tail -n 1))
endif
ifeq ($(PF_VM_NAME),)
PF_VM_NAME := pfsense-uranus
endif

FLUX_NAMESPACE ?= flux-system
FLUX_KUSTOMIZATION ?= flux-system

LOGS_NAMESPACE ?= $(FLUX_NAMESPACE)
LOGS_SELECTOR ?= app.kubernetes.io/name=kustomize-controller
LOGS_CONTAINER ?=
LOGS_TAIL ?= 200
LOGS_SINCE ?=
LOGS_FOLLOW ?= false
LOGS_FOLLOW_NORMALIZED := $(shell printf '%s' "$(LOGS_FOLLOW)" | tr '[:upper:]' '[:lower:]')
LOGS_FOLLOW_FLAG := $(if $(filter $(TRUE_VALUES),$(LOGS_FOLLOW_NORMALIZED)),--follow,)

MERMAID_CLI ?= npx --yes @mermaid-js/mermaid-cli@10.6.1
MERMAID_SOURCES := $(shell find docs -name '*.mmd' 2>/dev/null)
MERMAID_TARGETS := $(MERMAID_SOURCES:.mmd=.svg)
MKDOCS ?= mkdocs
MKDOCS_BUILD_FLAGS ?= --strict

POSTGRES_HELM_VERSION ?= $(strip $(shell sed -n 's/^LABZ_POSTGRES_HELM_VERSION=//p' "$(ENV_FILE)" | tail -n 1))
ifeq ($(POSTGRES_HELM_VERSION),)
POSTGRES_HELM_VERSION := 16.2.6
endif

.PHONY: up preflight bootstrap core-addons apps db post-check down status logs reconcile destroy fmt lint docs docs-serve docs-diagrams

$(info Using environment file $(ENV_FILE))

up: preflight core-addons apps post-check
	@echo "Homelab bootstrap complete."

preflight:
	sudo ./pfsense/pf-config-gen.sh --env-file "$(ENV_FILE)"
	installer_path="$$(awk -F= '
	  /^[[:space:]]*PF_SERIAL_INSTALLER_PATH[[:space:]]*=/ {
	    val=$$2
	    gsub(/^[[:space:]]+|[[:space:]]+$$/, "", val)
	    if (val != "") { print val; exit }
	  }
	  /^[[:space:]]*PF_ISO_PATH[[:space:]]*=/ {
	    val=$$2
	    gsub(/^[[:space:]]+|[[:space:]]+$$/, "", val)
	    if (val != "") { print val; exit }
	  }
	' "$(ENV_FILE)")"; \
	if [ -n "$$installer_path" ]; then \
		sudo ./pfsense/pf-bootstrap.sh --env-file "$(ENV_FILE)" --headless --installation-path "$$installer_path"; \
	else \
		sudo ./pfsense/pf-bootstrap.sh --env-file "$(ENV_FILE)" --headless; \
	fi
        pf_ztp_status=0; \
        sudo ./scripts/pf-ztp.sh --env-file "$(ENV_FILE)" --vm-name "$(PF_VM_NAME)" --verbose --lenient || pf_ztp_status=$$?; \
        if [ $$pf_ztp_status -ne 0 ]; then \
          if [ $$pf_ztp_status -eq 2 ]; then \
            echo "pfSense ZTP connectivity checks failed; aborting bootstrap." >&2; \
          else \
            echo "pfSense ZTP stage failed (exit $$pf_ztp_status); aborting bootstrap." >&2; \
          fi; \
          exit $$pf_ztp_status; \
        fi
        ./scripts/preflight_and_bootstrap.sh $(COMMON_ARGS) $(DELETE_ARG) --preflight-only

bootstrap: preflight
	./scripts/uranus_nuke_and_bootstrap.sh $(COMMON_ARGS) $(DELETE_ARG) $(HOLD_PORT_FORWARD_ARG)

core-addons: bootstrap
	./scripts/uranus_homelab_one.sh $(COMMON_ARGS)

apps: core-addons
	./scripts/uranus_homelab_apps.sh $(COMMON_ARGS)

db:
	$(KUBECTL) apply -f $(REPO_ROOT)/data/postgres/backup-pv.yaml
	helm upgrade --install pg bitnami/postgresql \
	    --version $(POSTGRES_HELM_VERSION) \
	    --namespace data \
	    --values $(REPO_ROOT)/values/postgresql.yaml \
	    --create-namespace --wait
	$(KUBECTL) apply -f $(REPO_ROOT)/data/postgres/backup-cron.yaml

post-check:
	$(KUBECTL) get nodes -o wide
	$(KUBECTL) get pods --all-namespaces
	$(KUBECTL) -n metallb-system get ippools,l2advertisements
	$(KUBECTL) -n traefik get svc traefik -o wide
	$(KUBECTL) -n cert-manager get certificaterequests,certificates

# Stop the Minikube profile without deleting workloads.
down:
	$(MINIKUBE) stop -p $(MINIKUBE_PROFILE)

status:
	$(KUBECTL) get nodes -o wide
	$(KUBECTL) get pods --all-namespaces
	@if command -v $(FLUX) >/dev/null 2>&1; then \
	$(FLUX) get kustomizations --namespace $(FLUX_NAMESPACE); \
	else \
	echo "flux CLI not found; skipping Flux status" >&2; \
	fi

logs:
	$(KUBECTL) -n $(LOGS_NAMESPACE) logs -l $(LOGS_SELECTOR) --tail=$(LOGS_TAIL) $(LOGS_FOLLOW_FLAG) $(if $(LOGS_SINCE),--since=$(LOGS_SINCE),) $(if $(LOGS_CONTAINER),-c $(LOGS_CONTAINER),)

reconcile:
	$(FLUX) reconcile kustomization $(FLUX_KUSTOMIZATION) --namespace $(FLUX_NAMESPACE) --with-source

# WARNING: Permanently deletes the Minikube profile and its workloads.
destroy:
	@echo "Deleting Minikube profile '$(MINIKUBE_PROFILE)'."
	$(MINIKUBE) delete -p $(MINIKUBE_PROFILE)

fmt:
	$(PRECOMMIT) run --all-files

lint: fmt

docs-diagrams: $(MERMAID_TARGETS)

docs/%.svg: docs/%.mmd
	@mkdir -p $(dir $@)
	$(MERMAID_CLI) -i $< -o $@

docs: docs-diagrams
	$(MKDOCS) build $(MKDOCS_BUILD_FLAGS)

docs-serve: docs-diagrams
	$(MKDOCS) serve -a 0.0.0.0:8000
