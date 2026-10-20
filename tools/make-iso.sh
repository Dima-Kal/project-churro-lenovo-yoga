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

# 1. Extract Churro kernel from ESP FIRST so xorriso places it at a low LBA before initrd.img
log "extracting Churro kernel from EFI-SYSTEM"
MNT_ESP=$(mktemp -d)
mount -o ro "$P_ESP" "$MNT_ESP"
cp "$MNT_ESP/churro/kernel" "$ISO_ROOT/boot/00-kernel"
ln -sf 00-kernel "$ISO_ROOT/boot/kernel"
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

# Copy extra storage, USB, Type-C, LPSS, and pinctrl modules in dependency order
PACK_STORAGE=$(ls -d /var/cache/churro/packs-generic-*/storage 2>/dev/null | head -1 || true)
if [ -n "$PACK_STORAGE" ] && [ -f "$PACK_STORAGE/modules.load" ]; then
  cp "$PACK_STORAGE"/modules.load "$INITRD_ROOT/lib/modules/modules.load"
  while read -r ko; do
    [ -n "$ko" ] && [ -f "$PACK_STORAGE/$ko" ] && cp "$PACK_STORAGE/$ko" "$INITRD_ROOT/lib/modules/"
  done < "$PACK_STORAGE/modules.load"
fi

# Extract essential platform/USB/PCI/Network modules from vendor_dlkm_a so USB-C/Thunderbolt & Ethernet adapters work in initrd
MNT_DLKM=$(mktemp -d)
read -r dlkm_off dlkm_sz < <(python3 "$HERE/lib/lpinfo.py" "$P_SUP" "vendor_dlkm_a")
if mount -o ro,offset=$dlkm_off,sizelimit=$dlkm_sz "$P_SUP" "$MNT_DLKM" 2>/dev/null; then
  for ko in \
    mfd-core.ko intel-lpss.ko intel-lpss-pci.ko intel-lpss-acpi.ko \
    pinctrl-intel.ko pinctrl-intel-platform.ko pinctrl-alderlake.ko pinctrl-tigerlake.ko pinctrl-meteorlake.ko \
    i2c-designware-core.ko i2c-designware-platform.ko i2c-ccgx-ucsi.ko i2c-designware-pci.ko \
    intel-xhci-usb-role-switch.ko ucsi_acpi.ko xhci-pci-renesas.ko \
    rtsx_pci.ko rtsx_pci_sdmmc.ko rtsx_usb.ko rtsx_usb_sdmmc.ko \
    mii.ko mdio.ko usbnet.ko cdc_ether.ko cdc_ncm.ko r8152.ko r8153_ecm.ko ax88179_178a.ko asix.ko aqc111.ko r8169.ko igc.ko e1000e.ko; do
    if [ -f "$MNT_DLKM/lib/modules/$ko" ]; then
      cp "$MNT_DLKM/lib/modules/$ko" "$INITRD_ROOT/lib/modules/"
      grep -qx "$ko" "$INITRD_ROOT/lib/modules/modules.load" 2>/dev/null || echo "$ko" >> "$INITRD_ROOT/lib/modules/modules.load"
    fi
  done
  umount "$MNT_DLKM"
fi
rmdir "$MNT_DLKM" 2>/dev/null || true

# Create udhcpc script for automatic DHCP configuration in initrd
mkdir -p "$INITRD_ROOT/usr/share/udhcpc"
cat > "$INITRD_ROOT/usr/share/udhcpc/default.script" <<'EOS'
#!/bin/busybox sh
case "$1" in
  deconfig)
    ip addr flush dev "$interface"
    ip link set dev "$interface" up
    ;;
  bound|renew)
    ip addr add "$ip/${mask:-24}" dev "$interface"
    [ -n "$router" ] && ip route add default via "${router%% *}" dev "$interface" 2>/dev/null || true
    ;;
esac
EOS
chmod 0755 "$INITRD_ROOT/usr/share/udhcpc/default.script"

# 4. Create init script
cat > "$INITRD_ROOT/init" <<'EOF'
#!/bin/busybox sh
/bin/busybox --install -s /bin
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
# Android GKI kernels have CONFIG_DEVTMPFS disabled! Mount tmpfs on /dev and populate with mdev -s
mount -t tmpfs tmpfs /dev
mkdir -p /dev/pts /dev/shm
mdev -s 2>/dev/null || true

echo ""
echo "================================================================"
echo "    Project Churro - UEFI Updater & Recovery Tool               "
echo "================================================================"
echo ""

