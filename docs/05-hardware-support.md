# 05 — Hardware support: status and roadmap

Goal: one generic image that boots on as many PCs as possible. This page tracks what each kind of
hardware needs, what Churro does today, and the planned next steps.

## ⚠ Safety: things that must stay disabled

The Googlebook image assumes it runs on a Googlebook and **updates firmware by itself, at boot,
without asking**. On any other PC each of these can damage hardware or lock you out of Windows:

| Image component | What it does on a Googlebook | Risk on a PC | Churro |
|---|---|---|---|
| `spi-intel.writeable=1` + flashrom/futility/vpd/crossystem/elogtool | rewrites coreboot, EC, VPD in the SPI flash | **bricked BIOS** | flag stripped, SPI drivers blacklisted, tools removed |
| `fwupd` + `fwupd_blocking_update` (every boot, `ApprovalRequired=false`, LVFS enabled) | updates touchscreen, camera, USB-hub firmware | reflashes any matching SSD, hub, dock, camera, Thunderbolt controller | removed |
| `gscutil`, `check_tpm_clear` (every boot, `/dev/tpm0`) | updates / resets the Google security chip | sends vendor/clear commands to the PC's TPM → **BitLocker recovery, lost TPM keys** | TPM drivers blacklisted (the tools find no TPM) |
| `efi_pstore` (built into the GKI kernel) | saves the kernel log into UEFI variables on every panic | fills the PC's NVRAM → some firmwares stop booting | `efi_pstore.pstore_disable=1` always on the cmdline (found via the GBRUNCH comparison, docs/06) |
| vendor fstab `voldmanaged` entries: `/devices/*/nvme/nvme[1-9]*`, `/devices/*/mmc_host*`, `/devices/*/usb*` | SD card / USB sticks as storage | Android mounts (rw) or offers to *format* a PC's second NVMe or internal eMMC holding Windows; already mounts our own boot stick's CHURRO-LOG | **OPEN** — fstab override planned (docs/06). Today's MSI is safe only because its NVMe is behind Intel VMD, which the kernel can't see |

Rules: these protections are in `churro.sh` and the default `firmware-lockdown` feature, and there
are deliberately no switches to undo them. Anyone changing this must re-check the vendor and
system init scripts for new updaters with each new Googlebook image (`grep -rE
'flashrom|futility|fwupd|gsc|tpm|crossystem' */etc/init`).

## Hard floor: the CPU

Googlebook userspace is compiled for recent Intel CPUs. First-stage `init` already executes GFNI
(`vgf2p8affineqb`); `surfaceflinger` uses AVX-VNNI (VEX), VAES, SHA. All Intel Googlebook images
share the same build, the other two are ARM (Snapdragon). Seen on real hardware: HP AiO (older
Intel) → `init trap invalid opcode` → panic; Asus T300FA (Broadwell) can't boot either.

