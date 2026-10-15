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
| Intel iGPU / Arc (Gen12+) | image's own `xe` + `firmware-extra` (GuC/HuC/GSC/DMC from linux-firmware); default graphics = Google's stack (ANGLE on ANV) | test on Arrow Lake (MSI) |
| Intel pre-Gen12 | opt-in `i915` pack (not default: it wedged Arrow Lake and broke `xe`) | only relevant with CPU emulation |
| AMD | — | amdgpu module + firmware + Mesa radeonsi/radv + allocator |
| NVIDIA | — | nouveau (Blackwell since Linux 6.16) + GSP firmware + Mesa NVK/Zink + allocator; NVIDIA's own driver is glibc-only, no Android build |
| No usable GPU / NVIDIA-only laptops in dGPU mode | crash-loop: Googlebook's minigbm allocator only knows Intel | own allocator (dumb/vgem buffers) + Mesa CPU rendering |
| VMs (QEMU) | virtio-gpu, vgem in the `gpu` pack | — |

Later: pick the graphics stack automatically at boot from the GPU found (today: build default
`--gfx native` + GRUB menu).

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
| MSI (Core Ultra 7 255HX) | Arrow Lake / RTX 50 | NPU freeze fixed; dGPU-only mode → allocator loop; hybrid mode → our i915 wedged the iGPU, `xe` couldn't load → fixed by dropping i915 + firmware-extra (to test) |

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