# Load storage modules in dependency order if present
if [ -f /lib/modules/modules.load ]; then
  while read -r ko; do
    [ -n "$ko" ] && [ -f "/lib/modules/$ko" ] && insmod "/lib/modules/$ko" 2>/dev/null || true
  done < /lib/modules/modules.load
fi
sleep 2
mdev -s 2>/dev/null || true

# Wait up to 10 seconds for USB/NVMe disks to finish enumerating and create /dev nodes
echo ">> Waiting for storage devices (USB / NVMe / SD)..."
FOUND_DISKS=""
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  mdev -s 2>/dev/null || true
  for b in /sys/class/block/*; do
    [ -e "$b/dev" ] || continue
    bn=$(basename "$b")
    if [ ! -b "/dev/$bn" ]; then
      maj_min=$(cat "$b/dev")
      maj=${maj_min%:*}
      min=${maj_min#*:}
      mknod "/dev/$bn" b "$maj" "$min" 2>/dev/null || true
    fi
  done

  # Find any disk that has a partition with PARTNAME=EFI-SYSTEM or PARTNAME=super
  for uev in /sys/class/block/*/uevent; do
    [ -f "$uev" ] || continue
    if grep -Eq "^PARTNAME=(EFI-SYSTEM|super|CHURRO-LOG)$" "$uev" 2>/dev/null; then
      pdir=$(dirname "$uev")
      pbn=$(basename "$pdir")
      # Determine parent disk from /sys/block/*/$pbn
      for d in /sys/block/*; do
        if [ -e "$d/$pbn" ]; then
          dbn=$(basename "$d")
          echo " $FOUND_DISKS " | grep -q " /dev/$dbn " || FOUND_DISKS="$FOUND_DISKS /dev/$dbn"
        fi
      done
    fi
  done

  # Fallback: check via sgdisk
  if [ -z "$FOUND_DISKS" ]; then
    for d in /sys/block/sd* /sys/block/nvme* /sys/block/mmcblk* /sys/block/vd*; do
      [ -e "$d" ] || continue
      bn=$(basename "$d")
      dev="/dev/$bn"
      [ -b "$dev" ] || continue
      if /bin/sgdisk -p "$dev" 2>/dev/null | grep -Eq "EFI-SYSTEM|super|CHURRO-LOG"; then
        echo " $FOUND_DISKS " | grep -q " $dev " || FOUND_DISKS="$FOUND_DISKS $dev"
      fi
    done
  fi

  [ -n "$FOUND_DISKS" ] && break
  sleep 1
done

MODE="update"
grep -q "churro.mode=shell" /proc/cmdline && MODE="shell"
grep -q "churro.mode=logs" /proc/cmdline && MODE="logs"

if [ "$MODE" = "shell" ]; then
  echo ">> Entering debug shell. Type 'exit' or 'reboot' when done."
  sh
  reboot -f
fi

echo ">> Searching for disks with an existing Churro installation..."

TARGET_DISK=""
for fd in $FOUND_DISKS; do
  echo "   Found Churro installation on: $fd"
  TARGET_DISK="$fd"
done

if [ -z "$TARGET_DISK" ]; then
  echo ""
  echo ">> ERROR: No disk with an existing Churro installation was found!"
  echo "   Block devices in /sys/block:"
  ls -1 /sys/block/ 2>/dev/null | tr '\n' ' '; echo ""
  echo "   Partitions in /sys/class/block:"
  for u in /sys/class/block/*/uevent; do
    [ -f "$u" ] || continue
    pn=$(grep "^PARTNAME=" "$u" 2>/dev/null || true)
    [ -n "$pn" ] && echo "     $(basename "$(dirname "$u")"): $pn"
  done
  echo ""
  echo ">> Dropping to rescue shell..."
  sh
  reboot -f
fi

tpart() {
  local want=$1 p
  for p in /sys/class/block/$(basename "$TARGET_DISK")*; do
    [ -f "$p/uevent" ] || continue
    if grep -qx "PARTNAME=$want" "$p/uevent" 2>/dev/null; then
      echo "/dev/$(basename "$p")"
      return 0
    fi
  done
  local n; n=$(/bin/sgdisk -p "$TARGET_DISK" | awk -v l="$want" '$NF == l {print $1; exit}')
  [ -n "$n" ] || { echo "error: missing partition $want on $TARGET_DISK" >&2; return 1; }
  case $TARGET_DISK in *[0-9]) echo "${TARGET_DISK}p$n" ;; *) echo "${TARGET_DISK}$n" ;; esac
}

