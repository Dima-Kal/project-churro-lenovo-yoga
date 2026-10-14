#!/usr/bin/env bash
# Project Churro - make a Googlebook OS recovery image bootable on generic UEFI PCs.
# Usage: sudo ./churro.sh auto  <recovery.bin> <out.img> [--gfx mesa|native|soft] [--packs virt,gpu,storage,wifi]
#        sudo ./churro.sh build <recovery.bin> <out.img> [--kernel dir] [--modules <pack dir>]...
#                               [--features a,b] [--boot-source external|internal]
#        sudo ./churro.sh install <churro.img> <disk>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

# NPU (Intel "VPU" AI accelerator) driver. The image only ships Panther Lake NPU firmware; on
# other Intel chips (e.g. Arrow Lake) intel_vpu fails to load it and the machine freezes during
# boot. true = let it load (only for Panther Lake-class machines).
CHURRO_NPU=${CHURRO_NPU:-false}
. "$HERE/lib/bootimg.sh"; . "$HERE/lib/bootconfig.sh"; . "$HERE/lib/esp.sh"; . "$HERE/lib/ramdisk.sh"; . "$HERE/lib/repack.sh"

die() { echo "churro: $*" >&2; exit 1; }
log() { echo ">> $*"; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "missing tool: $c"; done; }

