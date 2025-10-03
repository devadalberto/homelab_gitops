#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then . "$ENV_FILE"; fi
DOMAIN_BASE="${DOMAIN_BASE:-home.arpa}"
TRAEFIK_LB_IP="${TRAEFIK_LB_IP:-192.168.88.201}"
NEXTCLOUD_LB_IP="${NEXTCLOUD_LB_IP:-192.168.88.202}"
DJANGO_LB_IP="${DJANGO_LB_IP:-192.168.88.203}"
MINECRAFT_LB_IP="${MINECRAFT_LB_IP:-192.168.88.204}"
TRAEFIK_HOST="traefik.${DOMAIN_BASE}"
NEXTCLOUD_HOST="nextcloud.${DOMAIN_BASE}"
DJANGO_HOST="django.${DOMAIN_BASE}"
MINECRAFT_HOST="minecraft.${DOMAIN_BASE}"
TMP="$(mktemp)"
grep -vE "[[:space:]]${TRAEFIK_HOST}([[:space:]]|$)|[[:space:]]${NEXTCLOUD_HOST}([[:space:]]|$)|[[:space:]]${DJANGO_HOST}([[:space:]]|$)|[[:space:]]${MINECRAFT_HOST}([[:space:]]|$)" /etc/hosts >"$TMP" || true
echo "${TRAEFIK_LB_IP} ${TRAEFIK_HOST}" >>"$TMP"
echo "${NEXTCLOUD_LB_IP} ${NEXTCLOUD_HOST}" >>"$TMP"
echo "${DJANGO_LB_IP} ${DJANGO_HOST}" >>"$TMP"
echo "${MINECRAFT_LB_IP} ${MINECRAFT_HOST}" >>"$TMP"
sudo cp "$TMP" /etc/hosts
rm -f "$TMP"
