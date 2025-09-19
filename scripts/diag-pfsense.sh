#!/usr/bin/env bash
set -Eeuo pipefail
VM="${1:-pfsense-uranus}"
echo "=== domiflist ==="; sudo virsh domiflist "$VM" || true
echo; echo "=== domblklist ==="; sudo virsh domblklist "$VM" || true
echo; echo "=== dumpxml (interfaces/disks/controllers) ==="
sudo virsh dumpxml "$VM" | sed -n 's/^[[:space:]]*//; /<interface\|<disk\|<controller/p' || true
echo; echo "=== bridges (host) ==="; ip -br a | grep -E 'virbr|br0' || true
echo; echo "=== probe 10.10.0.1 and 192.168.1.1 ==="
ping -c1 -W1 10.10.0.1 || true
curl -kIs --connect-timeout 5 https://10.10.0.1/ || true
ping -c1 -W1 192.168.1.1 || true
curl -kIs --connect-timeout 5 https://192.168.1.1/ || true
echo; echo "=== brief tcpdump on virbr-lan (arp/icmp) ==="
if ip link show virbr-lan >/dev/null 2>&1; then
  sudo timeout 8 tcpdump -nni virbr-lan "arp or icmp" || true
fi
