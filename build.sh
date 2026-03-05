#!/bin/bash
set -e

# ─── Configuration ────────────────────────────────────────────────────────────
ROOTFS=/build/debian-riscv64
OUTPUT=/output/debian-riscv64.img
MINBASE_TAR=/output/minbase.tar.gz
IMAGE_SIZE_MB=${IMAGE_SIZE_MB:-12288}
MIRROR=${MIRROR:-http://deb.debian.org/debian}
HOSTNAME=${HOSTNAME:-riscv-debian}
ROOT_PASSWORD=${ROOT_PASSWORD:-root}
USER_NAME=${USER_NAME:-user}
USER_PASSWORD=${USER_PASSWORD:-user}
INSTALL_XFCE=${INSTALL_XFCE:-false}
TIMEZONE=${TIMEZONE:-UTC}
CURRENT_DATETIME=$(date +%Y%m%d%H%M)

# Partition layout (MiB)
EFI_START_MB=1
EFI_END_MB=512
ROOTFS_START_MB=$EFI_END_MB
EFI_SIZE_MB=$((EFI_END_MB - EFI_START_MB))
# Reserve 1 MiB at end for backup GPT
EXT4_SIZE_MB=$((IMAGE_SIZE_MB - ROOTFS_START_MB - 1))

# ─── Helpers ──────────────────────────────────────────────────────────────────
inf() { echo -e "\033[;34m[INFO] $*\033[0m"; }
err() { echo -e "\033[;31m[ERROR] $*\033[0m" >&2; exit 1; }

[ "$EUID" -ne 0 ] && err "Please run as root (sudo)"

echo "============================================"
echo " Debian Trixie RISC-V Image Builder"
echo " Build: $CURRENT_DATETIME"
echo " Image size: ${IMAGE_SIZE_MB}MB"
echo " XFCE: $INSTALL_XFCE"
echo "============================================"
echo ""

# ─── Mount/Umount helpers ─────────────────────────────────────────────────────
mount_fs() {
    inf "Mounting pseudo filesystems into $1"
    mountpoint -q "$1/proc"    || mount -t proc  /proc    "$1/proc"
    mountpoint -q "$1/sys"     || mount -t sysfs /sys     "$1/sys"
    mountpoint -q "$1/dev"     || mount -o bind  /dev     "$1/dev"
    mountpoint -q "$1/dev/pts" || mount -o bind  /dev/pts "$1/dev/pts"
}

umount_fs() {
    inf "Unmounting pseudo filesystems from $1"
    mountpoint -q "$1/dev/pts" && umount -l "$1/dev/pts" || true
    mountpoint -q "$1/dev"     && umount -l "$1/dev"     || true
    mountpoint -q "$1/proc"    && umount -l "$1/proc"    || true
    mountpoint -q "$1/sys"     && umount -l "$1/sys"     || true
}

# ─── Step 1: Enable binfmt for RISC-V ────────────────────────────────────────
inf "[1/9] Registering QEMU binfmt..."
update-binfmts --enable qemu-riscv64 2>/dev/null || true

# ─── Step 2: Debootstrap (with minbase cache) ────────────────────────────────
if [ -f "$MINBASE_TAR" ]; then
    inf "[2/9] Found minbase cache, extracting..."
    rm -rf "$ROOTFS"
    mkdir -p "$ROOTFS"
    tar -xzf "$MINBASE_TAR" -C "$ROOTFS"
else
    inf "[2/9] Running debootstrap (minbase)..."
    rm -rf "$ROOTFS"
    debootstrap \
        --arch=riscv64 \
        --variant=minbase \
        --foreign \
        trixie \
        "$ROOTFS" \
        "$MIRROR"

    inf "[2/9] Copying QEMU static binary..."
    cp /usr/bin/qemu-riscv64-static "$ROOTFS/usr/bin/"

    inf "[2/9] Running debootstrap second stage..."
    chroot "$ROOTFS" /debootstrap/debootstrap --second-stage

    inf "[2/9] Caching minbase tarball for future runs..."
    umount_fs "$ROOTFS"
    tar -czf "$MINBASE_TAR" -C "$ROOTFS" .
fi

# ─── Step 3: Configure rootfs ─────────────────────────────────────────────────
inf "[3/9] Configuring rootfs..."
mount_fs "$ROOTFS"

# DNS for build time
cat > "$ROOTFS/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Apt sources — uses configured MIRROR
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR trixie main
deb $MIRROR trixie-updates main
deb http://deb.debian.org/debian-security trixie-security main
EOF

# Hostname
echo "$HOSTNAME" > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
fe00::0     ip6-localnet
ff00::0     ip6-mcastprefix
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

chroot "$ROOTFS" /bin/bash -c "
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
apt-get update
"

export INSTALL_XFCE HOSTNAME ROOT_PASSWORD USER_NAME USER_PASSWORD TIMEZONE

chroot "$ROOTFS" /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive

# Upgrade base system first
apt-get -y --allow-downgrades upgrade

# Essential system packages
apt-get install -y \
    systemd \
    systemd-sysv \
    systemd-timesyncd \
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
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
echo "${TIMEZONE}" > /etc/timezone
dpkg-reconfigure --frontend=noninteractive tzdata

# ─── NTP (systemd-timesyncd only) ────────────────────────────────────────────
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
apt-get install -y grub-efi-riscv64-bin
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
if ls /input/linux-image-*.deb 1>/dev/null 2>&1; then
    inf "Found kernel .deb files in /input, installing..."

    for deb in /input/linux-image-*.deb; do
        case "$deb" in *-dbg_*) inf "Skipping debug package: $(basename "$deb")"; continue;; esac
        cp "$deb" "$ROOTFS/tmp/"
    done
    cp /input/linux-headers-*.deb "$ROOTFS/tmp/" 2>/dev/null || true

    chroot "$ROOTFS" /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
