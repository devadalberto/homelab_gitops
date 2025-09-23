#!/usr/bin/env bash
set -euo pipefail
CE_URL="${CE_URL:-https://atxfiles.netgate.com/mirror/downloads/pfSense-CE-memstick-serial-2.7.2-RELEASE-amd64.img.gz}"
WAN_BRIDGE="${WAN_BRIDGE:-br0}"
LAN_BRIDGE="${LAN_BRIDGE:-pfsense-lan}"
QCOW="${QCOW:-/var/lib/libvirt/images/pfsense-uranus.qcow2}"
CE_IMG="/var/lib/libvirt/images/pfsense-ce-installer.img"
RAM_MB="${RAM_MB:-4096}"

sudo mkdir -p /etc/qemu
printf 'allow %s\nallow %s\n' "$WAN_BRIDGE" "$LAN_BRIDGE" | sudo tee /etc/qemu/bridge.conf >/dev/null
sudo chmod 644 /etc/qemu/bridge.conf
HELPER="$(command -v qemu-bridge-helper || echo /usr/lib/qemu/qemu-bridge-helper)"
sudo chown root:root "$HELPER" 2>/dev/null || true
sudo chmod 4755 "$HELPER" 2>/dev/null || true

mkdir -p "$HOME/downloads"
GZ="$HOME/downloads/$(basename "$CE_URL")"
[ -f "$GZ" ] || wget -O "$GZ" "$CE_URL"

sudo bash -c "gunzip -c '$GZ' > '$CE_IMG'"
sudo chmod 0444 "$CE_IMG"

sudo virsh destroy pfsense-uranus 2>/dev/null || true
sudo virsh undefine pfsense-uranus 2>/dev/null || true
sudo fuser -vk "$QCOW" 2>/dev/null || true
[ -f "$QCOW" ] || sudo qemu-img create -f qcow2 "$QCOW" 20G

echo "Install CE: WAN=vtnet0 DHCP, LAN=vtnet1 10.10.0.1/24 (DHCP 10.10.0.100–200), ZFS+GPT."
sudo qemu-system-x86_64 \
  -enable-kvm -cpu host -m "$RAM_MB" -nographic -serial mon:stdio -no-reboot \
  -drive file="$CE_IMG",if=virtio,readonly=on \
  -drive file="$QCOW",if=virtio \
  -nic bridge,model=virtio,br="$WAN_BRIDGE" \
  -nic bridge,model=virtio,br="$LAN_BRIDGE"

echo "Booting from installed disk…"
exec sudo qemu-system-x86_64 \
  -enable-kvm -cpu host -m "$RAM_MB" -nographic -serial mon:stdio \
  -drive file="$QCOW",if=virtio \
  -nic bridge,model=virtio,br="$WAN_BRIDGE" \
  -nic bridge,model=virtio,br="$LAN_BRIDGE"
