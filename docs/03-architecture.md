# 03 — Churro architecture (how the conversion works)

Goal: take Google's signed Googlebook recovery image and turn it, locally, into something that
boots and installs on generic x86_64 UEFI PCs. Nothing Google-owned is redistributed; every extra
component is either built from public source or downloaded from Google's public servers by the
script (same model as Croissant downloading ChromeOS recovery images).

## Layers

```
 recovery.bin (Google)                       Churro adds
 ┌────────────────────────────┐
 │ EFI-SYSTEM (empty)          │ ◄── GRUB + kernel + initrd + grub.cfg/env.cfg   (lib/esp.sh)
 │ boot_a      GKI kernel      │ ──► reused, or replaced by a Churro kernel        (kmod/)
 │ vendor_boot_a ramdisks+cmd  │ ──► reused + Churro ramdisk (module packs) + bootconfig
 │ init_boot_a generic ramdisk │ ──► reused
 │ vbmeta_a                    │ ──► flags=3 (verity off) when partitions are patched
 │ super: system/vendor/...    │ ──► EROFS repack of vendor / system_ext by "features"
 │ userdata, metadata, misc …  │ ──► untouched (installer will reformat)
 └────────────────────────────┘
```

### 1. Bootloader replacement (always)
Googlebooks boot via coreboot/depthcharge; a PC has UEFI. Churro builds one initrd exactly like a
boot-image-v4 bootloader would (vendor ramdisk → dlkm ramdisk → generic ramdisk → extras →
bootconfig trailer) and boots the kernel's EFI stub through GRUB. GRUB passes the dynamic bits on
the kernel cmdline: `androidboot.boot_part_uuid` (lets first-stage init find `super` on whatever
disk we booted from) and `androidboot.boot_source=external|internal`.

### 2. Kernel: stock GKI or Churro kernel
* **Stock GKI** (`boot_a`): fine for Intel Gen12+ (the image's own xe/iwlwifi/SOF modules) and for
  VMs (virtio module pack from Google's matching `kernel_virt_x86_64` CI build).
* **Churro kernel** (`kmod/build-kernel.sh`): *the same source commit and config* (from Google's
  public GKI build manifest + the image's IKCONFIG), built with the exact toolchain (clang
  r584948c, Android rustc 1.91.1, bindgen 0.72.1, pahole 1.31), same release string, kABI-stable
  CRCs — so the image's prebuilt vendor/system modules still load — but **without KMI symbol
  trimming** and with extra drivers (`kmod/profiles/*.conf`): i915 for older Intel, simpledrm on
  the UEFI framebuffer for *any* GPU, AHCI/SATA, eMMC (sdhci-pci/acpi), virtio-gpu, fbcon, ath9k.
  Needed because the stock GKI exports only the KMI symbol list (an out-of-tree i915 build had 137
  unresolved symbols). It also trusts Google's GKI module signing cert (extracted from the image's
  vmlinux) so system_dlkm modules keep their "signed" status. `prepare.sh` refuses the kernel if
  any of the 4501 GKI export CRCs differs from Google's `vmlinux.symvers`.

### 3. Module packs (`--modules dir`)
Directory of `.ko` + `modules.load` (+ `modules.dep`). Added to the first-stage ramdisk, loaded
by Android's first-stage init before `super` is mounted (storage/GPU drivers). Made with
`tools/make-pack.sh` (dependency closure) or `tools/fetch-virt-pack.sh`. `prepare.sh` makes
`virt`, `gpu`, `storage` (default) and `wifi` (opt-in, `auto --packs virt,gpu,storage,wifi`).
First stage can't read `/vendor/firmware`, so packs hold only drivers that need no firmware.

### 4. Features (`--features a,b`)
`features/<name>/` may contain `<partition>/…` (files overlaid into that EROFS partition),
`patch-<partition>.sh` (scripted edits on the extracted tree) and `bootconfig` (extra lines).
SELinux labels are kept from the original image (extracted with `fsck.erofs --xattrs`) and new
files get a sibling's label or an explicit one.

* `security-software` (default) — replaces the Googlebook security stack (Trusty VM on x86 pKVM
  + pvmfw DICE + GSC/Ti50) with Android's software implementations: AOSP's software KeyMint
  (from Google's public Android 17 emulator image) as `android.hardware.security.keymint-service`
  (a name Googlebook's sepolicy already labels `hal_keymint_default_exec`), gatekeeperd's
  built-in SoftGateKeeper, Trusty/GSC HALs and VINTF entries removed, gscd disabled.
  → the Churro counterpart of Croissant's swtpm.
* `security-trusty-vm` (experimental) — keep Trusty, run the security VM non-protected or
  protected (`androidboot.churro.security_vm=`). Only useful on hardware where x86 pKVM works;
  the KeyMint TA still needs a DICE chain + GSC.
* `firmware-lockdown` (default) — Googlebooks flash their own coreboot/EC/VPD from Android. The
  build removes `flashrom`, `futility`, `vpd`, `crossystem`, `fwtool`, `elogtool` and their
  executor HALs; independently, `churro.sh` always strips `spi-intel.writeable=1` /
  `ignore_protection_status=1` from the kernel cmdline and blacklists `spi_intel`/`spi_intel_pci`,
  so the BIOS flash chip has no driver at all.
* NPU: `intel_vpu` is blacklisted unless `CHURRO_NPU=true` (top of `churro.sh`): the image only
  has Panther Lake NPU firmware and on Arrow Lake the failed probe froze the machine.
* `debug-log` (default) — boot log to a file you can read from Windows. The "debug" GRUB entries
  start `/churro/logger` (static, `features/debug-log/logger.c`) as `rdinit`: it forks a child
  (own mount namespace, invisible to first-stage init) that copies `/dev/kmsg` — kernel + Android
  init messages — into `boot.log` on the **CHURRO-LOG** partition (the unused KERN-A slot turned
  into a FAT32 basic-data partition; the ESP is hidden by Windows), fsync'ed per batch so a hang
  + power button keeps it; then execs the real `/init`. `boot.log`/`boot.prev.log` are created
  by the build at 64 MiB, filled with blank lines, and only overwritten in place (text ends at the
  first empty line; rotation copies in place too), so FAT and directory entries never change at
  boot — appending had left the FAT inconsistent after a power cut on a real stick. Full file →
  the logger writes a "full" note and stops (a normal boot is ~1–3 MiB). The child stays in the `kernel` SELinux
  domain, so the feature adds the needed rules to the vendor policy and drops the precompiled
  policy (init compiles it at boot). Feature hooks used: `build-ramdisk.sh`, `cmdline-debug`.
* graphics (WIP) — Mesa built with the NDK (`gfx/build-mesa.sh`: iris/crocus/virgl/softpipe +
  hasvk/radv) for GPUs the image's Intel-only ANGLE/ANV stack can't drive.

### 5. Installer
The recovery image already has the installed layout, so `churro.sh install <img> <disk>` (from
any Linux live) writes the image, moves the backup GPT to the disk end, grows userdata over the
free space and sets `boot_source=internal` on the ESP. TODO: an installer inside the booted image.

## Why this is simpler than Croissant in some places and harder in others
* Simpler: no donor *system* image, no root-fs surgery for drivers on Intel Gen12+; Android's
  GKI/vendor split lets us add drivers as modules or rebuild the very same kernel.
* Harder: Android's security model is hardware-anchored (pKVM + DICE + GSC) and SELinux is
  enforcing on a user build — every change must keep labels intact and stay inside existing
  policy.
