#!/usr/bin/env bash
# !! SAFETY-CRITICAL: never drop this feature from a build meant for non-Googlebook PCs. !!
# Googlebooks update their own firmware from Android, automatically and without asking:
#  - coreboot/EC/VPD: flashrom, futility, vpd, crossystem, fwtool, elogtool + executor HALs;
#  - fwupd: starts on every boot and runs a blocking, no-approval update pass against the public
#    LVFS service and the image's own cabinets (Googlebook touchscreen/camera/USB-hub firmware).
#    On a normal PC it can match and reflash SSDs, USB hubs, cameras, docks, Thunderbolt...
# On any other PC these can brick hardware. churro.sh additionally strips spi-intel.writeable=1 and
# blacklists the SPI flash + TPM drivers (the TPM belongs to the PC's own OS, e.g. BitLocker).
# There is deliberately no switch to re-enable any of this.
set -euo pipefail
T=$1
rm -f "$T"/bin/{flashrom,futility,vpd,crossystem,fwtool,elogtool} \
      "$T"/bin/hw/vendor.google.desktop.futility-executor \
      "$T"/bin/hw/vendor.google.desktop.vpd_executor.vpd-executor \
      "$T"/etc/init/{futility-executor,vpd-executor,desktop_kernel_max_rollforward_boot}.rc \
      "$T"/etc/vintf/manifest/vendor.google.desktop.{futility-executor,vpd_executor.vpd-executor}.xml \
      "$T"/bin/{fwupd-binder,fwupd_blocking_update,fwupdmgr} "$T"/etc/init/fwupd.rc
rm -rf "$T"/usr/share/fwupd "$T"/etc/fwupd
echo "   vendor: firmware updaters removed (flashrom, futility, vpd, crossystem, fwtool, elogtool, fwupd)"
