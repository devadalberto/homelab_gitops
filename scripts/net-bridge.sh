#!/usr/bin/env bash
set -euo pipefail
NIC="${1:?Usage: $0 <WAN_NIC>}"
STATE="/root/.uranus_bootstrap_state"
log(){ printf('[%s] %s\n' "$(date +'%F %T')" "$*"); }

HOST_IPV4=$(ip -4 -br addr show "${NIC}" | awk '{print $3}' | cut -d/ -f1 || true)
HOST_MASK=$(ip -4 -br addr show "${NIC}" | awk '{print $3}' | cut -d/ -f2 || true)
GATEWAY=$(ip route | awk '/default/ {print $3; exit}')

if [[ -z "${HOST_IPV4}" || -z "${HOST_MASK}" || -z "${GATEWAY}" ]]; then
  read -r -p "Enter host IPv4 for br0 (e.g., 192.168.88.12): " HOST_IPV4
  read -r -p "Enter CIDR mask (e.g., 24): " HOST_MASK
  read -r -p "Enter default gateway (e.g., 192.168.88.1): " GATEWAY
fi

cp -a /etc/netplan /etc/netplan.backup.$(date +%F_%H%M%S) || true
cat >/etc/netplan/60-uranus-br0.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}: {dhcp4: no}
  bridges:
    br0:
      interfaces: [${NIC}]
      addresses: [${HOST_IPV4}/${HOST_MASK}]
      gateway4: ${GATEWAY}
      nameservers:
        addresses: [1.1.1.1,9.9.9.9]
      parameters:
        stp: true
        forward-delay: 0
EOF

netplan generate
netplan apply || true
echo "post_br0_reboot" > "$STATE"
sleep 3
reboot
