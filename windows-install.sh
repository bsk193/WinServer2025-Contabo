#!/bin/bash
set -e

echo "[1/10] Updating package list..."
apt update -y

echo "[2/10] Installing required packages..."
# Stub out update-initramfs to prevent "no space left" on the live rescue tmpfs.
# The live medium at /run/live/medium has no room for a new initrd, but we don't
# need one — we're booting into Windows, not back into this rescue system.
dpkg-divert --local --rename --add /usr/sbin/update-initramfs
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs
chmod +x /usr/sbin/update-initramfs

apt install -y grub-pc-bin grub2-common parted gdisk wimtools ntfs-3g rsync wget curl

rm -f /usr/sbin/update-initramfs
dpkg-divert --local --rename --remove /usr/sbin/update-initramfs

echo "[3/10] Detecting disk..."
DISK=$(lsblk -dpno NAME | grep -E "/dev/sd|/dev/vd|/dev/nvme" | head -n1)
echo "Using disk: $DISK"

if [ -z "$DISK" ]; then
  echo "❌ No disk found. Exiting."
  exit 1
fi

# Handle NVMe naming
if [[ $DISK == *"nvme"* ]]; then
  PART1=${DISK}p1
  PART2=${DISK}p2
else
  PART1=${DISK}1
  PART2=${DISK}2
fi

echo "[4/10] Getting disk size..."
disk_size_mb=$(lsblk -b -dn -o SIZE $DISK)
disk_size_mb=$((disk_size_mb / 1024 / 1024))

part_size_mb=$((disk_size_mb / 2))

echo "[5/10] Wiping disk..."
wipefs -a $DISK
sgdisk --zap-all $DISK

echo "[6/10] Creating partitions..."
parted -s $DISK mklabel msdos
parted -s $DISK mkpart primary ntfs 1MiB ${part_size_mb}MiB
parted -s $DISK mkpart primary ntfs ${part_size_mb}MiB 100%

partprobe $DISK
sleep 5

echo "[7/10] Formatting partitions..."
mkfs.ntfs -f $PART1
mkfs.ntfs -f $PART2

echo "[8/10] Mounting partitions..."
mkdir -p /mnt/win
mkdir -p /mnt/install

mount $PART1 /mnt/win
mount $PART2 /mnt/install

echo "[9/10] Installing GRUB..."
grub-install --boot-directory=/mnt/win/boot $DISK

cat <<EOF > /mnt/win/boot/grub/grub.cfg
set timeout=5
set default=0

menuentry "Windows Installer" {
    insmod ntfs
    search --no-floppy --set=root --file /bootmgr
    chainloader /bootmgr
}
EOF

echo "[10/10] Downloading Windows ISO..."
cd /root

wget -O windows.iso https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso

echo "Mounting ISO..."
mkdir -p /mnt/iso
mount -o loop windows.iso /mnt/iso

echo "Copying Windows files..."
rsync -avh --progress /mnt/iso/ /mnt/win/

umount /mnt/iso

echo "Downloading VirtIO drivers..."
wget -O virtio.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso

mkdir -p /mnt/virtio
mount -o loop virtio.iso /mnt/virtio

mkdir -p /mnt/win/virtio
rsync -avh /mnt/virtio/ /mnt/win/virtio/

umount /mnt/virtio

sync

echo "======================================"
echo "✅ DONE. Rebooting into Windows setup..."
echo "======================================"

reboot
