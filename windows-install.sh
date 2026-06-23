#!/bin/bash
set -e

echo "[1/11] Updating package list..."
apt update -y

echo "[2/11] Installing required packages..."
# live-tools already has a diversion on update-initramfs, so dpkg-divert would
# clash. Swap the live wrapper with a no-op stub so package post-install hooks
# can't trigger an initrd rebuild into the live medium tmpfs (no space there).
mv /usr/sbin/update-initramfs /usr/sbin/update-initramfs.live-backup
printf '#!/bin/sh\nexit 0\n' > /usr/sbin/update-initramfs
chmod +x /usr/sbin/update-initramfs

apt install -y grub-pc-bin grub2-common parted gdisk wimtools ntfs-3g rsync wget curl

mv /usr/sbin/update-initramfs.live-backup /usr/sbin/update-initramfs

echo "[3/11] Detecting disk..."
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

echo "[4/11] Getting disk size..."
disk_size_mb=$(lsblk -b -dn -o SIZE $DISK)
disk_size_mb=$((disk_size_mb / 1024 / 1024))

part_size_mb=$((disk_size_mb / 2))

echo "[5/11] Wiping disk..."
wipefs -a $DISK
sgdisk --zap-all $DISK

echo "[6/11] Creating partitions..."
parted -s $DISK mklabel msdos
parted -s $DISK mkpart primary ntfs 1MiB ${part_size_mb}MiB
parted -s $DISK mkpart primary ntfs ${part_size_mb}MiB 100%

partprobe $DISK
sleep 5

echo "[7/11] Formatting partitions..."
mkfs.ntfs -f $PART1
mkfs.ntfs -f $PART2

echo "[8/11] Mounting partitions..."
mkdir -p /mnt/win
mkdir -p /mnt/install

mount $PART1 /mnt/win
mount $PART2 /mnt/install

echo "[9/11] Installing GRUB..."
grub-install --boot-directory=/mnt/win/boot $DISK

cat <<EOF > /mnt/win/boot/grub/grub.cfg
set timeout=5
set default=0

menuentry "Windows Installer" {
    insmod part_msdos
    insmod ntfs
    insmod ntldr
    search --no-floppy --set=root --file /bootmgr
    ntldr /bootmgr
}
EOF

echo "[10/11] Downloading Windows ISO and VirtIO drivers..."
# Download to the actual disk (/mnt/install) — /root is a tmpfs in RAM
# and cannot hold a ~6 GB ISO.
wget -O /mnt/install/windows.iso https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso

echo "Mounting ISO..."
mkdir -p /mnt/iso
mount -o loop /mnt/install/windows.iso /mnt/iso

echo "Copying Windows files..."
rsync -avh --progress /mnt/iso/ /mnt/win/

umount /mnt/iso
rm -f /mnt/install/windows.iso

echo "Downloading VirtIO drivers..."
wget -O /mnt/install/virtio.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso

mkdir -p /mnt/virtio
mount -o loop /mnt/install/virtio.iso /mnt/virtio

mkdir -p /mnt/win/virtio
rsync -avh /mnt/virtio/ /mnt/win/virtio/

umount /mnt/virtio
rm -f /mnt/install/virtio.iso

echo "[11/11] Injecting VirtIO SCSI driver into WinPE (boot.wim)..."
# Contabo VPS uses a VirtIO-SCSI controller (disk appears as sda in Linux).
# Without vioscsi injected into the WinPE image, Windows installer sees no
# disks at all. We mount image 2 (the setup environment) and add the driver
# so it is available on X: during installation.
mkdir -p /mnt/wim
wimlib-imagex mountrw /mnt/win/sources/boot.wim 2 /mnt/wim

mkdir -p /mnt/wim/drivers/vioscsi
cp -r /mnt/win/virtio/vioscsi/2k25/amd64/* /mnt/wim/drivers/vioscsi/

wimlib-imagex unmount --commit /mnt/wim

sync

echo "======================================"
echo "✅ DONE. Rebooting into Windows setup..."
echo "  When prompted, click Load Driver"
echo "  and browse to X:\\drivers\\vioscsi"
echo "======================================"

reboot
