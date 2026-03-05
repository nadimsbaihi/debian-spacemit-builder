#!/bin/bash
set -e

# ─── Configuration ────────────────────────────────────────────────────────────
ROOTFS=/build/debian-riscv64
EFI_IMG=/output/efi.img
ROOTFS_IMG=/output/rootfs.ext4
MINBASE_TAR=/output/minbase.tar.gz
IMAGE_SIZE_MB=${IMAGE_SIZE_MB:-8192}   # rootfs size
EFI_SIZE_MB=${EFI_SIZE_MB:-512}        # EFI partition size
MIRROR=${MIRROR:-http://deb.debian.org/debian-ports}
HOSTNAME=${HOSTNAME:-riscv-debian}
ROOT_PASSWORD=${ROOT_PASSWORD:-root}
USER_NAME=${USER_NAME:-user}
USER_PASSWORD=${USER_PASSWORD:-user}
INSTALL_XFCE=${INSTALL_XFCE:-false}
TIMEZONE=${TIMEZONE:-UTC}
CURRENT_DATETIME=$(date +%Y%m%d%H%M)

# UUIDs - generated once so fstab and filesystem match
UUID_ROOTFS=$(uuidgen)
UUID_EFI=$(uuidgen)

# ─── Helpers ──────────────────────────────────────────────────────────────────
inf() { echo -e "\033[;34m[INFO] $*\033[0m"; }
err() { echo -e "\033[;31m[ERROR] $*\033[0m" >&2; exit 1; }

[ "$EUID" -ne 0 ] && err "Please run as root (sudo)"

echo "============================================"
echo " Debian Trixie RISC-V Image Builder"
echo " Build:      $CURRENT_DATETIME"
echo " Rootfs:     ${IMAGE_SIZE_MB}MB"
echo " EFI:        ${EFI_SIZE_MB}MB"
echo " XFCE:       $INSTALL_XFCE"
echo " UUID rootfs: $UUID_ROOTFS"
echo " UUID EFI:    $UUID_EFI"
echo "============================================"
echo ""

# ─── Mount/Umount helpers ─────────────────────────────────────────────────────
mount_fs() {
    inf "Mounting pseudo filesystems into $1"
    mount | grep "$1/proc"    >/dev/null || mount -t proc  /proc    $1/proc
    mount | grep "$1/sys"     >/dev/null || mount -t sysfs /sys     $1/sys
    mount | grep "$1/dev/pts" >/dev/null || mount -o bind  /dev/pts $1/dev/pts
    mount | grep "$1/dev"     >/dev/null || mount -o bind  /dev     $1/dev
}

umount_fs() {
    inf "Unmounting pseudo filesystems from $1"
    mount | grep "$1/dev/pts" >/dev/null 2>&1 && umount -l $1/dev/pts || true
    mount | grep "$1/dev"     >/dev/null 2>&1 && umount -l $1/dev     || true
    mount | grep "$1/proc"    >/dev/null 2>&1 && umount -l $1/proc    || true
    mount | grep "$1/sys"     >/dev/null 2>&1 && umount -l $1/sys     || true
}

# ─── Step 1: Enable binfmt for RISC-V ────────────────────────────────────────
inf "[1/8] Registering QEMU binfmt..."
update-binfmts --enable qemu-riscv64 2>/dev/null || true

# ─── Step 2: Debootstrap (with minbase cache) ────────────────────────────────
if [ -f "$MINBASE_TAR" ]; then
    inf "[2/8] Found minbase cache, extracting..."
    rm -rf $ROOTFS
    mkdir -p $ROOTFS
    tar -xzf "$MINBASE_TAR" -C "$ROOTFS"
else
    inf "[2/8] Running debootstrap (minbase)..."
    rm -rf $ROOTFS
    debootstrap \
        --arch=riscv64 \
        --variant=minbase \
        --foreign \
        trixie \
        $ROOTFS \
        $MIRROR

    inf "[2/8] Copying QEMU static binary..."
    cp /usr/bin/qemu-riscv64-static $ROOTFS/usr/bin/

    inf "[2/8] Running debootstrap second stage..."
    chroot $ROOTFS /debootstrap/debootstrap --second-stage

    inf "[2/8] Caching minbase tarball for future runs..."
    umount_fs $ROOTFS
    tar -czf "$MINBASE_TAR" -C "$ROOTFS" .
fi

# ─── Step 3: Configure rootfs ─────────────────────────────────────────────────
inf "[3/8] Configuring rootfs..."
mount_fs $ROOTFS

# DNS for build time
cat > $ROOTFS/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Apt sources
cat > $ROOTFS/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian-ports trixie main
deb http://deb.debian.org/debian-ports unreleased main
EOF

# Hostname
echo "$HOSTNAME" > $ROOTFS/etc/hostname
cat > $ROOTFS/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# fstab — written now using pre-generated UUIDs
cat > $ROOTFS/etc/fstab <<EOF
UUID=$UUID_ROOTFS  /         ext4  defaults,noatime,errors=remount-ro  0  1
UUID=$UUID_EFI     /boot/efi vfat  defaults                            0  2
EOF

mkdir -p $ROOTFS/boot/efi

# Install debian-ports keyring first (unauthenticated)
chroot $ROOTFS /bin/bash -c "
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::AllowInsecureRepositories=true || true
apt-get install -y --allow-unauthenticated debian-ports-archive-keyring || true
apt-get update
"

export INSTALL_XFCE HOSTNAME ROOT_PASSWORD USER_NAME USER_PASSWORD TIMEZONE

chroot $ROOTFS /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

# Upgrade base system first
apt-get -y --allow-downgrades upgrade

# Essential system packages
apt-get install -y \
    systemd \
    systemd-sysv \
    sudo \
    vim \
    iproute2 \
    dbus \
    fdisk \
    e2fsprogs \
    ca-certificates \
    wget \
    curl \
    kmod \
    network-manager \
    initramfs-tools \
    grub-efi-riscv64 \
    grub-efi-riscv64-bin \
    openssh-server \
    locales \
    tzdata \
    keyboard-configuration \
    console-setup \
    ntp

# ─── XFCE desktop ─────────────────────────────────────────────────────────────
if [ "${INSTALL_XFCE}" = "true" ]; then
    echo "Installing XFCE desktop..."

    # Keyboard config before desktop install
    echo "keyboard-configuration  keyboard-configuration/xkb-model select pc105"  | debconf-set-selections
    echo "keyboard-configuration  keyboard-configuration/layoutcode string us"     | debconf-set-selections
    echo "keyboard-configuration  keyboard-configuration/variantcode string"       | debconf-set-selections
    echo "keyboard-configuration  keyboard-configuration/optionscode string"       | debconf-set-selections

    # task-xfce-desktop is the correct metapackage - handles all deps properly
    apt-get install -y task-xfce-desktop

    # Mesa for software rendering (no proprietary GPU drivers)
    apt-get install -y \
        libgl1-mesa-dri \
        libegl1-mesa \
        libgles2-mesa \
        mesa-common-dev \
        mesa-vulkan-drivers \
        libgbm1

    # Plymouth boot splash
    apt-get install -y plymouth plymouth-themes
    plymouth-set-default-theme spinner
    update-initramfs -u

    systemctl enable lightdm 2>/dev/null || true
    systemctl set-default graphical.target
fi

# ─── Locale ───────────────────────────────────────────────────────────────────
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8"         | debconf-set-selections
sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
dpkg-reconfigure --frontend=noninteractive locales

# ─── Timezone ─────────────────────────────────────────────────────────────────
TZ_AREA=\$(echo "${TIMEZONE}" | cut -d/ -f1)
TZ_ZONE=\$(echo "${TIMEZONE}" | cut -d/ -f2)
echo "tzdata tzdata/Areas select \$TZ_AREA"           | debconf-set-selections
echo "tzdata tzdata/Zones/\$TZ_AREA select \$TZ_ZONE" | debconf-set-selections
rm -f /etc/timezone /etc/localtime
dpkg-reconfigure --frontend=noninteractive tzdata

# ─── NTP ──────────────────────────────────────────────────────────────────────
sed -i 's/^#NTP=.*/NTP=pool.ntp.org/' /etc/systemd/timesyncd.conf

# ─── Persistent PATH ──────────────────────────────────────────────────────────
echo 'PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' > /etc/environment

# ─── Passwords ────────────────────────────────────────────────────────────────
echo "root:${ROOT_PASSWORD}" | chpasswd

# ─── Regular user ─────────────────────────────────────────────────────────────
useradd -m -s /bin/bash ${USER_NAME}
echo "${USER_NAME}:${USER_PASSWORD}" | chpasswd
usermod -aG sudo ${USER_NAME}

# ─── Services ─────────────────────────────────────────────────────────────────
systemctl enable NetworkManager             2>/dev/null || true
systemctl enable ssh                        2>/dev/null || true
systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
systemctl enable systemd-timesyncd          2>/dev/null || true

# ─── DNS restore for runtime ──────────────────────────────────────────────────
echo "nameserver 127.0.0.53" > /etc/resolv.conf

# ─── Cleanup apt cache ────────────────────────────────────────────────────────
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

# ─── Step 4: Install kernel debs if provided ──────────────────────────────────
inf "[4/8] Installing kernel..."
if ls /input/*.deb 1>/dev/null 2>&1; then
    inf "Found .deb files in /input, installing..."
    cp /input/*.deb $ROOTFS/tmp/
    chroot $ROOTFS /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
dpkg -i /tmp/linux-image-*.deb   2>/dev/null || true
dpkg -i /tmp/linux-headers-*.deb 2>/dev/null || true
# Index kernel modules
KVER=\$(ls /lib/modules/ | grep -v placeholder | head -1)
if [ -n "\$KVER" ]; then
    echo "Running depmod for kernel \$KVER..."
    depmod -a \$KVER
fi
rm -f /tmp/*.deb
CHROOT
else
    inf "No .deb files found in /input, skipping kernel install."
    inf "Place kernel .deb files in the 'input' directory to install them."
fi

# ─── Step 5: Install firmware if provided ─────────────────────────────────────
inf "[5/8] Installing firmware..."
if [ -f /input/rtthread-n308.elf ]; then
    inf "Found rtthread-n308.elf, installing as esos.elf..."
    mkdir -p $ROOTFS/lib/firmware
    cp /input/rtthread-n308.elf $ROOTFS/lib/firmware/esos.elf
fi

# Update initramfs after kernel + firmware install
chroot $ROOTFS /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
update-initramfs -u -k all 2>/dev/null || true
CHROOT

# ─── Step 6: Unmount pseudo-filesystems ───────────────────────────────────────
inf "[6/8] Unmounting pseudo-filesystems..."
umount_fs $ROOTFS

# ─── Step 7: Create EFI image ─────────────────────────────────────────────────
inf "[7/8] Creating EFI image (${EFI_SIZE_MB}MB)..."
mkdir -p /output

dd if=/dev/zero of=$EFI_IMG bs=1M count=$EFI_SIZE_MB status=progress
mkfs.fat -F32 -i "$(echo $UUID_EFI | tr -d '-' | head -c 8)" $EFI_IMG

# Mount EFI image via loop to run grub-install
LOOP_EFI=$(losetup -f)
losetup $LOOP_EFI $EFI_IMG
mkdir -p /mnt/efi
mount $LOOP_EFI /mnt/efi
mkdir -p $ROOTFS/boot/efi
mount --bind /mnt/efi $ROOTFS/boot/efi

mount_fs $ROOTFS

chroot $ROOTFS /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
grub-install \
    --target=riscv64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=debian \
    --recheck \
    --no-nvram

update-grub

# Fallback EFI binary for EDK2 auto-discovery
mkdir -p /boot/efi/EFI/BOOT
cp /boot/efi/EFI/debian/grubriscv64.efi /boot/efi/EFI/BOOT/BOOTRISCV64.EFI
CHROOT

umount_fs $ROOTFS
umount $ROOTFS/boot/efi
umount /mnt/efi
losetup -d $LOOP_EFI

# ─── Step 8: Create rootfs ext4 image ─────────────────────────────────────────
inf "[8/8] Creating rootfs.ext4 (${IMAGE_SIZE_MB}MB)..."

# mke2fs -d populates the filesystem directly from the directory —
# no loop device, no mount, no rsync needed.
# -N 524288: explicit inode count to prevent inode exhaustion before disk space
# -U: pre-set UUID to match fstab written earlier
mke2fs \
    -d $ROOTFS \
    -L rootfs \
    -t ext4 \
    -N 524288 \
    -U $UUID_ROOTFS \
    $ROOTFS_IMG \
    ${IMAGE_SIZE_MB}M

e2fsck -f -y $ROOTFS_IMG

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Build complete!"
echo " EFI image:  $EFI_IMG  ($(du -sh $EFI_IMG | cut -f1))"
echo " Rootfs:     $ROOTFS_IMG  ($(du -sh $ROOTFS_IMG | cut -f1))"
echo " DateTime:   $CURRENT_DATETIME"
echo "============================================"
