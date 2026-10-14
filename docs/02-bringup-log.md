# 02 — Bring-up log (QEMU, Lenovo Googlebook 15 "ruby" image)

Test rig: WSL2 Ubuntu 24.04 on the dev laptop (Core Ultra 7 255HX), QEMU q35 + OVMF + KVM,
NVMe disk, `tools/qemu-test.sh`. Image build `CL3B.260622.271.R1 / 16452207`.
Kernel `6.18.21-android17-5-g3938c8d97142-ab16302624` (official GKI, ci.android.com build 16302624,
branch `aosp_kernel-common-android17-6.18-2026-06`).

## Where we are (2026-10-14)

Converted image boots in QEMU **with the stock GKI kernel and with the Churro kernel** up to:
first-stage → second stage → apexd → vold (FBE `/data` encrypted with software KeyMint) →
keystore2 → zygote → **system_server** → **SurfaceFlinger loads Mesa** (`MESA: Using gralloc0 CrOS
API`). SurfaceFlinger then crashes inside softpipe (`sp_find_cached_tile`) on QEMU's 2D virtio-gpu:
gralloc (minigbm, virtio_gpu backend) buffers can't be CPU-mapped by Mesa's kms_swrast. This is a
QEMU-only path; on real Intel hardware the path is iris + minigbm i915 (hardware rendering).

## Milestones

