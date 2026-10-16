#!/usr/bin/env bash
# !! SAFETY-CRITICAL: never drop this feature from a build meant for non-Googlebook PCs. !!
# Googlebooks update their own firmware from Android, automatically and without asking:
#  - coreboot/EC/VPD: flashrom, futility, vpd, crossystem, fwtool, elogtool + futility executor HAL;
#  - fwupd: starts on every boot and runs a blocking, no-approval update pass against the public
#    LVFS service and the image's own cabinets (Googlebook touchscreen/camera/USB-hub firmware).
#    On a normal PC it can match and reflash SSDs, USB hubs, cameras, docks, Thunderbolt...
# On any other PC these can brick hardware. churro.sh additionally strips spi-intel.writeable=1 and
# blacklists the SPI flash + TPM drivers (the TPM belongs to the PC's own OS, e.g. BitLocker).
# There is deliberately no switch to re-enable any of this.
#
# The VPD *executor* HAL stays: system_server (DesktopRepairModeService) blocks forever in
# waitForService() on it and the watchdog kills system_server -> boot loop. It is only a binder
# wrapper that runs /vendor/bin/vpd (no flash access of its own); with `vpd` removed every call
# fails, which system_server catches ("Failed to read or parse post manufacturing config").
#
# crossystem is replaced by a no-op stub (crossystem-stub.c), not deleted: the boot-control HAL
# needs `crossystem fw_result=success ...` to exit 0 or every boot ends in "Checkpoint commit
# failed" -> reboot. Written in place over the original so it keeps its SELinux label
# (firmware_tool_exec: the HAL's domain transition) and mode.
set -euo pipefail
T=$1
S=$(mktemp); ${CC:-cc} -static -Os -s -Wall -o "$S" "$(dirname "$0")/crossystem-stub.c"
"$S" fw_result=success fw_try_count=0 && ! "$S" mainfw_act && ! "$S" || { echo "crossystem stub self-check failed" >&2; exit 1; }
[ ! -e "$T"/bin/crossystem ] || cat "$S" > "$T"/bin/crossystem; rm -f "$S"
rm -f "$T"/bin/{flashrom,futility,vpd,fwtool,elogtool} \
      "$T"/bin/hw/vendor.google.desktop.futility-executor \
      "$T"/etc/init/{futility-executor,desktop_kernel_max_rollforward_boot}.rc \
      "$T"/etc/vintf/manifest/vendor.google.desktop.futility-executor.xml \
      "$T"/bin/{fwupd-binder,fwupd_blocking_update,fwupdmgr} "$T"/etc/init/fwupd.rc
rm -rf "$T"/usr/share/fwupd "$T"/etc/fwupd
[ ! -e "$T"/bin/vpd ] || { echo "vpd still present" >&2; exit 1; }   # the executor must stay toothless
echo "   vendor: firmware updaters removed (flashrom, futility, vpd, fwtool, elogtool, fwupd); crossystem = no-op stub"
