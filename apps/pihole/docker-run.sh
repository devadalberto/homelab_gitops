#!/usr/bin/env bash
set -euo pipefail
docker rm -f pihole >/dev/null 2>&1 || true
docker run -d --name pihole --restart unless-stopped \
  -p 53:53/udp -p 53:53/tcp -p 8081:80/tcp -p 444:443/tcp \
  -e TZ="UTC" \
  -e FTLCONF_dns_listeningMode="all" \
  -e FTLCONF_misc_etc_dnsmasq_d="true" \
  -e FTLCONF_dns_upstreams="1.1.1.1;1.0.0.1" \
  -v /srv/pihole/etc-pihole:/etc/pihole \
  -v /srv/pihole/etc-dnsmasq.d:/etc/dnsmasq.d \
  --cap-add=NET_ADMIN \
  pihole/pihole:latest
