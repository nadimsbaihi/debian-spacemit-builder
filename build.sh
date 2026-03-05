#!/bin/bash
set -e

# ─── Configuration ────────────────────────────────────────────────────────────
ROOTFS=/build/debian-riscv64
EFI_IMG=/output/efi.img
ROOTFS_IMG=/output/rootfs.ext4
MINBASE_TAR=/output/minbase.tar.gz
IMAGE_SIZE_MB=${IMAGE_SIZE_MB:-8192}   # rootfs size
EFI_SIZE_MB=${EFI_SIZE_MB:-512}        # EFI partition size
MIRROR=${MIRROR:-http://deb.debian.org/debian}
HOSTNAME=${HOSTNAME:-riscv-debian}
ROOT_PASSWORD=${ROOT_PASSWORD:-root}
USER_NAME=${USER_NAME:-user}
USER_PASSWORD=${USER_PASSWORD:-user}
INSTALL_XFCE=${INSTALL_XFCE:-true}
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
inf "[1/9] Registering QEMU binfmt..."
update-binfmts --enable qemu-riscv64 2>/dev/null || true

# ─── Step 2: Debootstrap (with minbase cache) ────────────────────────────────
if [ -f "$MINBASE_TAR" ]; then
    inf "[2/9] Found minbase cache, extracting..."
    rm -rf $ROOTFS
    mkdir -p $ROOTFS
    tar -xzf "$MINBASE_TAR" -C "$ROOTFS"
else
    inf "[2/9] Running debootstrap (minbase)..."
    rm -rf $ROOTFS
    debootstrap \
        --arch=riscv64 \
        --variant=minbase \
        --foreign \
        trixie \
        $ROOTFS \
        $MIRROR

    inf "[2/9] Copying QEMU static binary..."
    cp /usr/bin/qemu-riscv64-static $ROOTFS/usr/bin/

    inf "[2/9] Running debootstrap second stage..."
    chroot $ROOTFS /debootstrap/debootstrap --second-stage

    inf "[2/9] Caching minbase tarball for future runs..."
    umount_fs $ROOTFS
    tar -czf "$MINBASE_TAR" -C "$ROOTFS" .
fi

# ─── Step 3: Configure rootfs ─────────────────────────────────────────────────
inf "[3/9] Configuring rootfs..."
mount_fs $ROOTFS

# DNS for build time
cat > $ROOTFS/etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Apt sources
cat > $ROOTFS/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main
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

# Install debian keyring first (unauthenticated)
chroot $ROOTFS /bin/bash -c "
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::AllowInsecureRepositories=true || true
apt-get install -y --allow-unauthenticated debian-archive-keyring || true
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
    openssh-server \
    locales \
    tzdata \
    keyboard-configuration \
    console-setup

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
mkdir -p /etc/systemd/timesyncd.conf.d
cat > /etc/systemd/timesyncd.conf.d/ntp.conf <<NTPEOF
[Time]
NTP=pool.ntp.org
NTPEOF

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

# ─── Step 4: Install GRUB and kernel ──────────────────────────────────────────
inf "[4/9] Installing GRUB and kernel..."

# --- 4a: Install GRUB (from /input debs or from apt) ---
if ls /input/grub-*.deb 1>/dev/null 2>&1; then
    inf "Found GRUB .deb files in /input, installing..."
    cp /input/grub-*.deb "$ROOTFS/tmp/"
    chroot "$ROOTFS" /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
dpkg -i --force-depends /tmp/grub-*.deb || true
rm -f /tmp/grub-*.deb
CHROOT
else
    inf "No GRUB .deb files in /input, installing grub-efi-riscv64 from apt..."
    chroot "$ROOTFS" /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y grub2-common grub-efi-riscv64-bin
CHROOT
fi

# Verify GRUB riscv64-efi modules were installed (these are data files, not executables)
if [ ! -d "$ROOTFS/usr/lib/grub/riscv64-efi" ]; then
    err "GRUB riscv64-efi modules not found in chroot — GRUB installation may have failed"
fi

# Install grub-common on the host so we can run grub-mkimage natively
# (the chroot's grub-mkimage is a riscv64 binary that can't execute on the host)
if ! command -v grub-mkimage &>/dev/null; then
    inf "Installing grub-common on host for grub-mkimage..."
    apt-get update -qq
    apt-get install -y -qq grub-common
fi

# --- 4b: Install kernel debs if provided ---
if ls /input/linux-*.deb 1>/dev/null 2>&1; then
    inf "Found kernel .deb files in /input, installing..."
    cp /input/linux-*.deb $ROOTFS/tmp/
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
    inf "No kernel .deb files found in /input, skipping kernel install."
    inf "Place kernel .deb files in the 'input' directory to install them."
fi

# ─── Step 5: Install firmware if provided ─────────────────────────────────────
inf "[5/9] Installing firmware..."
if [ -f /input/rtthead-n308.elf ]; then
    inf "Found rtthead-n308.elf, installing as esos.elf..."
    mkdir -p $ROOTFS/lib/firmware
    cp /input/rtthead-n308.elf $ROOTFS/lib/firmware/esos.elf
fi

# Update initramfs after kernel + firmware install
chroot $ROOTFS /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
update-initramfs -u -k all 2>/dev/null || true
CHROOT

# ─── Step 6: Build GRUB EFI binary (on host) ─────────────────────────────────
inf "[6/9] Building GRUB EFI binary..."

# Detect installed kernel version
KVER=$(ls "$ROOTFS/lib/modules/" 2>/dev/null | grep -v placeholder | head -1)

# Verify GRUB modules directory exists
GRUB_MOD_DIR="$ROOTFS/usr/lib/grub/riscv64-efi"
if [ ! -d "$GRUB_MOD_DIR" ]; then
    err "GRUB modules directory not found at $GRUB_MOD_DIR — GRUB installation may have failed"
fi

mkdir -p "$ROOTFS/boot/efi/EFI/debian" "$ROOTFS/boot/efi/EFI/BOOT" "$ROOTFS/boot/grub"

# Embedded early config: searches for the real grub.cfg on the ext4 partition
cat > /tmp/grub-early.cfg <<'EARLYCFG'
search --file --set=root /boot/grub/grub.cfg
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EARLYCFG

# Build EFI binary on the HOST (grub-mkimage is a host-arch tool; the riscv64
# modules in the chroot are just data files it reads, no QEMU needed)
grub-mkimage \
    --directory="$ROOTFS/usr/lib/grub/riscv64-efi" \
    --config=/tmp/grub-early.cfg \
    --prefix=/boot/grub \
    --output="$ROOTFS/boot/efi/EFI/debian/grubriscv64.efi" \
    --format=riscv64-efi \
    normal search search_fs_uuid search_fs_file \
    ext2 fat part_gpt linux echo gzio

rm -f /tmp/grub-early.cfg

# Verify EFI binary was created
if [ ! -f "$ROOTFS/boot/efi/EFI/debian/grubriscv64.efi" ]; then
    err "GRUB EFI binary not found — grub-mkimage failed"
fi

# Fallback EFI binary for EDK2 auto-discovery
cp "$ROOTFS/boot/efi/EFI/debian/grubriscv64.efi" \
   "$ROOTFS/boot/efi/EFI/BOOT/BOOTRISCV64.EFI"

# Install GRUB modules onto rootfs so update-grub works at runtime
if [ -d "$GRUB_MOD_DIR" ]; then
    cp -r "$GRUB_MOD_DIR" "$ROOTFS/boot/grub/riscv64-efi"
fi

# Write grub.cfg
cat > "$ROOTFS/boot/grub/grub.cfg" <<GRUBCFG
set default=0
set timeout=5

menuentry "Debian Trixie (RISC-V)" {
    linux /boot/vmlinuz-$KVER root=UUID=$UUID_ROOTFS console=ttyS0,115200 
    initrd /boot/initrd.img-$KVER
}
GRUBCFG

# ─── Step 7: Unmount pseudo-filesystems ───────────────────────────────────────
inf "[7/9] Unmounting pseudo-filesystems..."
umount_fs "$ROOTFS"
sync
sleep 1

# ─── Step 8: Create partition images ─────────────────────────────────────────
inf "[8/9] Creating partition images..."

# --- EFI partition (FAT32, built with mtools — no loop device needed) ---
inf "Creating EFI partition image (${EFI_SIZE_MB}MiB)..."
truncate -s ${EFI_SIZE_MB}M /build/efi.img
mkfs.fat -F32 -n EFI /build/efi.img

# Copy EFI content into the FAT image using mtools
inf "Populating EFI partition..."
if [ -f "$ROOTFS/boot/efi/EFI/debian/grubriscv64.efi" ]; then
    mmd -i /build/efi.img ::/EFI
    mmd -i /build/efi.img ::/EFI/debian
    mmd -i /build/efi.img ::/EFI/BOOT
    mcopy -i /build/efi.img "$ROOTFS/boot/efi/EFI/debian/grubriscv64.efi" ::/EFI/debian/grubriscv64.efi
    mcopy -i /build/efi.img "$ROOTFS/boot/efi/EFI/BOOT/BOOTRISCV64.EFI"  ::/EFI/BOOT/BOOTRISCV64.EFI
    # Verify
    mdir -i /build/efi.img -s ::/
else
    err "GRUB EFI binary not found at $ROOTFS/boot/efi/EFI/debian/grubriscv64.efi — grub-mkimage may have failed"
fi

# Read back the FAT volume serial (used as UUID in fstab)
EFI_UUID=$(blkid -s UUID -o value /build/efi.img)
inf "EFI UUID: $EFI_UUID"

# Copy EFI image to output
cp /build/efi.img "$EFI_IMG"

# ─── Step 9: Create rootfs ext4 image ─────────────────────────────────────────
inf "[9/9] Creating rootfs.ext4 (${IMAGE_SIZE_MB}MB)..."

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
