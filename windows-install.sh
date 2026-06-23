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
  echo "No disk found. Exiting."
  exit 1
fi

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

# PART1 = large Windows target (most of disk)
# PART2 = small installer bootstrap at the END of disk (15GB)
# Layout: [----PART1 ~285GB----][--PART2 15GB--]
# After Windows installs to PART1, delete PART2 in Disk Management
# then right-click C: -> Extend Volume to reclaim the full 300GB.
installer_mb=15360
win_mb=$((disk_size_mb - installer_mb))

echo "[5/11] Wiping disk..."
wipefs -a $DISK
sgdisk --zap-all $DISK

echo "[6/11] Creating partitions..."
parted -s $DISK mklabel msdos
parted -s $DISK mkpart primary ntfs 1MiB ${win_mb}MiB
parted -s $DISK mkpart primary ntfs ${win_mb}MiB 100%

parted -s $DISK set 1 boot on

partprobe $DISK
sleep 5

echo "[7/11] Formatting partitions..."
mkfs.ntfs -f $PART1
mkfs.ntfs -f $PART2

echo "[8/11] Mounting partitions..."
mkdir -p /mnt/win /mnt/install

mount $PART1 /mnt/win
mount $PART2 /mnt/install

echo "[9/11] Installing GRUB..."
# GRUB MBR written to disk; modules stored on PART2 (installer bootstrap).
# PART1 stays empty so Windows installs cleanly to it.
grub-install --boot-directory=/mnt/install/boot $DISK

cat <<EOF > /mnt/install/boot/grub/grub.cfg
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
# Download ISO to PART1 (/mnt/win, ~285GB free) to avoid RAM limits,
# rsync installer files to PART2 (/mnt/install), then delete the ISO.
wget -O /mnt/win/windows.iso https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.32230.260111-0550.lt_release_svc_refresh_SERVER_EVAL_x64FRE_en-us.iso

echo "Mounting ISO..."
mkdir -p /mnt/iso
mount -o loop /mnt/win/windows.iso /mnt/iso

echo "Copying Windows installer files to installer partition..."
rsync -avh --progress /mnt/iso/ /mnt/install/

umount /mnt/iso
rm -f /mnt/win/windows.iso

echo "Downloading VirtIO drivers..."
wget -O /mnt/win/virtio.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso

mkdir -p /mnt/virtio
mount -o loop /mnt/win/virtio.iso /mnt/virtio

mkdir -p /mnt/install/virtio
rsync -avh /mnt/virtio/ /mnt/install/virtio/

umount /mnt/virtio
rm -f /mnt/win/virtio.iso

echo "[11/11] Injecting VirtIO SCSI driver into boot.wim..."
mkdir -p /mnt/wim

# --- boot.wim: image 2 only ---
# Autounattend.xml DriverPaths did not load vioscsi before setup enumerated
# disks, so the "Load driver" prompt still appeared. New approach:
#
# Override winpeshl.ini so winpeshl.exe runs a wrapper batch instead of
# setup.exe directly. The wrapper:
#   1. Calls drvload to load vioscsi BEFORE setup.exe starts
#   2. Runs setup.exe (Phase 1 — expands image, no driver prompt)
#   3. After setup.exe exits, cancels any pending reboot
#   4. Runs DISM to inject vioscsi into the installed Windows on C:
#      (DISM handles both driver store + registry service entry)
#   5. Reboots into Phase 2 — vioscsi already registered, no prompt

wimlib-imagex mountrw /mnt/install/sources/boot.wim 2 /mnt/wim
mkdir -p /mnt/wim/drivers/vioscsi
cp -r /mnt/install/virtio/vioscsi/2k25/amd64/* /mnt/wim/drivers/vioscsi/

# Batch wrapper — single-quoted heredoc keeps %% and \r\n safe from bash
cat > /tmp/setup_wrapper.bat << 'BATEOF'
@echo off
drvload X:\drivers\vioscsi\vioscsi.inf
X:\sources\setup.exe
shutdown /a 2>nul
set WINDRV=C
for %%d in (C D E F G) do (
    if exist %%d:\Windows\System32\winload.exe (
        if not "%%d"=="X" if not defined WINDRV set WINDRV=%%d
    )
)
dism /Image:%WINDRV%:\ /Add-Driver /Driver:X:\drivers\vioscsi\vioscsi.inf /ForceUnsigned
wpeutil reboot
BATEOF
sed -i 's/$/\r/' /tmp/setup_wrapper.bat
cp /tmp/setup_wrapper.bat /mnt/wim/setup_wrapper.bat

# winpeshl.ini — tell WinPE to launch cmd.exe running our wrapper
printf '[LaunchApps]\r\n%%SYSTEMROOT%%\\system32\\cmd.exe /c X:\\setup_wrapper.bat\r\n' \
    > /mnt/wim/Windows/System32/winpeshl.ini

wimlib-imagex unmount --commit /mnt/wim

sync

echo "=============================================="
echo "DONE. Rebooting into Windows setup..."
echo ""
echo "  The vioscsi driver loads automatically - no manual"
echo "  'Load Driver' step needed."
echo ""
echo "  At the disk selection screen:"
echo "  -> Select Drive 0 Partition 1 (~285GB) and click Next"
echo "  -> Do NOT delete or touch Partition 2 (15GB at end)"
echo ""
echo "  After Windows is installed and running:"
echo "  -> Open Disk Management"
echo "  -> Delete Partition 2 (~15GB at end of disk)"
echo "  -> Right-click C: -> Extend Volume -> full 300GB"
echo "=============================================="

reboot
