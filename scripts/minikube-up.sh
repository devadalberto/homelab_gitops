#!/usr/bin/env bash
set -euo pipefail
: "${MINIKUBE_CPUS:=2}"
: "${MINIKUBE_MEMORY_MB:=10240}"
: "${MINIKUBE_DISK_SIZE:=40g}"
: "${MINIKUBE_DRIVER:=docker}"
: "${MINIKUBE_FORCE_RESET:=0}"
minikube config set cpus "${MINIKUBE_CPUS}"
minikube config set memory "${MINIKUBE_MEMORY_MB}"
minikube config set disk-size "${MINIKUBE_DISK_SIZE}"
if [ "${MINIKUBE_FORCE_RESET}" = "1" ]; then minikube delete -p minikube -f || true || true; fi
minikube start --driver="${MINIKUBE_DRIVER}"
minikube addons enable metrics-server