| CPU | Status |
|---|---|
| Intel 12th gen (Alder Lake) and newer, N100/N200 | OK |
| AMD | probably Zen 5 (AVX-VNNI) — unverified |
| Older | needs instruction emulation in the Churro kernel (#UD trap → emulate GFNI/AVX-VNNI/VAES/SHA); research project, possibly slow |

## GPU

| GPU | Today | Next |
|---|---|---|
| Intel iGPU / Arc (Gen12+) | image's own `xe` + `firmware-extra` (GuC/HuC/GSC/DMC from linux-firmware); default graphics = Google's stack (ANGLE on ANV); hwcomposer color pipeline off; allocator rebuilt (`gfx-minigbm`): any Xe GPU, by graphics IP version | — (Arrow Lake verified on the MSI) |
| Intel pre-Gen12 | opt-in `i915` pack (not default: it wedged Arrow Lake and broke `xe`) | only relevant with CPU emulation |
| AMD | — | amdgpu module + firmware + Mesa radeonsi/radv + allocator |
| NVIDIA | `gpu-nouveau` (below): nouveau display + GSP firmware + allocator with VRAM buffers; GL = Zink on NVK (Turing+) or nouveau GL (older), Vulkan = NVK; only where nothing else drives the display | MSI discrete mode (RTX 5070 Ti, GB205): Android boots and renders on NVK/Zink; panel garbled by DSC the GOP left on, HDMI stalls → fix (`nouveau-dsc-off` + GB20x backports) to test |
| No usable GPU | no UI: no allocator backend for simpledrm/vgem, and Mesa's software path needs llvmpipe (LLVM) to import buffers | fallback allocator backend + llvmpipe |
| VMs (QEMU) | virtio-gpu, vgem in the `gpu` pack | — |

The graphics stack is picked at boot (`--gfx auto`, the default): GRUB reads PCI config space -
an Intel iGPU at 00:02.0 (hybrid laptops included) → `native`; else an NVIDIA display controller
→ `nouveau`; else `soft`. A GRUB menu entry or an explicit `--gfx` wins.

## Other hardware

| Area | Today | Next |
|---|---|---|
| Storage | NVMe/USB built in; `storage` pack: AHCI, eMMC (sdhci-pci/acpi) | — |
| Intel Wi-Fi / BT | image's iwlwifi/btintel + `firmware-extra` (modinfo-declared names + `extra.txt` for Bluetooth) | verify on MSI (`iwlwifi-so-a0-gf-a0-89`, `ibt-1040-0041`) |
| Other Wi-Fi | opt-in `wifi` pack (ath9k, firmware-less; replaces the image's iwl7000 cfg80211/mac80211) | boot-time choice instead of build-time |
| Audio | HDA from the image; SOF DSP firmware/topologies missing | sof-bin package |
| NPU (`intel_vpu`) | blacklisted (`CHURRO_NPU=false`): froze Arrow Lake | with `firmware-extra` the NPU firmware may now be there → retry with `CHURRO_NPU=true` |
| BIOS flash | always inaccessible (`firmware-lockdown` + cmdline + SPI driver blacklist) | — |
| Device firmware (SSD, hubs, cameras…) | `fwupd` removed (`firmware-lockdown`) | — |
| TPM | drivers always blacklisted: the image's gscutil/check_tpm_clear would talk to the PC's TPM (BitLocker!) | — |
| Security chip | not needed (`security-software`) | — |

## Machines tried

| Machine | CPU / GPU | Result |
|---|---|---|
| QEMU/KVM | host / virtio | boots to system_server; SurfaceFlinger crashes in softpipe (QEMU 2D virtio-gpu) |
| Asus T300FA | Core M-5Y10 / HD 5300 | not bootable (CPU floor) |
| HP AiO | older Intel | `init` invalid opcode (CPU floor) |
| MSI (Core Ultra 7 255HX) | Arrow Lake / RTX 50 (10de:2f18) | hybrid mode: boots and runs (xe + our allocator); discrete (MUX) mode: Android runs on nouveau/NVK, display fixes to test |

## Design direction: distro-style driver coverage (planned)

The image is already generic: "build time" only means files are baked in, nothing is probed on
the build machine. `firmware-extra` takes its list from *every* module in the image, so one image
carries firmware for all xe-supported Intel GPUs, ~30 Intel Wi-Fi variants, Intel BT, Realtek
NIC/BT. The goal is to extend this the way Linux distros do: ship most drivers, load only what
the hardware needs.

What makes it feasible:
- **Android already autoloads by device ID.** `ueventd` matches modaliases against the module
  alias table (the "Unable to find a module for acpi:…" lines in boot.log), like udev. A large
  module set can ship; each machine loads only matching modules — in second stage, so firmware is
  reachable (first stage can't see `/vendor/firmware`).
- **We build the kernel** with Google's KMI preserved, so almost any in-tree driver can be added
  as a module (amdgpu, nouveau, rtw88/rtw89, mt76, ath10k/11k, card readers, touchpads, codecs).
- **Size is fine:** modules are small; firmware for a broad set is a few hundred MB vs. an 8 GB image.

Where Android is harder than a Linux distro:
1. **Conflicting stacks.** Some drivers can't coexist: Google's Intel Wi-Fi runs on an
   out-of-tree cfg80211/mac80211 (iwl7000) that in-tree Wi-Fi drivers can't link against;
   i915 and xe need different `drm_display_helper` builds. Needs a **boot-time stack picker**:
   a small early step (the `rdinit` hook the logger already uses is the natural place) that reads
   PCI IDs and decides which stack gets loaded (Wi-Fi first, then graphics).
2. **HALs, not just drivers.** Linux userspace is generic (Mesa, PipeWire, NetworkManager);
   Android's graphics allocator/composer, audio, etc. are per device, and Google's are
   Intel-only. AMD/NVIDIA/no-GPU need the generic allocator + Mesa; unknown audio codecs need a
   generic audio HAL configuration. Android-x86 / Bliss OS solved this (minigbm/gbm_gralloc +
   drm_hwcomposer, generic tinyalsa audio) — known territory.
3. **More drivers = more chances one misbehaves** (cf. the NPU freeze). Safety valve: per-driver
   blocking via `module_blacklist` (already used), later exposed as a GRUB entry or setting.

Order:
1. Broaden `kmod/profiles/generic.conf` into a distro-like driver set (as modules, loaded on demand).
2. Extend `firmware-extra` to cover them (already automatic: it reads every module's firmware list).
3. Boot-time stack picker (Wi-Fi, then graphics; replaces build-time `--packs wifi` / `--gfx`).
4. Generic graphics allocator + Mesa CPU rendering, then AMD (amdgpu + radeonsi/radv) and
   NVIDIA (nouveau + NVK/Zink) on top.

None of this replaces what exists; each step is additive.

### Graphics allocator (`gfx-minigbm`)

Why it's needed even for Intel: Google's minigbm (`libminigbm_gralloc.so`, used by the allocator
service *and* the mapper loaded into every app; `libgbm.so`, used by the codec/camera HALs) only
accepts GPU IDs from tables compiled into it. Found on the MSI: `Xe driver is not supported on
your platform: 0x7d67` → every buffer allocation fails → SurfaceFlinger aborts. The tables cover
ADL/RPL, Meteor Lake, Lunar Lake, Panther Lake — **no Arrow Lake** (`7d41 7d51 7d67 7dd1`), even
though it's Meteor Lake graphics. (The interim test build retargeted one compiled ID compare.)

Step 1 (done, works on the MSI's Arrow Lake: detected as graphics IP 12.70): both libraries rebuilt from AOSP `external/minigbm`
(android17-release, same source as Google's; Google's own build is slightly newer in the core but
its C++ layout matches) by `gfx/build-minigbm.sh` with the NDK. Patch
`gfx/minigbm-patches/xe-unknown-gpus.patch`: a GPU missing from the tables is no longer rejected;
its generation comes from the graphics IP version the xe driver reports (Meteor Lake and newer;
older Xe GPUs report none and are Gen12). Google's allocator service, mapper and gralloc0 module
stay: our libraries are linked against the image's libc++ (`std::__1`) and the build checks that
every symbol the image's binaries import from Google's versions exists in ours. Built for the
plain x86-64 Android baseline: no extra CPU requirements (relevant for future old-CPU support).

Next steps (each needs hardware to test):
- AMD: compile minigbm's `amdgpu` backend (`DRV_AMDGPU`; static libdrm_amdgpu is already in the
  Mesa sysroot; tiled allocations go through Mesa's radeonsi DRI driver, which needs Mesa with LLVM).
- No GPU driver / unknown GPU: a fallback backend (vgem, or dumb buffers on simpledrm) tried
  only after every real GPU, and never by opening `card0` before hwcomposer (that would take DRM
  master away from it).
- If Google's allocator service or mapper ever become the limit (new AIDL versions, metadata),
  build them too: needs AIDL (already used by the build) + HIDL headers (gralloc4 types).
- nouveau backend: done (see NVIDIA below).

### NVIDIA (`gpu-nouveau`)

NVIDIA's own driver exists only for glibc Linux, so NVIDIA GPUs use the open stack Linux distros
use: nouveau (kernel), NVK (Vulkan), Zink (GL on Vulkan) or nouveau GL (Mesa).

- **Kernel module.** `DRM_NOUVEAU=m` in the generic profile; the feature puts `nouveau.ko` in
  vendor_dlkm, where ueventd loads it by device alias like the image's xe (`modules.alias`: only
  when an NVIDIA GPU is present; it loads before init continues, so before the composer). It links against
  Google's own drm helper modules, so the feature compares the CRC of every symbol it takes from
  them (107, all equal) and refuses to build on a mismatch. Google's `drm_ttm_helper` lacks one
  function (the fbdev console; GKI has no fbdev), so our build replaces it - allowed only because
  it exports everything Google's does with identical CRCs, so xe keeps loading.
- **Only where nothing else drives the display** (`kmod/patches/nouveau-hybrid-guard.patch`):
  nouveau doesn't bind when another display controller exists. Hybrid laptops keep today's Intel
  stack, and simpledrm isn't removed under it. `nouveau.hybrid=1` overrides. Desktops with the
  monitor on the NVIDIA card and the iGPU enabled: disable the iGPU in the BIOS.
- **Firmware** via `firmware-extra` (nouveau declares 519 names): GSP-RM 570.144 only
  (`skip.txt` drops the 535 fallback); linux-firmware's WHENCE links become hardlinks (one 60 MB
  GSP image serves 18 chip names). +95 MB on vendor.
- **Display:** drm_hwcomposer needs atomic KMS: `nouveau.atomic=1` (feature `cmdline`). nouveau
  scans out of VRAM only. It has no DSC support, so modes that need it (e.g. 2560x1600@240 on
  the MSI panel) are filtered out, and `nouveau-dsc-off.patch` clears the DSC state laptop
  firmware leaves behind for them. GB20x display fixes from mainline: `nouveau-up-*.patch`.
- **Buffers:** minigbm's dumb-buffer nouveau backend can't work (dumb buffers aren't allowed on
  render nodes), so `gfx/minigbm-patches/nouveau-native.patch` allocates with `NOUVEAU_GEM_NEW`:
  linear, pitch aligned to 256, VRAM (may spill to system memory) for anything the GPU or display
  touches, system memory for CPU-only buffers.
- **Rendering** (`gfx-nouveau.rc`): `ro.hardware.egl=mesa` - Mesa's loader picks Zink on NVK for
  Turing and newer (the only option from Blackwell on) and nouveau GL for older chips;
  `ro.hardware.vulkan=nouveau` (NVK) for apps. NVK has no AHardwareBuffer support upstream;
  `gfx/mesa-patches/nvk-android-hardware-buffer.patch` adds it (Chrome's ANGLE-on-Vulkan needs
  it). SurfaceFlinger and HWUI stay on GL for now (Skia's Vulkan backends are the next step). Mesa is built with NVK
  (`gfx/build-mesa.sh`): its Rust parts use the kernel's Android Rust toolchain (Android std,
  panic=abort) and bindgen, plus cbindgen and the small libelf Mesa's own Android CI uses.
- **SELinux:** Mesa finds GPUs through libdrm, which reads the GPU's PCI ID files in sysfs from
  every app. Google labels them readable (`sysfs_gpu`) only at the iGPU's slot 00:02.0; the
  feature adds wildcard genfscon rules for function 0 of any device behind a PCIe bridge.
- **Coverage:** display on anything nouveau drives with atomic modesetting (GeForce 8 and newer).
  3D: Turing+ at full speed (GSP); Kepler..Volta work but nouveau can't reclock them (boot clocks,
  slow); Maxwell 2+ need signed firmware (included).
- **Not covered:** the NVIDIA GPU of hybrid machines stays unused (no PRIME render offload). No
  software fallback on nouveau: softpipe can't import buffers, llvmpipe would need LLVM.
