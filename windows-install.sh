#!/bin/bash
set -e

echo "[1/12] Updating system..."
apt update -y && apt upgrade -y

echo "[2/12] Installing dependencies..."
apt install -y grub-pc-bin grub2-common parted gdisk wimtools ntfs-3g rsync wget curl

echo "[3/12] Detecting main disk..."
DISK=$(lsblk -dpno NAME | grep -E "/dev/sd|/dev/vd|/dev/nvme" | head -n1)
echo "Detected disk: $DISK"

if [ -z "$DISK" ]; then
  echo "No disk found. Exiting."
  exit 1
fi

echo "[4/12] Getting disk size..."
disk_size_mb=$(lsblk -b -dn -o SIZE $DISK)
disk_size_mb=$((disk_size_mb / 1024 / 1024))

part_size_mb=$((disk_size_mb / 2))

echo "[5/12] Wiping disk..."
wipefs -a $DISK
sgdisk --zap-all $DISK

echo "[6/12] Creating partitions..."
parted -s $DISK mklabel msdos
parted -s $DISK mkpart primary ntfs 1MiB ${part_size_mb}MiB
parted -s $DISK mkpart primary ntfs ${part_size_mb}MiB 100%

partprobe $DISK
sleep 5

PART1=${DISK}1
PART2=${DISK}2

# Fix NVMe naming
if [[ $DISK == *"nvme"* ]]; then
  PART1=${DISK}p1
  PART2=${DISK}p2
fi

echo "[7/12] Formatting partitions..."
mkfs.ntfs -f $PART1
mkfs.ntfs -f $PART2

echo "[8/12] Mounting partitions..."
mkdir -p /mnt/win
mkdir -p /mnt/install

mount $PART1 /mnt/win
mount $PART2 /mnt/install

echo "[9/12] Installing GRUB..."
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

echo "[10/12] Downloading Windows ISO..."
cd /root

wget -O windows.iso https://software-static.download.prss.microsoft.com/dbazure/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso

echo "[11/12] Extracting Windows files..."
mkdir -p /mnt/iso
mount -o loop windows.iso /mnt/iso

rsync -avh --progress /mnt/iso/ /mnt/win/

umount /mnt/iso

echo "[12/12] Downloading VirtIO drivers..."
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
