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

all: k8s db awx obs apps flux

pfSense:
	@$(DIR)/pfsense/pf-bootstrap.sh
	@$(DIR)/pfsense/pf-config-gen.sh

k8s:
	@$(DIR)/k8s/cluster-up.sh

db:
	@kubectl apply -f $(DIR)/data/postgres/backup-pv.yaml
	@helm upgrade --install pg bitnami/postgresql -n data -f $(DIR)/data/postgres/pg-values.yaml --create-namespace --wait
	@kubectl apply -f $(DIR)/data/postgres/backup-cron.yaml

awx:
	@kubectl create ns awx --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f $(DIR)/awx/certs.yaml
	@kubectl apply -f $(DIR)/awx/awx-small.yaml

obs:
	@kubectl create ns observability --dry-run=client -o yaml | kubectl apply -f -
	@helm upgrade --install kps prometheus-community/kube-prometheus-stack -n observability -f $(DIR)/observability/kps-values.yaml --wait
	@kubectl apply -f $(DIR)/observability/certs.yaml

apps:
	@kubectl create ns apps --dry-run=client -o yaml | kubectl apply -f -
	@$(DIR)/apps/django-multiproject/load-image.sh || true
	@envsubst < $(DIR)/apps/django-multiproject/deploy.yaml | kubectl apply -f -

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
