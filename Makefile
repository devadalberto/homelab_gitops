SHELL := /bin/bash
DIR := $(shell pwd)
ENVFILE := $(DIR)/.env
ifeq ("$(wildcard $(ENVFILE))","")
  ENVFILE := $(DIR)/.env.example
endif
include $(ENVFILE)
export

.PHONY: all pfSense k8s db awx obs apps flux clean up nukedown

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
	@$(DIR)/awx/operator/install.sh
	@kubectl apply -f $(DIR)/awx/certs.yaml
	@kubectl apply -f $(DIR)/awx/awx-small.yaml

obs:
	@kubectl create ns observability --dry-run=client -o yaml | kubectl apply -f -
	@helm upgrade --install kps prometheus-community/kube-prometheus-stack -n observability -f $(DIR)/observability/kps-values.yaml --wait
	@kubectl apply -f $(DIR)/observability/certs.yaml

apps:
	@kubectl create ns apps --dry-run=client -o yaml | kubectl apply -f -
	@$(DIR)/apps/django-multiproject/load-image.sh || true
	@kubectl apply -f $(DIR)/apps/django-multiproject/deploy.yaml

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
