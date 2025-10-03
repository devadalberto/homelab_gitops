#!/usr/bin/env bash
set -euo pipefail

# === Paths (adjust only if you really need to) ===
SRC_IMG="$HOME/downloads/netgate-installer-amd64.img"    # your memstick-serial .img (already present)
SRC_CFG="/opt/homelab/pfsense/config/pfSense-config.iso" # created by pf-config-gen.sh (if present)
LIBVIRT_DIR="/var/lib/libvirt/images"
DST_IMG="$LIBVIRT_DIR/pfsense-installer-serial.img"
DST_CFG="$LIBVIRT_DIR/pfSense-config.iso"
QCOW="$LIBVIRT_DIR/pfsense-uranus.qcow2"
VM="pfsense-uranus"

# === Sanity checks on source files ===
[ -f "$SRC_IMG" ] || {
  echo "[FATAL] Not found: $SRC_IMG"
  exit 1
}
# This is just a hint; if you know it's serial, ignore the warning
if file "$SRC_IMG" | grep -qi 'ISO 9660'; then
  echo "[WARN] $SRC_IMG looks like an ISO (VGA). You usually want a memstick-serial .img."
fi

# === Put images where libvirt-qemu can read them (no home perms needed) ===
sudo mkdir -p "$LIBVIRT_DIR"
sudo install -o libvirt-qemu -g kvm -m 0444 "$SRC_IMG" "$DST_IMG"
if [ -f "$SRC_CFG" ]; then
  sudo install -o libvirt-qemu -g kvm -m 0444 "$SRC_CFG" "$DST_CFG"
else
  echo "[WARN] $SRC_CFG not found; pfSense will still install, but config import will wait until you attach it later."
  DST_CFG="" # skip attaching if missing
fi

# === Prepare VM disk ===
if [ ! -f "$QCOW" ]; then
  sudo qemu-img create -f qcow2 "$QCOW" 20G
fi

# === Clean any old domain (do NOT remove storage now that we staged files) ===
sudo virsh destroy "$VM" 2>/dev/null || true
sudo virsh undefine "$VM" 2>/dev/null || true

# === Define serial-only VM with correct boot order ===
sudo virt-install \
  --name "$VM" \
  --memory 4096 \
  --vcpus 2 \
  --cpu host \
  --osinfo freebsd14.0 \
  --graphics none \
  --console pty,target_type=serial \
  --boot menu=on,useserial=on \
  --network bridge=pfsense-wan,model=virtio \
  --network bridge=pfsense-lan,model=virtio \
  --disk path="$DST_IMG",device=disk,bus=virtio,readonly=on,boot_order=1 \
  --disk path="$QCOW",format=qcow2,bus=virtio,boot_order=2 \
  $([ -n "${DST_CFG:-}" ] && [ -f "$DST_CFG" ] && echo "--disk path=$DST_CFG,device=cdrom,target.bus=sata,boot_order=3") \
  --noautoconsole --import

# === Start and attach to serial console ===
sudo virsh start "$VM"
echo "[INFO] Attaching to serial console. Exit with Ctrl+]."
exec sudo virsh console "$VM"