dpkg -i --force-depends /tmp/linux-image-*.deb || true
dpkg -i --force-depends /tmp/linux-headers-*.deb 2>/dev/null || true
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
    inf "Place linux-image-*.deb files in the 'input' directory to install them."
fi

# ─── Step 5: Install firmware if provided ─────────────────────────────────────
inf "[5/9] Installing firmware..."
if [ -f /input/rtthread-n308.elf ]; then
    inf "Found rtthread-n308.elf, installing as esos.elf..."
    mkdir -p "$ROOTFS/lib/firmware"
    cp /input/rtthread-n308.elf "$ROOTFS/lib/firmware/esos.elf"

    # initramfs hook to force-include esos.elf (not auto-detected by module scanning)
    mkdir -p "$ROOTFS/etc/initramfs-tools/hooks"
    cat > "$ROOTFS/etc/initramfs-tools/hooks/esos-firmware" <<'HOOK'
#!/bin/sh
set -e
. /usr/share/initramfs-tools/hook-functions
if [ -f /lib/firmware/esos.elf ]; then
    mkdir -p "${DESTDIR}/lib/firmware"
    cp /lib/firmware/esos.elf "${DESTDIR}/lib/firmware/esos.elf"
fi
HOOK
    chmod +x "$ROOTFS/etc/initramfs-tools/hooks/esos-firmware"
fi

# Update initramfs after firmware install
chroot "$ROOTFS" /bin/bash <<CHROOT
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
update-initramfs -u -k all 2>/dev/null || true
CHROOT

# ─── Step 6: Build GRUB EFI binary ───────────────────────────────────────────
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

# ─── Step 7: Unmount pseudo-filesystems ───────────────────────────────────────
inf "[7/9] Unmounting pseudo-filesystems..."
umount_fs "$ROOTFS"
sync
sleep 1

# ─── Step 8: Create partition images ─────────────────────────────────────────
inf "[8/9] Creating partition images..."