LOOP=""; cleanup() { [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT

# Partition by GPT label (labels are stable across Googlebook images, numbers might not be).
part() { local n; n=$(sgdisk -p "$LOOP" | awk -v l="$1" '$NF == l {print $1; exit}'); [ -n "$n" ] || die "no partition $1"; echo "${LOOP}p$n"; }

cmd_build() {
  local in=$1 out=$2; shift 2
  local packs=() bsrc=external feats=security-software,firmware-lockdown repack=1 kdir=""
  while [ $# -gt 0 ]; do case $1 in
    --modules) packs+=("$2"); shift 2 ;;
    --features) feats=$2; shift 2 ;;
    --no-repack) repack=0; shift ;;     # dev: partitions already patched, only redo boot files
    --boot-source) bsrc=$2; shift 2 ;;
    --kernel) kdir=$2; shift 2 ;;      # Churro kernel dir from kmod/build-kernel.sh (kernel, kernel.release)
    *) die "unknown option $1" ;; esac; done
  need losetup sgdisk mkfs.vfat grub-mkstandalone cpio lz4 od
  [ "$(id -u)" = 0 ] || die "run as root"

  if [ "$(realpath "$in")" != "$(realpath -m "$out")" ]; then
    log "copying $in -> $out (sparse)"; cp --sparse=always "$in" "$out"
  fi
  LOOP=$(losetup -f --show -P "$out"); udevadm settle 2>/dev/null || sleep 1
  local W; W=$(mktemp -d /tmp/churro.XXXX)

  log "extracting boot images (slot _a)"
  bootimg_extract "$(part boot_a)" "$W/boot"
  bootimg_extract "$(part init_boot_a)" "$W/init_boot"
  vendorboot_extract "$(part vendor_boot_a)" "$W/vboot"
  ls "$W/vboot"

  local fdirs=() f p
  for f in ${feats//,/ }; do [ -d "$HERE/features/$f" ] || die "unknown feature: $f"; fdirs+=("$HERE/features/$f"); done
  if [ "$repack" = 1 ] && [ ${#fdirs[@]} -gt 0 ]; then
    log "applying features: $feats (dm-verity off)"
    vbmeta_disable "$(part vbmeta_a)"
    for p in vendor system_ext product odm; do
      for f in "${fdirs[@]}"; do
        if [ -d "$f/$p" ] || [ -f "$f/patch-$p.sh" ]; then erofs_repack "$(part super)" "${p}_a" "/$p" "${fdirs[@]}"; break; fi
      done
    done
  fi

  log "building Churro ramdisk"
  ramdisk_build "$W" "${packs[@]}"
  for f in "${fdirs[@]}"; do [ -f "$f/build-ramdisk.sh" ] && bash "$f/build-ramdisk.sh" "$W/cr"; done
  ramdisk_pack "$W"

  log "writing bootconfig + initrd"
  local vbc; vbc=$(cat "$W/vboot/bootconfig")
  cat > "$W/bootconfig.txt" <<EOF
$vbc
androidboot.slot_suffix=_a
androidboot.force_normal_boot=1
androidboot.verifiedbootstate=orange
androidboot.vbmeta.device_state=unlocked
androidboot.veritymode=enforcing
androidboot.serialno=CHURRO$(od -An -tx1 -N4 /dev/urandom | tr -d ' ')
androidboot.bootloader=churro-grub
EOF
  for f in "${fdirs[@]}"; do [ -f "$f/bootconfig" ] && cat "$f/bootconfig" >> "$W/bootconfig.txt"; done
  bootconfig_pack "$W/bootconfig.txt" "$W/bootconfig.bin"
  # Boot v4 order: vendor ramdisks (platform, dlkm), generic ramdisk, then extras, bootconfig last.
  cat "$W"/vboot/ramdisk_*_1_* "$W"/vboot/ramdisk_*_3_* "$W/init_boot/ramdisk" "$W/churro.cpio" \
      "$W/bootconfig.bin" > "$W/initrd.img"
  if [ -n "$kdir" ]; then
    # must carry the GKI release string, or none of the image's prebuilt modules will load
    local want; want=$(strings "$W/boot/kernel" 2>/dev/null | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+-android[^ ]*' || true)
    [ -z "$want" ] || [ "$want" = "$(cat "$kdir/kernel.release")" ] || log "warning: Churro kernel $(cat "$kdir/kernel.release") != image kernel $want"
    log "using Churro kernel $(cat "$kdir/kernel.release")"
    cp "$kdir/kernel" "$W/kernel"
  else
    cp "$W/boot/kernel" "$W/kernel"
  fi

  # features may add kernel cmdline args (e.g. no pKVM when the security VM isn't used)
  local fargs=""
  for f in "${fdirs[@]}"; do [ -f "$f/cmdline" ] && fargs="$fargs $(grep -vE '^\s*(#|$)' "$f/cmdline" | tr '\n' ' ')"; done
  export CHURRO_EXTRA_ARGS="$(echo $fargs ${CHURRO_EXTRA_ARGS:-})"
  fargs=""   # ...and args for the "debug" boot entries only
  for f in "${fdirs[@]}"; do [ -f "$f/cmdline-debug" ] && fargs="$fargs $(grep -vE '^\s*(#|$)' "$f/cmdline-debug" | tr '\n' ' ')"; done
  export CHURRO_DEBUG_ARGS="$(echo $fargs)"

  # Slot state: the boot HAL keeps ChromeOS-style slot flags in the vbmeta_a/_b GPT attributes
  # (bits 48-51 priority, 52-55 tries, 56 successful). Recovery images ship slot B marked and A
  # not, but we boot A: unmarked, vold runs *every* boot as an unfinished update (checkpoint,
  # dm-bow on /data), which fills a small /data and panics. Mark A active + successful, clear B.
  local va vb b; va=$(part vbmeta_a); va=${va##*p}; vb=$(part vbmeta_b); vb=${vb##*p}
  for b in 48 49 50 51 52 53 54 55 56; do sgdisk -A "$vb:clear:$b" "$LOOP" >/dev/null; done
  for b in 48 49 50 51 56; do sgdisk -A "$va:set:$b" "$LOOP" >/dev/null; done

  # Log partition: the image's KERN-A (512 MiB, unused legacy ChromeOS kernel slot, all zeros)
  # becomes a FAT32 "basic data" partition, so Windows shows it as a drive (the ESP is hidden).
  local ln; ln=$(sgdisk -p "$LOOP" | awk '$NF == "KERN-A" || $NF == "CHURRO-LOG" {print $1; exit}')
  if [ -n "$ln" ]; then
    log "log partition: p$ln -> CHURRO-LOG (FAT32)"
    sgdisk -t "$ln:0700" -c "$ln:CHURRO-LOG" "$LOOP" >/dev/null
    mkfs.vfat -F 32 -n CHURRO-LOG "${LOOP}p$ln" >/dev/null
    # Fixed-size log files, pre-filled with blank lines: the boot logger only overwrites them in
    # place, so the FAT/directory never change at boot and a power cut can't corrupt them.
    local lm; lm=$(mktemp -d); mount "${LOOP}p$ln" "$lm"
    head -c $((64 << 20)) /dev/zero | tr '\0' '\n' > "$lm/boot.log"
    cp "$lm/boot.log" "$lm/boot.prev.log"
    umount "$lm"; rmdir "$lm"
  fi

  # Vendor cmdline, made safe for a non-Googlebook PC:
  # - BIOS flash read-only: drop spi-intel.writeable=1 / ignore_protection_status=1 and blacklist
  #   the SPI flash drivers outright (Googlebooks flash their own firmware from Android);
  # - NPU driver blocked unless CHURRO_NPU=true (see top).
  # module_blacklist is a single kernel parameter (the last one wins), so extend the vendor's.
  local vcmd blk=spi_intel,spi_intel_pci
  [ "$CHURRO_NPU" = true ] || blk="$blk,intel_vpu"
  vcmd=$(sed -E 's/ ?spi-intel\.(writeable|ignore_protection_status)=[^ ]*//g' "$W/vboot/cmdline")
  case $vcmd in
    *module_blacklist=*) vcmd=$(printf '%s' "$vcmd" | sed -E "s/module_blacklist=([^ ]*)/module_blacklist=\1,$blk/") ;;
    *) vcmd="$vcmd module_blacklist=$blk" ;;
  esac
  log "kernel cmdline: flash read-only, blacklisted: $blk"

  log "populating EFI-SYSTEM"
  esp_build "$(part EFI-SYSTEM)" "$W" "$vcmd" "$bsrc"
  rm -rf "$W"
  log "done: $out"
}

# install <churro.img> <target disk>: the image already has the Googlebook *installed* layout
# (same as partition-script.sh writes), so: copy it, move the backup GPT to the end of the disk,
# stretch userdata (partition 1, placed last) over the free space, mark the ESP boot as internal.
# Android formats userdata/metadata itself on first boot ("formattable").
cmd_install() {
  local img=$1 dst=$2
  need sgdisk dd partprobe
  [ "$(id -u)" = 0 ] || die "run as root"
  [ -b "$dst" ] || die "$dst is not a block device"
  [ "$(cat "/sys/block/$(basename "$dst")/removable" 2>/dev/null || echo 0)" = 0 ] || log "note: $dst is removable"
  local isz dsz; isz=$(stat -c %s "$img"); dsz=$(blockdev --getsize64 "$dst")
  [ "$dsz" -ge "$isz" ] || die "target too small ($dsz < $isz bytes)"
  log "this ERASES $dst ($((dsz / 1024 / 1024 / 1024)) GiB). Type YES to continue:"; read -r a; [ "$a" = YES ] || die "aborted"
  log "writing image"; dd if="$img" of="$dst" bs=4M conv=fsync,sparse status=progress
  sgdisk -e "$dst" >/dev/null
  local p1; p1=$(sgdisk -i 1 "$dst")
  local start guid name; start=$(sgdisk -i 1 "$dst" | awk '/First sector/ {print $3}')
  guid=$(echo "$p1" | awk -F': ' '/unique GUID/ {print $2}'); name=$(echo "$p1" | awk -F"'" '/Partition name/ {print $2}')
  log "growing $name to the end of the disk"
  sgdisk -d 1 -n "1:$start:0" -t 1:8300 -u "1:$guid" -c "1:$name" "$dst" >/dev/null
  partprobe "$dst" 2>/dev/null || blockdev --rereadpt "$dst" || true; sleep 2
  local espn esp mnt; espn=$(sgdisk -p "$dst" | awk '$NF == "EFI-SYSTEM" {print $1}')
  case $dst in *[0-9]) esp=${dst}p$espn ;; *) esp=$dst$espn ;; esac   # nvme0n1p12 vs sda12
  mnt=$(mktemp -d); mount "$esp" "$mnt"
  sed -i 's/^set boot_source=.*/set boot_source=internal/' "$mnt/churro/env.cfg"; umount "$mnt"; rmdir "$mnt"
  log "done. Reboot, pick the disk in the UEFI boot menu (Secure Boot off)."
}

