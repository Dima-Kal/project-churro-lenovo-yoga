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
 │ super: system/vendor/...    │ ──► EROFS repack of vendor_dlkm / vendor / system_ext by "features"
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
  **Distro module set** (profile `DISTRO_*`): every option a pinned Arch Linux kernel config
  builds as a module, if its Kconfig lives in a consumer-PC driver directory and it isn't denied
  (~3900 options → ~3000 extra modules, installed by `drivers-extra`). Modules only: built-in
  options are never weakened, and options a module would switch on that core headers test
  (struct fields in netdevice.h, i2c.h, sched.h, …; they'd change hundreds of GKI CRCs) are kept
  off by leaving out whatever selects them (select chains followed automatically: e.g. iavf →
  NET_SHAPER, two I2C bus drivers → I2C_SLAVE).
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
  - `nouveau-hybrid-guard` — nouveau binds only if no other display controller exists
    (discrete-only laptops, desktops without iGPU); hybrid machines keep their iGPU stack.
    `nouveau.hybrid=1` overrides.
  - `nouveau-dsc-off` — turns off DSC the firmware left enabled (head + panel); nouveau
    never compresses, so an inherited DSC state garbles the picture or stalls the display.
  - `vt-no-ctrl-alt-del` — the VT keyboard handler (comes with fbcon) hard-reset the machine on
    Ctrl+Alt+Del (no shutdown, no sync); now it only signals init, which ignores it.
  - `nouveau-up-01..09` — mainline GB20x / GSP-RM 570 display fixes, unchanged (r570
    `DP_CONFIG_STREAM` size, GB20x head state, vblank vector, HDMI packets; with prerequisites).

  **When the kernel source changes** (a newer Googlebook image = newer GKI commit, or newer
  nouveau backported): every patch is re-applied by `build-kernel.sh`, and a patch that doesn't
  apply stops the build — on purpose, nothing is kept blindly. For each failing patch:
  - `nouveau-up-*`: copies of mainline commits (the `From <sha>` header names the commit). If the
    new source already contains that commit, delete the patch; otherwise rebase it.
  - `nouveau-dsc-off`: needed until nouveau itself turns off (or supports) DSC. Check the new
    source: if `headc57d_mode()`/`headca7d_mode()` (or nouveau generally) now program
    `HEAD_SET_DSC_CONTROL`, drop the patch. If not, rebase it, and **extend it to every new display
    class**: a new GPU generation brings a new `dispnv50/head<class>.c` (e.g. `headca7d.c` came with
    GB20x); add the same DSC_CONTROL/DSC_PPS_CONTROL = 0 writes to its `*_mode()` and the two method
    defines to its class header, with offsets/head stride from NVIDIA's published
    `cl<class>.h` (open-gpu-kernel-modules, `src/common/sdk/nvidia/inc/class/`). The sink half
    (`DP_DSC_ENABLE` in `nouveau_dp.c`) is GPU-independent. Without it, laptops whose firmware
    enables DSC (high-refresh panels) show a squeezed, noisy strip (docs/02).
  - the others (`drm-remove-firmware-fb`, `sysfb-disable-any-gpu`, `nouveau-hybrid-guard`,
    `vt-no-ctrl-alt-del`): Churro behaviour, not upstream fixes — rebase them, their header says
    why they exist.

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
* `drivers-extra` (default) — distro-like driver coverage: every module of our kernel build the
  image doesn't have (the profile's distro module set, nouveau, …; ~3000) goes into vendor_dlkm,
  where ueventd loads modules by device alias, so a machine only loads what matches its hardware.
  ABI gate: `depmod -e -E Module.symvers` over the image's modules (vendor_dlkm + system_dlkm) +
  ours; a module with an unknown symbol or a CRC mismatch against Google's modules is left out
  (with everything that needs it), and a Google module is replaced by our build only if ours
  exports everything Google's does with identical CRCs (drm_ttm_helper: + the fbdev console).
  `skip.txt`: modules never added (i915: opt-in pack).
