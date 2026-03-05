# Debian RISC-V Image Builder

Builds a bootable Debian Trixie RISC-V disk image using Docker.

Uses `mke2fs -d` and `mtools` to create partition images directly from
directories — no loop devices or partition mounting required.

## Directory Structure

```
riscv-builder/
├── docker-compose.yml
├── Dockerfile
├── build.sh
├── input/          ← Put your files here
│   ├── linux-image-6.18.12+_*_riscv64.deb
│   ├── linux-headers-6.18.12+_*_riscv64.deb
│   └── rtthread-n308.elf          (optional firmware)
└── output/         ← Final image appears here
    └── debian-riscv64.img
```

## Usage

1. Create the input/output directories:
   ```bash
   mkdir -p input output
   ```

2. Copy your kernel debs and firmware into `input/`:
   ```bash
   cp linux-image-*.deb input/
   cp linux-headers-*.deb input/
   cp rtthread-n308.elf input/    # optional
   ```

3. Edit `docker-compose.yml` to set your passwords, timezone, and image size.

4. Build and run:
   ```bash
   docker compose build
   docker compose up
   ```

5. When done, `output/debian-riscv64.img` is your bootable image.

## Flash to SD card / eMMC

```bash
sudo dd if=output/debian-riscv64.img of=/dev/sdX bs=4M status=progress
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `IMAGE_SIZE_MB` | `12288` | Output image size in MB |
| `MIRROR` | `http://deb.debian.org/debian` | Debian mirror |
| `HOSTNAME` | `riscv-debian` | System hostname |
| `ROOT_PASSWORD` | `root` | Root password (change this!) |
| `USER_NAME` | `user` | Regular user account name |
| `USER_PASSWORD` | `user` | Regular user password (change this!) |
| `INSTALL_XFCE` | `false` | Set to `true` to install XFCE desktop |
| `TIMEZONE` | `UTC` | Timezone (e.g. `Europe/Rome`) |

## How It Works

1. **Debootstrap** creates a minimal riscv64 rootfs via QEMU user-mode emulation
2. Packages, kernel, and firmware are installed inside the chroot
3. **mke2fs -d** creates the ext4 root image directly from the directory (no mounting)
4. **mkfs.fat + mtools** creates the EFI partition image (no mounting)
5. Filesystem UUIDs are read back with `blkid`, then `fstab` and `grub.cfg` are
   patched into the ext4 image using `debugfs`
6. **sfdisk + dd** assembles the final GPT disk image from the partition images

## Notes

- The container runs `--privileged` for binfmt registration, pseudo-filesystem
  mounts, and chroot. No loop devices are used.
- If no `.deb` files are found in `input/`, the build skips kernel installation.
- The firmware file `rtthread-n308.elf` is installed as `/lib/firmware/esos.elf`.
- Debug kernel packages (`*-dbg_*.deb`) in `input/` are automatically skipped.
- The minbase tarball is cached in `output/minbase.tar.gz` for faster rebuilds.
  Delete it to force a fresh debootstrap.

## Creating a Live CD / ISO

This builder produces a raw disk image for flashing to storage. To create a
bootable live ISO instead (for RISC-V or other architectures), see the approach
below.

### Differences from a disk image

| | Disk Image | Live ISO |
|---|---|---|
| Boot method | UEFI firmware reads GPT/ESP | ISO 9660 with El Torito EFI boot |
| Root filesystem | ext4 on disk | SquashFS (read-only, compressed) |
| Persistence | Read-write | Ephemeral (RAM overlay) |
| Tool | `mke2fs -d` | `mksquashfs` + `xorriso` |

### Steps to adapt this build for a live ISO

1. **Build the rootfs** — steps 1–5 of `build.sh` are identical. You get a
   populated directory tree in `$ROOTFS`.

2. **Create a SquashFS image** from the rootfs:
   ```bash
   mksquashfs $ROOTFS /build/filesystem.squashfs \
       -comp zstd -Xcompression-level 19 \
       -e boot/efi
   ```

3. **Set up the ISO directory structure**:
   ```
   iso/
   ├── EFI/
   │   └── BOOT/
   │       └── BOOTRISCV64.EFI     ← GRUB EFI binary
   ├── boot/
   │   ├── grub/
   │   │   └── grub.cfg            ← points to squashfs
   │   ├── vmlinuz
   │   └── initrd.img
   └── live/
       └── filesystem.squashfs
   ```

4. **Create a GRUB config** that boots from the squashfs:
   ```
   search --no-floppy --label --set=root LIVE_ISO
   menuentry 'Debian Live' {
       linux /boot/vmlinuz boot=live toram
       initrd /boot/initrd.img
   }
   ```

5. **Create an EFI boot image** (FAT image embedded in the ISO):
   ```bash
   truncate -s 8M /build/efiboot.img
   mkfs.fat -F12 /build/efiboot.img
   mmd -i /build/efiboot.img ::/EFI ::/EFI/BOOT
   mcopy -i /build/efiboot.img \
       $ROOTFS/boot/efi/EFI/debian/grubriscv64.efi \
       ::/EFI/BOOT/BOOTRISCV64.EFI
   ```

6. **Assemble the ISO** with `xorriso`:
   ```bash
   xorriso -as mkisofs \
       -V "LIVE_ISO" \
       -e efiboot.img -no-emul-boot \
       -isohybrid-gpt-basdat \
       -o /output/debian-riscv64-live.iso \
       /build/iso
   ```

### Key additional packages

Install these inside the rootfs (step 3 of the main build) for live boot:

- `live-boot` — handles the SquashFS + overlay root at boot time
- `live-config` — auto-configures user, locale, keyboard in the live session

For **other architectures** (amd64, arm64), the process is the same — only the
debootstrap `--arch`, GRUB target (`--target=x86_64-efi`, `--target=arm64-efi`),
and the EFI fallback binary name change (`BOOTX64.EFI`, `BOOTAA64.EFI`).
