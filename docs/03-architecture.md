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
  Small built-in source fixes live in `kmod/patches/*.patch` (applied copies recorded in
  `<src>/.churro-applied`, edited/removed patches reversed automatically; the kernel cache dir is
  keyed on profile + patches + build script):
  - `drm-remove-firmware-fb` — DRM core removes the firmware framebuffer (simpledrm) when any PCI
    display driver registers. Google's prebuilt xe never does it (no EFI framebuffer on
    Googlebooks), so simpledrm stayed and hwcomposer used it as the primary display (black screen).
    Side effect: xe has no fbdev, so the on-screen debug log stops when xe loads (~5 s); the
    CHURRO-LOG files are unaffected. The GPU then reuses simpledrm's `card0`, which needs
    ueventd's parallel main loop off (gfx-mesa): otherwise simpledrm's late "remove" can delete
    the new `/dev/dri/card0` and the composer boots headless.
  - `sysfb-disable-any-gpu` — also drop it when the framebuffer belongs to *another* GPU
    (hybrid laptops with the boot framebuffer on an undriven dGPU).

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
* `firmware-lockdown` (default, **safety-critical — never drop it for a PC build**) — Googlebooks
  update their own firmware from Android automatically and without asking. Removed: `flashrom`,
  `futility`, `vpd`, `fwtool`, `elogtool` + the futility executor HAL (the VPD executor stays,
  toothless without `vpd`: system_server blocks on it and would be killed); `crossystem` becomes a
  no-op stub that accepts writes without touching anything (the boot-control HAL's
  markBootSuccessful needs `crossystem fw_result=success` to succeed, else "Checkpoint commit
  failed" reboots every boot), and
  `fwupd` + its boot-time blocking update script + cabinets (it runs at *every* boot with
  `ApprovalRequired=false` against the public LVFS and Googlebook peripheral cabinets: on a PC it
  could reflash SSDs, USB hubs, cameras, docks, Thunderbolt controllers). Independently,
  `churro.sh` always strips `spi-intel.writeable=1` / `ignore_protection_status=1` and blacklists
  the SPI flash drivers (`spi_intel`, `spi_intel_pci`) and the TPM drivers (`tpm`, `tpm_tis*`,
  `tpm_crb`): the image's `gscutil` and `check_tpm_clear` send Google-security-chip commands to
  `/dev/tpm0` at every boot, and on a PC that is the TPM Windows/BitLocker depends on. It also
  adds `efi_pstore.pstore_disable=1` (no kernel crash dumps into the PC's UEFI NVRAM), and the
  feature strips board tuning from the vendor rc files (`init.ruby.rc` writes the Lenovo
  laptop's RAPL power limits and a TCC offset to whatever CPU it runs on).
  There is deliberately no switch to turn any of this back on.
* `firmware-extra` (default) — firmware the image's own drivers declare (`modinfo -F firmware` over
  all vendor_dlkm/system_dlkm modules, plus `extra.txt` for runtime-built names like Intel
  Bluetooth) but the image lacks, fetched from a pinned linux-firmware tag
  (`CHURRO_LINUX_FIRMWARE`, cached in `$CHURRO_CACHE/linux-firmware-<tag>`) into
  `/vendor/firmware`, labelled like that dir. Patch scripts get `CHURRO_SUPER`/`CHURRO_HERE`/
  `EROFS_BIN` so they can read other LP partitions.
* `gfx-minigbm` (default) — the graphics buffer allocator libraries (`libminigbm_gralloc.so`,
  `libgbm.so`) rebuilt from AOSP `external/minigbm` (android17-release, the source of Google's
  own build) by `gfx/build-minigbm.sh` with the NDK, plus `gfx/minigbm-patches/`. Google's build
  rejects every GPU missing from its ID tables; ours asks the xe kernel driver for the GPU's
  graphics IP version instead (any Intel Xe GPU works). Google's allocator service, mapper and
  gralloc0 module stay and load our libraries: they're linked against the image's own libc++
  (platform `std::__1` ABI) and the build refuses to install them unless every symbol the image's
  binaries take from Google's versions is present. Written in place (labels kept).
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
  the logger writes a "full" note and stops (a normal boot is ~1–3 MiB). A second child streams
  Android's log into `logcat.log` the way logcat does: it connects to logd's reader socket
  (`/dev/socket/logdr`, reached via `/proc/1/root` because the logger lives in its own mount
  namespace), sends `stream lids=0,1,3,4` (main, radio, system, crash) with a 16 MiB receive
  buffer (logd drops slow readers), and writes `HH:MM:SS.mmm pid tid P tag: msg` lines (UTC). The child stays in the `kernel` SELinux
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