extract_and_serve_logs() {
  T_LOG=$(tpart CHURRO-LOG || true)
  [ -n "$T_LOG" ] || return 0
  mkdir -p /mnt/logs /logs
  mount -t vfat -o ro "$T_LOG" /mnt/logs 2>/dev/null || return 0
  echo ">> Extracting crash logs from $T_LOG into /logs/ ..."
  for f in boot.log boot.prev.log logcat.log logcat.prev.log; do
    if [ -f "/mnt/logs/$f" ]; then
      awk 'NF == 0 {exit} {print}' "/mnt/logs/$f" > "/logs/$f"
      echo "   /logs/$f: $(wc -l < "/logs/$f") lines ($(wc -c < "/logs/$f") bytes)"
    fi
  done
  umount /mnt/logs 2>/dev/null || true

  cat > /logs/index.html <<'EOH'
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Project Churro Crash Logs</title>
<style>body{font-family:monospace;background:#111;color:#eee;padding:20px} a{color:#4da6ff;font-size:18px;display:block;margin:10px 0}</style>
</head>
<body>
<h2>Project Churro - Crash &amp; Boot Logs</h2>
<a href="boot.log">boot.log (Current Boot Kernel + Init Log)</a>
<a href="boot.prev.log">boot.prev.log (Previous Boot Kernel + Init Log)</a>
<a href="logcat.log">logcat.log (Current Boot Android Logcat)</a>
<a href="logcat.prev.log">logcat.prev.log (Previous Boot Android Logcat)</a>
</body></html>
EOH

  # Bring up only real Ethernet/USB-LAN interfaces via DHCP and start BusyBox HTTP server on port 80
  ip link set lo up 2>/dev/null || true
  for net in /sys/class/net/*; do
    ifn=$(basename "$net")
    case "$ifn" in
      eth*|en*|usb*)
        echo ">> Bringing up network interface $ifn via DHCP..."
        ip link set "$ifn" up 2>/dev/null || true
        udhcpc -i "$ifn" -n -q -t 3 -T 1 2>/dev/null || true
        ;;
    esac
  done

  MY_IP=$(ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {sub(/\/.*/, "", $2); print $2; exit}')
  if [ -n "$MY_IP" ]; then
    httpd -p 80 -h /logs 2>/dev/null || httpd -p 8080 -h /logs 2>/dev/null || true
    echo ""
    echo "================================================================"
    echo ">> HTTP Log Server Active: http://$MY_IP/"
    echo "   - http://$MY_IP/boot.log"
    echo "   - http://$MY_IP/boot.prev.log"
    echo "   - http://$MY_IP/logcat.log"
    echo "   - http://$MY_IP/logcat.prev.log"
    echo "================================================================"
  fi
}

if [ "$MODE" = "logs" ]; then
  extract_and_serve_logs
  echo ""
  if [ -s /logs/boot.log ]; then
    echo "================ LAST 40 LINES OF boot.log ================"
    tail -n 40 /logs/boot.log
    echo "==========================================================="
  elif [ -s /logs/boot.prev.log ]; then
    echo "================ LAST 40 LINES OF boot.prev.log ================"
    tail -n 40 /logs/boot.prev.log
    echo "================================================================"
  else
    echo ">> Note: boot.log and boot.prev.log are empty."
  fi
  echo ""
  echo ">> Logs are hosted over HTTP above. Press Enter or type 'reboot' when done."
  sh
  reboot -f
fi

echo ""
echo ">> Target disk selected: $TARGET_DISK"
echo ">> ALL USERDATA ON THIS DISK WILL BE PRESERVED."
echo ">> Applying updates (EFI-SYSTEM, vbmeta_a, super)..."

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
    linux /boot/kernel console=tty0 iommu.passthrough=1 efi_pstore.pstore_disable=1 churro.mode=update
    initrd /boot/initrd.img
}

menuentry "Project Churro - View / Extract Crash Logs (boot.log & logcat.log)" {
    echo "Loading Churro kernel and log viewer..."
    linux /boot/kernel console=tty0 iommu.passthrough=1 efi_pstore.pstore_disable=1 churro.mode=logs
    initrd /boot/initrd.img
}

menuentry "Project Churro - Recovery & Debug Shell" {
    echo "Loading Churro kernel and shell..."
    linux /boot/kernel console=tty0 iommu.passthrough=1 efi_pstore.pstore_disable=1 churro.mode=shell
    initrd /boot/initrd.img
}
EOF

# 7. Generate bootable ISO
log "generating hybrid UEFI ISO ($OUT_ISO)"
mkdir -p "$(dirname "$OUT_ISO")"
grub-mkrescue -o "$OUT_ISO" "$ISO_ROOT" -- -volid "CHURRO_UPDATE" >/dev/null 2>&1

log "done: $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