# auto <in.bin> <out.img> [--gfx mesa|native|soft] [--kernel-profile generic]:
# prepare everything (tools/prepare.sh) and build with the recommended defaults.
cmd_auto() {
  local in=$1 out=$2; shift 2
  local gfx=mesa kprof=generic packs=virt,gpu,storage
  while [ $# -gt 0 ]; do case $1 in
    --gfx) gfx=$2; shift 2 ;; --kernel-profile) kprof=$2; shift 2 ;;
    --packs) packs=$2; shift 2 ;;   # module packs from prepare.sh: virt,gpu,storage[,wifi]
    *) die "unknown option $1" ;; esac; done
  bash "$HERE/tools/prepare.sh" "$in" "$kprof"
  local envf; envf=$(ls -t "${CHURRO_CACHE:-/var/cache/churro}"/prepared-*.env | head -1)
  # shellcheck disable=SC1090
  . "$envf"; export CHURRO_MESA CHURRO_MESA_SYSROOT
  local margs=() p; for p in ${packs//,/ }; do
    [ -d "$CHURRO_PACK_DIR/$p" ] || die "no module pack '$p' in $CHURRO_PACK_DIR"; margs+=(--modules "$CHURRO_PACK_DIR/$p"); done
  CHURRO_EXTRA_ARGS="androidboot.churro.gfx=$gfx ${CHURRO_EXTRA_ARGS:-}" \
    cmd_build "$in" "$out" --kernel "$CHURRO_KERNEL" --features security-software,firmware-lockdown,gfx-mesa,debug-log "${margs[@]}"
}

case ${1:-} in
  auto) shift; [ $# -ge 2 ] || die "usage: churro.sh auto <in.bin> <out.img> [--gfx mesa|native|soft]"; cmd_auto "$@" ;;
  build) shift; [ $# -ge 2 ] || die "usage: churro.sh build <in.bin> <out.img> [opts]"; cmd_build "$@" ;;
  install) shift; [ $# -eq 2 ] || die "usage: churro.sh install <churro.img> <disk, e.g. /dev/nvme0n1>"; cmd_install "$@" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
