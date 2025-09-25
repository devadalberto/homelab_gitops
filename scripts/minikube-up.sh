#!/usr/bin/env bash
set -euo pipefail
: "${MINIKUBE_CPUS:=2}"
: "${MINIKUBE_MEMORY_MB:=8192}"
: "${MINIKUBE_DISK_SIZE:=40g}"
minikube start --driver=docker --cpus="${MINIKUBE_CPUS}" --memory="${MINIKUBE_MEMORY_MB}" --disk-size="${MINIKUBE_DISK_SIZE}"
minikube addons enable metrics-server