# --- EFI partition (FAT32, built with mtools — no mount needed) ---
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

# --- Root partition (ext4, built with mke2fs -d — no mount needed) ---
inf "Creating root partition image (${EXT4_SIZE_MB}MiB)..."

# Remove EFI content from rootfs (it lives on the FAT partition)
rm -rf "$ROOTFS/boot/efi/"*
mkdir -p "$ROOTFS/boot/efi"

# Clean transient directories
rm -rf "$ROOTFS/tmp/"*

# Create ext4 image directly from the rootfs directory
truncate -s ${EXT4_SIZE_MB}M /build/rootfs.img
mke2fs -t ext4 -F \
    -d "$ROOTFS" \
    -L rootfs \
    -m 1 \
    /build/rootfs.img

# Read back the ext4 UUID
ROOT_UUID=$(blkid -s UUID -o value /build/rootfs.img)
inf "Root UUID: $ROOT_UUID"

# --- Patch fstab and grub.cfg into the ext4 image using debugfs ---
inf "Writing fstab and grub.cfg into ext4 image..."

cat > /tmp/fstab <<EOF
UUID=$ROOT_UUID  /         ext4  defaults,noatime,errors=remount-ro  0  1
UUID=$EFI_UUID   /boot/efi vfat  defaults                            0  2
EOF
debugfs -w -R "rm etc/fstab" /build/rootfs.img 2>/dev/null || true
debugfs -w -R "write /tmp/fstab etc/fstab" /build/rootfs.img

if [ -n "$KVER" ]; then
    cat > /tmp/grub.cfg <<EOF
set default=0
set timeout=5

insmod gzio
insmod part_gpt
insmod ext2
insmod search_fs_uuid

search --no-floppy --fs-uuid --set=root $ROOT_UUID

menuentry 'Debian GNU/Linux' --class debian --class gnu-linux --class gnu --class os {
    echo 'Loading Linux $KVER ...'
    linux /boot/vmlinuz-$KVER root=UUID=$ROOT_UUID ro quiet
    echo 'Loading initial ramdisk ...'
    initrd /boot/initrd.img-$KVER
}
EOF
    debugfs -w -R "rm boot/grub/grub.cfg" /build/rootfs.img 2>/dev/null || true
    debugfs -w -R "write /tmp/grub.cfg boot/grub/grub.cfg" /build/rootfs.img
    inf "Patched grub.cfg for kernel $KVER"
else
    inf "WARNING: No kernel found, skipping grub.cfg generation"
fi

rm -f /tmp/fstab /tmp/grub.cfg

# ─── Step 9: Assemble GPT disk image ─────────────────────────────────────────
inf "[9/9] Assembling GPT disk image (${IMAGE_SIZE_MB}MiB)..."
mkdir -p /output
truncate -s ${IMAGE_SIZE_MB}M "$OUTPUT"

# Write GPT partition table with sfdisk
sfdisk "$OUTPUT" <<EOF
label: gpt
first-lba: 2048

start=$((EFI_START_MB * 2048)), size=$((EFI_SIZE_MB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="ESP"
start=$((ROOTFS_START_MB * 2048)), type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="rootfs"
EOF

# Write partition images at correct offsets (conv=notrunc preserves GPT)
dd if=/build/efi.img    of="$OUTPUT" bs=1M seek=$EFI_START_MB    conv=notrunc status=progress
dd if=/build/rootfs.img of="$OUTPUT" bs=1M seek=$ROOTFS_START_MB conv=notrunc status=progress

# Clean up temp images
rm -f /build/efi.img /build/rootfs.img

echo ""
echo "============================================"
echo " Build complete!"
echo " Output:   $OUTPUT"
echo " Size:     $(du -sh "$OUTPUT" | cut -f1)"
echo " DateTime: $CURRENT_DATETIME"
echo " Root UUID: $ROOT_UUID"
echo " EFI UUID:  $EFI_UUID"
echo "============================================"
