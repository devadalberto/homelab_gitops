SHELL := /bin/bash
DIR := $(shell pwd)
ENVFILE := $(DIR)/.env
ifeq ("$(wildcard $(ENVFILE))","")
  ENVFILE := $(DIR)/.env.example
endif
include $(ENVFILE)
export

.PHONY: all pfSense k8s db awx obs apps flux clean up nukedown docs docs-serve docs-diagrams

MERMAID_CLI ?= npx --yes @mermaid-js/mermaid-cli@10.6.1
MERMAID_SOURCES := $(shell find docs -name '*.mmd' 2>/dev/null)
MERMAID_TARGETS := $(MERMAID_SOURCES:.mmd=.svg)
MKDOCS ?= mkdocs
MKDOCS_BUILD_FLAGS ?= --strict

docs-diagrams: $(MERMAID_TARGETS)

docs/%.svg: docs/%.mmd
	@mkdir -p $(dir $@)
	$(MERMAID_CLI) -i $< -o $@

docs: docs-diagrams
	$(MKDOCS) build $(MKDOCS_BUILD_FLAGS)

docs-serve: docs-diagrams
	$(MKDOCS) serve -a 0.0.0.0:8000

all: k8s flux

pfSense:
	@$(DIR)/pfsense/pf-bootstrap.sh
	@$(DIR)/pfsense/pf-config-gen.sh

k8s:
	@$(DIR)/k8s/cluster-up.sh

db:
        @echo "PostgreSQL is reconciled by Flux (see k8s/data/postgres). Push changes and let Flux apply them."

awx:
        @echo "The AWX operator and instance are managed by Flux (k8s/addons/awx-operator)."

obs:
        @echo "Observability stack is deployed via Flux HelmRelease (k8s/observability)."

apps:
        @echo "Application manifests live under k8s/apps and are reconciled by Flux."

flux:
	@$(DIR)/flux/install.sh

clean:
	@echo "Nothing destructive here; clean by namespaces if needed."

up:
	@chmod +x scripts/*.sh
	./scripts/uranus_homelab.sh --delete-previous-environment --assume-yes --env-file ./.env

nukedown:
	@chmod +x scripts/*.sh
	./scripts/uranus_nuke_and_bootstrap.sh --delete-previous-environment --assume-yes --env-file ./.env