| # | Result | What made it work |
|---|---|---|
| 1 | GRUB from the image's ESP boots the GKI kernel | ESP was empty; `lib/esp.sh` formats it, standalone GRUB + kernel + initrd |
| 2 | First stage mounts `super` from *any* disk | `androidboot.boot_part_uuid=<ESP PARTUUID>` (GRUB `probe --part-uuid`) |
| 3 | Second stage runs | bootconfig trailer (`lib/bootconfig.sh`): slot `_a`, `verifiedbootstate=orange`, `vbmeta.device_state=unlocked`, `force_normal_boot=1` |
| 4 | Shell on ttyS0 (`ap:/ $`, uid shell + log group) | stock `apgetty` – the main debug channel (`tools/qemu-serial.sh`) |
| 5 | Patched partitions boot | `vbmeta` flags=3 + EROFS repack keeping xattrs (`lib/repack.sh`) |
| 6 | Extra first-stage modules load | Churro ramdisk compressed as **lz4 legacy** (an uncompressed cpio after the vendor's lz4-legacy ramdisks is silently dropped: "Decoding failed") |
| 7 | /data mounts, keystore2 + zygote + system_server run | feature `security-software`: AOSP software KeyMint (from the public Android 17 emulator image) + Trusty/GSC HALs/VINTF removed |
| 8 | Churro kernel loads the image's own prebuilt modules | same source/config/toolchain + `KBUILD_GENDWARFKSYMS_STABLE=1` → `module_layout` and `drm_dev_register` CRCs identical to Google's `vmlinux.symvers` |
| 9 | simpledrm on the UEFI framebuffer, i915/virtio-gpu/vgem/ahci as modules | `kmod/profiles/generic.conf` |
| 10 | Mesa 26.2.4 for Android built from source (NDK r28c) | `gfx/build-mesa.sh`: host mesa_clc, static libdrm/expat (sphal namespace) |
| 11 | SurfaceFlinger loads Mesa | feature `gfx-mesa` (driver chosen at boot: `androidboot.churro.gfx=native|mesa|soft`) |
| 12 | `churro.sh auto` prepares everything from scratch (sources, toolchains, kernel, packs, Mesa) | `tools/prepare.sh`, cache in `/var/cache/churro` |
| 13 | Kernel + init log on screen ("debug console" entry) | `VT FB FRAMEBUFFER_CONSOLE DRM_FBDEV_EMULATION` in the generic profile; kABI unchanged |
| 14 | Optional Atheros Wi-Fi (ath9k) | `wifi` pack: in-tree cfg80211/mac80211/ath9k (see problems: replaces the vendor iwl7000 stack) |

## Problems hit (and fixes)

- **Bootconfig garbled** – `printf "\\x.."` in double quotes; `le32` now uses single quotes.
- **GRUB fell to a shell** – embedded stub could not find its partition; added `search --file` fallback.
- **`Skipping insecure file` for our .rc** – Windows checkout files are 0777/uid 1000; overlays are installed root:root 0644/0755.
- **`apexd-bootstrap: Can't open /vendor/apex: Permission denied` → reboot loop** – (1) `cp -a` rewrote metadata of existing dirs; (2) `mkfs.erofs --file-contexts` with Android file_contexts on host libselinux **drops every label**. Now: keep xattrs from `fsck.erofs --xattrs` (erofs-utils ≥1.8, `tools/build-erofs-utils.sh`), label new files explicitly / like a sibling.
- **`servicemanager` can't read manifest.xml (unlabeled)** – a patch script used `mv` (new inode, no xattr); edit files in place.
- **Vendor rc cannot override a system_ext service** ("across the treble boundary") – overrides live in `system_ext/etc/init/zz-churro-*.rc`.
- **Protected VM: `failed to create vm: Invalid argument`** – no pKVM. In QEMU pKVM wants VT-d (`DMAR: pkvm: Failed to initialize DMAR table`); with `intel-iommu,aw-bits=48` it reaches `Failed to initialize pKVM hyp on CPU0: -95` (nested VMX, QEMU itself runs under Hyper-V). The Churro kernel even hangs in pKVM init under QEMU → `kvm-intel.pkvm=0` is default with `security-software`.
- **Non-protected Trusty VM boots, but the KeyMint TA never answers** – needs pvmfw's DICE chain and the GSC (gscd → `/dev/tpm0`, Ti50 vendor commands; swtpm is not enough).
- **keystore2 has no software fallback for the TEE level** (`Failed to construct mandatory security level TEE`) → ship AOSP's software KeyMint. Its binary name matches an existing Googlebook sepolicy label (`hal_keymint_default_exec`) – no policy change needed.
- **i915 as module against the stock GKI**: 137 unresolved symbols (KMI-trimmed exports) → Churro kernel.
- **Churro kernel: `disagrees about version of symbol module_layout`** – fixed by keeping `LOCALVERSION_AUTO` (→ `MODULE_SCMVERSION`) and building with `KBUILD_GENDWARFKSYMS_STABLE=1`.
- **Kernel build**: Ubuntu pahole 1.25 breaks BTF (`tools/build-pahole.sh` → 1.31); bindgen must use the Android clang's libclang (`LIBCLANG_PATH`).
- **Unsigned virtio_pci copies refused by the stock GKI** ("Cannot use protected symbol") – with the stock kernel only add modules that aren't already GKI modules.
- **Mesa**: meson ≥1.4 (venv), `mesa_clc`/`vtn_bindgen2` host tools (LLVM 18 + libclc), libdrm/expat must be static (Android's sphal namespace can't see vendor libdrm/libexpat).
- **QEMU display stays on the boot text** – with plain `virtio-gpu-pci`, simpledrm keeps the firmware framebuffer; `-device virtio-vga` makes virtio-gpu kick simpledrm out.
- **minigbm in the image has no `vgem`/simpledrm backend** → the "software rendering on any GPU" path needs our own gralloc (open).
- **Churro kernel: `zram: Cannot use protected symbol zs_malloc`** (no zram swap) – Google's modpost marks GKI exports "protected" inside the prebuilt modules (zsmalloc.ko); our kernel couldn't verify Google's per-build module signing key, so zram counted as unsigned. Fix: `tools/extract-certs.sh` pulls the X.509 cert out of the image's vmlinux and the Churro kernel trusts it (`SYSTEM_TRUSTED_KEYS`). (`MODULE_SIG_PROTECT` is `def_bool y`, `-d` doesn't stick – and wouldn't help: the flags live in the modules.)
- **The image's Wi-Fi stack is out-of-tree** – `cfg80211.ko`/`mac80211.ko` on vendor_dlkm are Intel's iwl7000 backport (module name `iwl7000_mac80211`, no `intree`). Other Wi-Fi drivers can't link against it, so the `wifi` pack ships the in-tree stack; with it the vendor iwlmld/mac80211 fail to load (`Unresolved symbol wiphy_locked_debugfs_read`).
- **First-stage modules can't load firmware** (`/vendor/firmware` isn't mounted yet) → packs only take firmware-less drivers (ath9k yes; iwlwifi/ath10k/rtw88 no).
- **Older CPUs: `traps: init[1] trap invalid opcode` → `Attempted to kill init`** (HP AiO video). The faulting instruction in first-stage `init` is `vgf2p8affineqb` (GFNI); `init` and `surfaceflinger` also use AVX-VNNI/VAES/SHA. Googlebook userspace is built for recent Intel (≈ Alder Lake / 12th gen and newer); the other Intel Googlebook images share the same build. Not fixable without instruction emulation.
- **Every boot ran as an unfinished update** (`vdc checkpoint needsCheckpoint` → dm-bow on /data; on a re-used 4 GB /data: `dm-bow: Unable to find free space to back up to` → EXT4 errors=panic). The boot HAL keeps ChromeOS-style slot flags in the **vbmeta_a/_b GPT attributes**; recovery images ship slot B marked successful and A not, and we boot A. `churro.sh build` now marks A (priority 15 + successful) and clears B.
- **No logs on serial-less machines** → feature `debug-log` (boot.log on the CHURRO-LOG partition). Gotchas: no devtmpfs in GKI (logger makes its own nodes); first-stage init moves every mount it sees and aborts on failure (logger uses a private mount namespace); the logger stays in the `kernel` SELinux domain (rules added, precompiled policy dropped → init compiles it, ~0.5 s).
- **MSI (Arrow Lake HX) froze during second-stage module loading** – boot.log shows `intel_vpu: Failed to request firmware: -2` → `NPU not idle during power down` → probe failed, then nothing (whole machine, not just the display). The image only ships Panther Lake NPU firmware → `intel_vpu` blacklisted by default (`CHURRO_NPU`).
- **boot.log unreadable in Windows (0x80070570)** after a real-hardware hang: directory size 157755 B but FAT chain only 147456 B (the stick lost/reordered the last metadata writes despite fsync). Text was intact on disk and recovered by raw read. Fix: preallocated fixed-size log files, written in place.
- **The image can write the BIOS flash**: vendor cmdline has `spi-intel.writeable=1 spi-intel.ignore_protection_status=1` and the vendor partition carries flashrom/futility/vpd/crossystem (run after boot_completed, which we never reached). Now stripped/blacklisted/removed (`firmware-lockdown`).
- **Downloads from googlesource `+archive` get cut off** (`curl: (18)`) and can't resume → `fetch_tar` retries and only publishes a directory once fully extracted.
