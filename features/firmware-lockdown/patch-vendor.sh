#!/usr/bin/env bash
# Googlebooks update their own coreboot/EC/VPD firmware from Android (flashrom, futility, vpd,
# crossystem, elogtool + the executor HALs). On any other PC those must never touch the BIOS
# flash. churro.sh already strips spi-intel.writeable=1 from the kernel cmdline and blacklists
# the SPI flash driver; this removes the tools themselves (all ran only after boot_completed).
set -euo pipefail
T=$1
rm -f "$T"/bin/{flashrom,futility,vpd,crossystem,fwtool,elogtool} \
      "$T"/bin/hw/vendor.google.desktop.futility-executor \
      "$T"/bin/hw/vendor.google.desktop.vpd_executor.vpd-executor \
      "$T"/etc/init/{futility-executor,vpd-executor,desktop_kernel_max_rollforward_boot}.rc \
      "$T"/etc/vintf/manifest/vendor.google.desktop.{futility-executor,vpd_executor.vpd-executor}.xml
echo "   vendor: firmware flashing tools removed (flashrom, futility, vpd, crossystem, fwtool, elogtool)"
