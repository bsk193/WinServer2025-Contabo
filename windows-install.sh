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

echo "[11/11] Injecting VirtIO SCSI driver into boot.wim and install.wim..."
mkdir -p /mnt/wim /mnt/wim2

# --- boot.wim: image 2 only (setup environment) ---
# Adding to image 1 (bare WinPE) caused a BSOD during WinPE kernel init.
# Image 2 is what GRUB actually boots for the installer.
#
# Autounattend.xml (wcm: namespace required or setup ignores the file):
#   windowsPE pass  — auto-loads vioscsi from X: so no manual "Load Driver"
#   offlineServicing pass — DISM injects vioscsi into the offline OS image
#                          so Phase 2 can find the disk without prompting
cat > /tmp/Autounattend.xml << 'AEOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-PnpCustomizationsWinPE"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
            <DriverPaths>
                <PathAndCredentials wcm:action="add" wcm:keyValue="1">
                    <Path>X:\drivers\vioscsi</Path>
                </PathAndCredentials>
            </DriverPaths>
        </component>
    </settings>
    <settings pass="offlineServicing">
        <component name="Microsoft-Windows-PnpCustomizationsNonWinPE"
                   processorArchitecture="amd64"
                   publicKeyToken="31bf3856ad364e35"
                   language="neutral"
                   versionScope="nonSxS">
            <DriverPaths>
                <PathAndCredentials wcm:action="add" wcm:keyValue="1">
                    <Path>X:\drivers\vioscsi</Path>
                </PathAndCredentials>
            </DriverPaths>
        </component>
    </settings>
</unattend>
AEOF

wimlib-imagex mountrw /mnt/install/sources/boot.wim 2 /mnt/wim
mkdir -p /mnt/wim/drivers/vioscsi
cp -r /mnt/install/virtio/vioscsi/2k25/amd64/* /mnt/wim/drivers/vioscsi/
cp /tmp/Autounattend.xml /mnt/wim/Autounattend.xml
wimlib-imagex unmount --commit /mnt/wim

# --- install.wim: all images ---
# Register vioscsi as a boot-start service in each image's SYSTEM registry
# hive. This is the guaranteed fix for Phase 2: when the partially-installed
# Windows reboots for the first time it loads vioscsi and can see the disk
# without asking the user for drivers again.
apt-get install -y hivex

cat > /tmp/vioscsi.reg << 'EOF'
Windows Registry Editor Version 5.00

[ControlSet001\Services\vioscsi]
"Type"=dword:00000001
"Start"=dword:00000000
"ErrorControl"=dword:00000001
"ImagePath"="\SystemRoot\system32\drivers\vioscsi.sys"
"DisplayName"="VirtIO SCSI pass-through controller"
"Group"="SCSI Miniport"
EOF

IMAGE_COUNT=$(wimlib-imagex info /mnt/install/sources/install.wim | grep -i "image count" | awk '{print $NF}')
echo "Patching install.wim ($IMAGE_COUNT images)..."

for i in $(seq 1 $IMAGE_COUNT); do
    echo "  Image $i of $IMAGE_COUNT..."
    wimlib-imagex mountrw /mnt/install/sources/install.wim $i /mnt/wim2
    cp /mnt/install/virtio/vioscsi/2k25/amd64/vioscsi.sys \
        /mnt/wim2/Windows/System32/drivers/
    hivexregedit --merge /mnt/wim2/Windows/System32/config/SYSTEM \
        /tmp/vioscsi.reg
    wimlib-imagex unmount --commit /mnt/wim2
done

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
