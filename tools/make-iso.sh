#!/usr/bin/env bash
# Project Churro - Build a bootable UEFI El-Torito ISO for iVentoy PXE / Ventoy / USB.
# Generates a self-contained updater/installer ISO using the Churro kernel and BusyBox initramfs.
# Updates existing installs in-place without touching userdata.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)

die() { echo "make-iso: error: $*" >&2; exit 1; }
log() { echo ">> $*"; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing required command: $c"; done; }

need grub-mkrescue xorriso python3 sgdisk dd gzip cpio

[ $# -ge 2 ] || die "usage: make-iso.sh <churro.img> <out.iso>"
IMG=$(realpath "$1"); OUT_ISO=$(realpath "$2")
[ -f "$IMG" ] || die "image not found: $IMG"

LOOP=""
cleanup() {
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
  [ -n "${ISO_ROOT:-}" ] && rm -rf "$ISO_ROOT" 2>/dev/null || true
  [ -n "${INITRD_ROOT:-}" ] && rm -rf "$INITRD_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

log "analyzing $IMG"
LOOP=$(losetup -f --show -r -P "$IMG")
partprobe "$LOOP" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 1

part() {
  local n; n=$(sgdisk -p "$LOOP" | awk -v l="$1" '$NF == l {print $1; exit}')
  [ -n "$n" ] || die "no partition $1 in $IMG"
  echo "${LOOP}p$n"
}

P_ESP=$(part EFI-SYSTEM)
P_VBM=$(part vbmeta_a)
P_SUP=$(part super)

ISO_ROOT=$(mktemp -d /tmp/churro-iso.XXXX)
INITRD_ROOT=$(mktemp -d /tmp/churro-initrd.XXXX)
mkdir -p "$ISO_ROOT/boot/grub" "$INITRD_ROOT"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,mnt,lib64,lib/x86_64-linux-gnu,lib/modules,payload}

# 1. Extract Churro kernel from ESP
log "extracting Churro kernel from EFI-SYSTEM"
MNT_ESP=$(mktemp -d)
mount -o ro "$P_ESP" "$MNT_ESP"
cp "$MNT_ESP/churro/kernel" "$ISO_ROOT/boot/kernel"
umount "$MNT_ESP"; rmdir "$MNT_ESP"

# 2. Extract payload partitions into initrd
log "extracting update payload (EFI-SYSTEM, vbmeta_a, super LP metadata)"
dd if="$P_ESP" of="$INITRD_ROOT/payload/esp.img" bs=1M status=none
dd if="$P_VBM" of="$INITRD_ROOT/payload/vbmeta.img" bs=64K status=none
dd if="$P_SUP" of="$INITRD_ROOT/payload/super_meta.bin" bs=1M count=1 status=none

log "extracting modified logical partitions from super"
: > "$INITRD_ROOT/payload/extents.txt"
for lp in vendor_dlkm_a vendor_a system_ext_a; do
  read -r off sz < <(python3 "$HERE/lib/lpinfo.py" "$P_SUP" "$lp")
  echo "$lp $off $sz" >> "$INITRD_ROOT/payload/extents.txt"
  count_sec=$(( (sz + 511) / 512 )) off_sec=$((off / 512))
  log "  -> $lp ($((sz >> 20)) MiB at sector $off_sec)"
  dd if="$P_SUP" of="$INITRD_ROOT/payload/$lp.img" bs=512 skip=$off_sec count=$count_sec status=none
done

# 3. Populate initrd system binaries
log "bundling BusyBox and sgdisk into initramfs"
cp /bin/busybox "$INITRD_ROOT/bin/busybox"
chmod 4755 "$INITRD_ROOT/bin/busybox"
cp /usr/sbin/sgdisk "$INITRD_ROOT/bin/sgdisk"
chmod 0755 "$INITRD_ROOT/bin/sgdisk"

# Copy dynamic linker and required shared libraries for sgdisk
cp /lib64/ld-linux-x86-64.so.2 "$INITRD_ROOT/lib64/"
for lib in /lib/x86_64-linux-gnu/{libuuid.so.1,libpopt.so.0,libstdc++.so.6,libm.so.6,libgcc_s.so.1,libc.so.6}; do
  [ -f "$lib" ] && cp "$lib" "$INITRD_ROOT/lib/x86_64-linux-gnu/"
done

# Copy extra storage modules if cached
KMOD_DIR=$(ls -d /var/cache/churro/kernel-generic-*/modroot/lib/modules/*/ 2>/dev/null | head -1 || true)
if [ -n "$KMOD_DIR" ]; then
  find "$KMOD_DIR" -name "*.ko" | grep -E "(ahci|sdhci|virtio_pci)" | while read -r ko; do
    cp "$ko" "$INITRD_ROOT/lib/modules/" 2>/dev/null || true
  done
fi

# 4. Create init script
cat > "$INITRD_ROOT/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo ""
echo "================================================================"
echo "    Project Churro - UEFI Updater & Recovery Tool               "
echo "================================================================"
echo ""

# Load storage modules if present
for m in /lib/modules/*.ko; do
  [ -f "$m" ] && insmod "$m" 2>/dev/null || true
done
sleep 2

MODE="update"
grep -q "churro.mode=shell" /proc/cmdline && MODE="shell"

if [ "$MODE" = "shell" ]; then
  echo ">> Entering debug shell. Type 'exit' or 'reboot' when done."
  sh
  reboot -f
fi

echo ">> Searching for disks with an existing Churro installation..."
FOUND_DISKS=""

for d in /sys/block/sd* /sys/block/nvme*n1 /sys/block/mmcblk*; do
  [ -e "$d" ] || continue
  bn=$(basename "$d")
  dev="/dev/$bn"
  [ -b "$dev" ] || continue

  # Check if disk has Churro partition layout (EFI-SYSTEM and userdata)
  gpt_names=$(/bin/sgdisk -p "$dev" 2>/dev/null | awk '{print $NF}' || true)
  if echo "$gpt_names" | grep -qx "EFI-SYSTEM" && echo "$gpt_names" | grep -qx "userdata"; then
    FOUND_DISKS="$FOUND_DISKS $dev"
  fi
done

TARGET_DISK=""
for fd in $FOUND_DISKS; do
  echo "   Found Churro installation on: $fd"
  TARGET_DISK="$fd"
done

if [ -z "$TARGET_DISK" ]; then
  echo ""
  echo ">> ERROR: No disk with an existing Churro installation was found!"
  echo "   Available block devices:"
  ls -l /dev/sd* /dev/nvme* 2>/dev/null || true
  echo ""
  echo ">> Dropping to rescue shell..."
  sh
  reboot -f
fi

echo ""
echo ">> Target disk selected: $TARGET_DISK"
echo ">> ALL USERDATA ON THIS DISK WILL BE PRESERVED."
echo ">> Applying updates (EFI-SYSTEM, vbmeta_a, super)..."

tpart() {
  local n; n=$(/bin/sgdisk -p "$TARGET_DISK" | awk -v l="$1" '$NF == l {print $1; exit}')
  [ -n "$n" ] || { echo "error: missing partition $1 on $TARGET_DISK" >&2; return 1; }
  case $TARGET_DISK in *[0-9]) echo "${TARGET_DISK}p$n" ;; *) echo "${TARGET_DISK}$n" ;; esac
}

T_ESP=$(tpart EFI-SYSTEM)
T_VBM=$(tpart vbmeta_a)
T_SUP=$(tpart super)
T_DAT=$(tpart userdata)

echo "   Partitions: ESP=$T_ESP, vbmeta=$T_VBM, super=$T_SUP, userdata=$T_DAT"

# Preserve boot_source
BSRC="usb"
MNT_TMP=/mnt/esp_check
mkdir -p "$MNT_TMP"
if mount -t vfat -o ro "$T_ESP" "$MNT_TMP" 2>/dev/null; then
  grep -q "boot_source=internal" "$MNT_TMP/churro/env.cfg" 2>/dev/null && BSRC="internal"
  umount "$MNT_TMP"
fi

echo ">> Writing vbmeta_a..."
dd if=/payload/vbmeta.img of="$T_VBM" bs=65536 conv=fsync 2>/dev/null

echo ">> Writing EFI-SYSTEM (boot_source=$BSRC)..."
dd if=/payload/esp.img of="$T_ESP" bs=1048576 conv=fsync 2>/dev/null
if [ "$BSRC" = "internal" ]; then
  mount -t vfat "$T_ESP" "$MNT_TMP"
  sed -i 's/^set boot_source=.*/set boot_source=internal/' "$MNT_TMP/churro/env.cfg"
  umount "$MNT_TMP"
fi
rmdir "$MNT_TMP" 2>/dev/null || true

echo ">> Writing super metadata header..."
dd if=/payload/super_meta.bin of="$T_SUP" bs=1048576 count=1 conv=notrunc,fsync 2>/dev/null

while read -r lp off sz; do
  [ -n "$lp" ] || continue
  count_sec=$(( (sz + 511) / 512 ))
  off_sec=$((off / 512))
  echo ">> Writing $lp ($((sz >> 20)) MiB)..."
  dd if="/payload/$lp.img" of="$T_SUP" bs=512 seek=$off_sec count=$count_sec conv=notrunc,fsync 2>/dev/null
done < /payload/extents.txt

sync
echo ""
echo "================================================================"
echo ">> SUCCESS! Update applied successfully."
echo ">> All userdata, apps, and settings on $T_DAT were preserved."
echo ">> Rebooting in 5 seconds..."
echo "================================================================"
sleep 5
reboot -f
EOF
chmod 0755 "$INITRD_ROOT/init"

# 5. Pack initramfs
log "packing initrd ($INITRD_ROOT -> $ISO_ROOT/boot/initrd.img)"
(cd "$INITRD_ROOT" && find . | cpio -o -H newc -R 0:0 --quiet) | gzip -1 > "$ISO_ROOT/boot/initrd.img"

# 6. Create GRUB configuration
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

insmod efi_gop
insmod font
if loadfont /boot/grub/fonts/unicode.pf2; then
  insmod gfxterm
  set gfxmode=auto
  terminal_output gfxterm
fi

menuentry "Project Churro - Update Existing Disk (Preserve All Data)" {
    echo "Loading Churro kernel and updater..."
    linux /boot/kernel console=tty0 churro.mode=update
    initrd /boot/initrd.img
}

menuentry "Project Churro - Recovery & Debug Shell" {
    echo "Loading Churro kernel and shell..."
    linux /boot/kernel console=tty0 churro.mode=shell
    initrd /boot/initrd.img
}
EOF

# 7. Generate bootable ISO
log "generating hybrid UEFI ISO ($OUT_ISO)"
mkdir -p "$(dirname "$OUT_ISO")"
grub-mkrescue -o "$OUT_ISO" "$ISO_ROOT" -- -volid "CHURRO_UPDATE" >/dev/null 2>&1

log "done: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
