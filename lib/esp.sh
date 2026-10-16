# shellcheck shell=bash
# Populate the image's (empty) EFI-SYSTEM partition with GRUB + kernel + initrd.
# Googlebooks boot through depthcharge, which never touches the ESP, so we own it.

# esp_build <esp block device> <stage dir with kernel, initrd.img> <vendor cmdline> <boot_source>
esp_build() {
  local dev=$1 stage=$2 vcmd=$3 bsrc=$4 mnt
  mkfs.vfat -n CHURRO "$dev" >/dev/null
  mnt=$(mktemp -d); mount "$dev" "$mnt"
  mkdir -p "$mnt/EFI/BOOT" "$mnt/churro"

  # Tiny embedded config: find the partition GRUB was loaded from, hand over to the editable cfg.
  local stub; stub=$(mktemp)
  cat > "$stub" <<'EOF'
regexp --set=1:root '^\(([^)]+)\)' "$cmdpath"
if [ -z "$root" -o ! -f "($root)/churro/grub.cfg" ]; then search --no-floppy --file --set=root /churro/grub.cfg; fi
echo "Churro: cmdpath=$cmdpath root=$root"
configfile "($root)/churro/grub.cfg"
EOF
  grub-mkstandalone -O x86_64-efi -o "$mnt/EFI/BOOT/BOOTX64.EFI" \
    --modules="part_gpt part_msdos fat normal linux echo all_video efi_gop efi_uga probe regexp configfile test cat efifwsetup search search_fs_file sleep" \
    --locales="" --fonts="" "boot/grub/grub.cfg=$stub"
  rm -f "$stub"

  cp "$stage/kernel" "$mnt/churro/kernel"
  cp "$stage/initrd.img" "$mnt/churro/initrd.img"

  # env.cfg is the per-install knob file (the installer flips boot_source to internal).
  cat > "$mnt/churro/env.cfg" <<EOF
set boot_source=$bsrc
set extra_args="${CHURRO_EXTRA_ARGS:-}"
set default=${CHURRO_DEFAULT_ENTRY:-0}
EOF
  cat > "$mnt/churro/grub.cfg" <<EOF
# Project Churro boot menu. Kernel cmdline = Googlebook vendor_boot cmdline + Churro additions.
set timeout=5
set default=0
source (\$root)/churro/env.cfg
probe --set=puuid --part-uuid (\$root)
set vcmd="$vcmd"

set base="\$vcmd androidboot.boot_part_uuid=\$puuid androidboot.boot_source=\$boot_source"
# debug: log on screen (fbcon) + serial, stop on errors instead of rebooting (panic=0; Android
# init's fatal errors become panics; the image's lockup watchdogs only warn), plus feature debug
# args (debug-log: boot.log on the CHURRO-LOG partition).
set dbg="console=tty0 console=ttyS1,115200 ignore_loglevel printk.devkmsg=on panic=0 androidboot.init_fatal_panic=true softlockup_panic=0 nmi_watchdog=nopanic ${CHURRO_DEBUG_ARGS:-}"

menuentry "Googlebook OS (Churro)" {
  linux (\$root)/churro/kernel \$base \$extra_args
  initrd (\$root)/churro/initrd.img
}
menuentry "Googlebook OS (Churro) - debug (log on screen + CHURRO-LOG/boot.log)" {
  linux (\$root)/churro/kernel \$base \$dbg \$extra_args
  initrd (\$root)/churro/initrd.img
}
# Intel xe display: DSB poll errors at init left the panel undetected (hwc went headless) on
# Arrow Lake. Flags go last so they override the vendor cmdline's xe.enable_psr=1.
menuentry "Googlebook OS (Churro) - debug, safe display (Intel: no DSB/PSR/DC states)" {
  linux (\$root)/churro/kernel \$base \$dbg \$extra_args xe.enable_dsb=0 xe.enable_psr=0 xe.enable_dc=0
  initrd (\$root)/churro/initrd.img
}
menuentry "Googlebook OS (Churro) - early debug (slow firmware console, for black screens)" {
  linux (\$root)/churro/kernel \$base \$dbg earlycon=efifb \$extra_args
  initrd (\$root)/churro/initrd.img
}
submenu "Graphics: other stacks" {
  menuentry "Mesa (older Intel iris/crocus, AMD, virgl)" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=mesa \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Mesa software rendering (slow, any GPU)" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=soft \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Googlebook native (Intel Gen12+: ANGLE on ANV)" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=native \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Mesa - debug" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=mesa \$dbg \$extra_args
    initrd (\$root)/churro/initrd.img
  }
  menuentry "Googlebook native - debug" {
    linux (\$root)/churro/kernel \$base androidboot.churro.gfx=native \$dbg \$extra_args
    initrd (\$root)/churro/initrd.img
  }
}
menuentry "UEFI firmware settings" { fwsetup }
EOF
  sync; umount "$mnt"; rmdir "$mnt"
}