* `firmware-extra` (default) — firmware the image's drivers need but the image lacks, installed
  into `/vendor/firmware` (labelled like that dir) from a pinned linux-firmware release
  (`CHURRO_LINUX_FIRMWARE`; tarball downloaded and unpacked once into
  `$CHURRO_CACHE/linux-firmware-<tag>`): names every vendor_dlkm/system_dlkm module declares
  (`modinfo -F firmware`), every file WHENCE lists under a shipped driver (catches names drivers
  build at runtime: board files, per-laptop amplifier tunings), and `extra.txt`. Plus two things
  outside linux-firmware: Intel's audio DSP firmware/topologies (sof-bin release, `CHURRO_SOF`)
  and the Wi-Fi regulatory database (wireless-regdb, `CHURRO_REGDB`). Patch scripts get
  `CHURRO_SUPER`/`CHURRO_HERE`/`EROFS_BIN` so they can read other LP partitions. Names
  linux-firmware only creates when installed (WHENCE `Link:`) are resolved and become hardlinks to
  one copy; `skip.txt` lists globs never installed (NVIDIA GSP 535). vendor_dlkm is repacked
  before vendor, so modules drivers-extra adds get their firmware too.
* `gfx-minigbm` (default) — the graphics buffer allocator libraries (`libminigbm_gralloc.so`,
  `libgbm.so`) rebuilt from AOSP `external/minigbm` (android17-release, the source of Google's
  own build) by `gfx/build-minigbm.sh` with the NDK, plus `gfx/minigbm-patches/`. Google's build
  rejects every GPU missing from its ID tables; ours asks the xe kernel driver for the GPU's
  graphics IP version instead (any Intel Xe GPU works), and on nouveau allocates real buffers
  (`NOUVEAU_GEM_NEW`, VRAM) instead of dumb buffers, which render nodes refuse. Google's allocator service, mapper and
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
* `gpu-nouveau` (default) — NVIDIA GPUs (nouveau.ko itself comes with drivers-extra):
  `nouveau.atomic=1` for drm_hwcomposer, and wildcard SELinux labels so apps can read any GPU's
  PCI ID files (Mesa's device enumeration). Details: docs/05.
* `gfx-mesa` (default) — Mesa built with the NDK (`gfx/build-mesa.sh`: iris/crocus/nouveau/zink/
  virgl/softpipe + NVK, hasvk/radv on request) and the boot-time stack selection
  (`androidboot.churro.gfx`, set by GRUB from PCI: native / nouveau / mesa / soft).

### 5. Installer
The recovery image already has the installed layout, so `churro.sh install <img> <disk>` (from
any Linux live) writes the image, moves the backup GPT to the disk end, grows userdata over the
free space and sets `boot_source=internal` on the ESP. TODO: an installer inside the booted image.

## Updating the driver set and firmware (checklist, no prior context needed)

What it is: the Churro kernel is Google's GKI rebuilt from source (§2). On top of the GKI config
it builds, as modules, the driver part of a Linux distro's config ("distro module set"), and the
build installs those modules plus their firmware into the image. Everything is pinned, so an
update means bumping pins, rebuilding and reading what the build reports. Nothing is downloaded
unpinned.

Files involved (each has comments explaining the why):
| File | Role |
|---|---|
| `kmod/profiles/generic.conf` | `DISTRO_CONFIG` (URL of the pinned distro config), `DISTRO_DIRS` (regex: Kconfig file locations whose modules are taken), `DISTRO_DENY` (regex: symbols never taken), optional `DISTRO_BUILTIN_OK` (space-separated core options checked to be harmless) |
| `kmod/build-kernel.sh` | the `if [ -n "${DISTRO_CONFIG:-}" ]` block: picks the symbols, adds them as `=m`, keeps core-struct options off (follows `select`/`imply` chains), refuses to weaken built-ins |
| `tools/prepare.sh` | kABI check after the build: all GKI export CRCs must equal Google's `vmlinux.symvers`, else the kernel is rejected; copies `Module.symvers` into the kernel cache dir |
| `features/drivers-extra/patch-vendor_dlkm.sh` (+ `skip.txt`) | installs every module of our build that the image lacks into vendor_dlkm, after a `depmod -e -E` ABI check against the image's own modules; prints what it left out and why |
| `features/firmware-extra/patch-vendor.sh` (+ `skip.txt`, `extra.txt`) | firmware for all shipped modules: pinned linux-firmware release (`CHURRO_LINUX_FIRMWARE`), sof-bin (`CHURRO_SOF`), wireless-regdb (`CHURRO_REGDB`) |

Steps:
1. Find the image's kernel version: the kernel release string printed by `prepare.sh`
   (e.g. `6.18.21-android17-…`), or `kernel.release` in the kernel cache dir.
2. Distro config: pick a config for the **same major.minor kernel version** (a newer series has
   different Kconfig symbols). Arch Linux keeps one per release tag:
   `https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw/<tag>/config`, tags
   look like `6.18.9.arch1-1` (list them on that repo's tags page; not every point release has
   one). Put the URL in `DISTRO_CONFIG`. Any distro's full kernel config works the same way
   (Debian/Fedora), as long as the version matches.
3. Firmware pins (defaults at the top of `features/firmware-extra/patch-vendor.sh`, or override
   with the env vars): linux-firmware = a release tag present on
   `https://cdn.kernel.org/pub/linux/kernel/firmware/` (`linux-firmware-<YYYYMMDD>.tar.xz`);
   sof-bin = a release of `github.com/thesofproject/sof-bin` (version without the `v`);
   wireless-regdb = a `master-YYYY-MM-DD` tag of `git.kernel.org/…/wens/wireless-regdb.git`.
4. Rebuild: `sudo ./churro.sh auto <recovery.bin> <out.img>` (Linux or WSL, as root). Changing the
   profile changes the kernel cache key, so the kernel is rebuilt (incremental when the build
   tree in `$CHURRO_CACHE/src-<build>/common/out-kernel-generic` still exists).
5. If the build stops, the message says why:
   - `distro modules: can't tell which module enables X` → a new module turns on core option X
     (one tested in core headers, so it would change GKI struct layouts) other than through
     `select`. Find the module(s) whose Kconfig depends on/defaults X and add them to
     `DISTRO_DENY`; or, if X only changes function declarations and no struct (read the
     `#ifdef CONFIG_X` sites in `include/`), add X to `DISTRO_BUILTIN_OK`.
   - `distro modules would weaken built-in options` → a taken module lowers a built-in (`=y`)
     option to `=m` (listed). Find the taken symbol it depends on and add that to `DISTRO_DENY`.
   - `kABI broken … CRC differs: <symbol>` → some built-in option still changed a GKI type. Diff
     `.config.predistro` against `.config` in the kernel build dir (non-`=m` lines), find the new
     `=y` options tested in `include/` (`grep -rlw CONFIG_X include/`), deny what enables them.
     Never "fix" it by accepting different CRCs: Google's prebuilt modules would stop loading.
6. Read the build log: `drivers-extra` prints how many modules it added and every module it left
   out (`needs unknown symbol` / `disagrees about version of symbol`). Left-out modules are
   normal (they need exports Google's own module builds don't have); they're not errors.
   `firmware-extra` prints how many files/MiB it added.
7. Test: the QEMU smoke test (`tools/` helpers, see `docs/02`) and real hardware with the GRUB
   "debug" entry (boot.log/logcat.log on the CHURRO-LOG partition). A misbehaving driver on one
   machine: add its module name to `features/drivers-extra/skip.txt`.
8. Record what changed and why in `docs/02-bringup-log.md` and the status in
   `docs/05-hardware-support.md`.

Rules that must hold whatever is changed: built-in kernel options stay identical except for
harmless additions; the kABI check passes with 0 differences; safety exclusions stay in
`DISTRO_DENY`/`DISTRO_DIRS` (TPM, SPI flash/MTD, watchdogs, EFI/firmware drivers, NPU — see the
safety section of `docs/05`).

## Why this is simpler than Croissant in some places and harder in others
* Simpler: no donor *system* image, no root-fs surgery for drivers on Intel Gen12+; Android's
  GKI/vendor split lets us add drivers as modules or rebuild the very same kernel.
* Harder: Android's security model is hardware-anchored (pKVM + DICE + GSC) and SELinux is
  enforcing on a user build — every change must keep labels intact and stay inside existing
  policy.
