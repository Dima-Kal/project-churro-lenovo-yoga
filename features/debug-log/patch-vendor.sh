#!/usr/bin/env bash
# SELinux for the boot logger (logger.c): it starts before policy load, so it stays in the
# "kernel" domain, which may not read kmsg nor write vfat files. Add exactly that to the vendor
# policy and drop the precompiled policy so init compiles it on-device (a few seconds per boot).
set -euo pipefail
T=$1; S=$T/etc/selinux
V=$(cat "$S/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro debug-log: boot logger (kernel domain) -> CHURRO-LOG partition
(allow kernel_$V vfat_$V (dir (search getattr open read write add_name remove_name)))
(allow kernel_$V vfat_$V (file (getattr open read write append create setattr rename unlink ioctl lock)))
(allow kernel_$V vfat_$V (filesystem (mount getattr)))
(allow kernel_$V tmpfs_$V (dir (search getattr open read write add_name mounton)))
(allow kernel_$V tmpfs_$V (chr_file (getattr open read write ioctl)))
(allow kernel_$V tmpfs_$V (blk_file (create getattr open read write ioctl)))
(allow kernel_$V self (capability (sys_admin mknod)))
(allow kernel_$V sysfs_$V (dir (search getattr open read)))
(allow kernel_$V sysfs_$V (file (getattr open read)))
EOF
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256
echo "   vendor: SELinux rules for the boot logger, precompiled policy removed"
