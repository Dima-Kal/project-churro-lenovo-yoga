# Project Churro — 01: Image analysis (Lenovo Googlebook 15 "ruby")

Source analysed: `android-desktop_signed_recovery_image.bin` (19,069,493,760 bytes), build `CL3B.260622.271.R1 / 16452207`, Android 17 (SDK 37), fingerprint `Lenovo/ruby/ruby:17/CL3B.260622.271.R1/16452207:user/release-keys`. Analysed read-only from WSL (`losetup -r -P`, `dump.erofs`, `fsck.erofs --extract`, `unpack_bootimg.py`).

> Status: this is the **initial** analysis (before any bring-up). Several open points were since answered: GRUB was chosen over UKI, pKVM does not come up off-Googlebook (→ `security-software` feature), and pre-Gen12 Intel is handled by the Churro kernel + Mesa. See `02-bringup-log.md` and `03-architecture.md` for the current state.

## 1. What the YouTuber (Stockdroid) actually did

From the video's auto-transcript and description:

- He used the **Acer Googlebook 14 (moonstone)** image, not ruby.
- His Claude first explained that the image is device-specific: the kernel and partitions are made for the Acer hardware and won't boot as-is in VirtualBox or QEMU. It also said the `system` partition is generic and "could be used as a GSI on top of an Android base".
- On Windows it produced `.bat` scripts; the "download of the Android base" failed.
- Claude then suggested **dual-booting Ubuntu**. On Ubuntu it built a wrapper command (`sudo alos avvia`) that starts a VM. He then opens a **localhost web page**, hits restart, and the Googlebook UI appears in the browser. The mouse acts as a touchscreen, Bluetooth is not detected, and the NPU features don't work.
- The description says so directly: *"installato come macchina virtuale VM su Linux (Ubuntu)"* (installed as a virtual machine on Linux).

**Inference (high confidence, not confirmed on screen):** this matches **Cuttlefish** (Android's official KVM virtual device): `launch_cvd` plus the WebRTC UI on `https://localhost:8443`, a touch-style input, no Bluetooth or NPU, and an "Android base" (Cuttlefish host package and AOSP CF images) to download. In other words, the Googlebook `system`/`system_ext`/`product` were run like a GSI on top of the **Cuttlefish vendor and kernel**.

→ He did **not** port anything to bare metal. It is emulation on an AMD Ryzen mini PC, which is why driver, TPM and boot questions never came up for him. This is a valid "run it anywhere" path, but it is not what Churro is about (a native install).

## 2. Image layout: Android A/B on ChromeOS-style firmware

The GPT has 30 partitions. The main ones:

| # | Name | Size | Content |
|---|---|---|---|
| 1 | userdata | 4 GiB | empty (grows on install) |
| 2 | KERN-A | 512 MiB | **all zeros** (legacy ChromeOS slot, unused) |
| 3 | super | 12 GiB | liblp v10.2: system_a 1.1G, system_b 4.4G (= *system_other*: preloads + odex), vendor_a, product_a, system_ext_a, system_dlkm_a, vendor_dlkm_a. All **EROFS** |
| 4 | KERN-B | 4 MiB | squashfs holding `partition-script.sh` + `partition-common*.sh` (installer GPT layout) |
| 5 | ROOT-B | 512 MiB | erofs holding `chromeos-firmwareupdate` (AP + EC firmware `Google_Ruby.16650.*`, with GSC `gscvd`) |
| 9/10 | ota_recovery_a/b | 128 MiB | **nested GPT** (boot_a, init_boot_a, vendor_boot_a, pvmfw_a, vbmeta_a). Cmdline adds `ota_recovery=1 androidboot.override_force_normal_boot=1` |
| 12 | EFI-SYSTEM | 64 MiB | **all zeros, not even formatted** |
| 13/14 | boot_a/b | 64 MiB | boot v4, kernel only (Linux **6.18.21**, x86_64, IKCONFIG present) |
| 15/16 | vbmeta_a/b | 4 MiB | AVB, flags = 0 (verification on) |
| 18/19 | init_boot_a/b | 8 MiB | generic ramdisk |
| 20/21 | vendor_boot_a/b | 32 MiB | v4: ramdisk00 (platform + first-stage fstab), ramdisk01 `recovery`, ramdisk02 `dlkm` (59 .ko); bootconfig `androidboot.hardware=android-desktop` |
| 22/23 | pvmfw_a/b | 4 MiB | protected-VM firmware (pKVM) |
| 29/30 | desktop_security_persist / _storage | 16/32 MiB | Trusty secure storage |

Takeaways:

- The real device firmware is **Google coreboot + depthcharge + ChromeOS EC + GSC** (manifest: `Google_Ruby.16650.89.0`, root/recovery keys). Depthcharge boots the Android boot images directly. Nothing UEFI-bootable is shipped: the ESP is empty and KERN-A is empty.
- The recovery `.bin` is **already a full disk image in the installed layout** (same offsets as `write_base_table`). Installing is essentially "partition table + dd each partition".

## 3. Drivers: does it need Croissant-style donor drivers?

The kernel is generic-ish x86_64 (Intel + AMD CPU support, EFI stub, NVMe/xHCI/USB storage built in). Modules: 484 in vendor_dlkm, 100 in system_dlkm, 59 in the vendor_boot dlkm ramdisk. The hardware coverage is narrow, though:

| Area | What's there | Consequence on a generic PC |
|---|---|---|
| GPU | **only `xe.ko`** (out-of-tree, `force_probe=*`). PCI IDs cover TGL, RKL, ADL, RPL, MTL, LNL, PTL, DG1/DG2, BMG. No i915, amdgpu, nouveau, simpledrm, efifb or virtio-gpu | Intel Gen12+ only. **Firmware shipped only for PTL** (`xe/ptl_guc/huc/gsc`, plus DMC for xe2lpd/xe3lpd) → TGL…LNL need `tgl/adlp/mtl/lnl_guc_70.bin` etc. added. AMD/NVIDIA: no display at all |
| GL/Vulkan | `ro.hardware.egl=angle`, `ro.hardware.vulkan=intel` (ANV only), minigbm, drm_hwcomposer. No SwiftShader | No software fallback |
| Storage | NVMe built in, eMMC/SD, USB storage. **`CONFIG_ATA` not set** | No SATA/AHCI disks |
| Wi-Fi / BT | iwlwifi/iwlmvm/iwlmld, btintel/btusb/btrtl | Firmware only for the new `sc-a0-wh*` chips → older Intel cards need linux-firmware blobs |
| Ethernet | r8169 (+ rtl_nic fw), e1000e, igc | OK on common NICs |
| Audio | HDA + all codecs, SOF Intel | HDA should work; SOF topologies are device-specific |
| Input | i2c-hid-acpi, hid-multitouch, elan, atkbd built in | Mostly fine |
| Virt | virtio_blk/pci/console/balloon only (no virtio-gpu/net) | Won't boot "as is" in QEMU with a display |

Verdict: unlike Croissant, **swapping the kernel or modules is not needed on Intel Gen12+ machines**. The modules are already there and the gap is mostly **firmware blobs** (and possibly SOF topologies). AMD, NVIDIA, pre-Gen12 Intel and SATA would need a different kernel + modules + Mesa/Vulkan (Brunch-level work). That is out of scope for v0.

## 4. TPM: is an emulator needed?

No TPM emulator is needed. The security stack is not cryptohome+TPM like ChromeOS:

- `ro.hardware.keystore=trusty`, `ro.hardware.gatekeeper=trusty`. KeyMint, Gatekeeper and secure storage run in a **Trusty "security VM"** launched through AVF/crosvm (`/system_ext/etc/vm/trusty_vm/*.elf`, `trusty_security_vm_launcher`).
- The kernel has `CONFIG_PKVM_X86=y`, `CONFIG_PKVM_INTEL=y`, cmdline `kvm-intel.pkvm=1`. Vendor `build.prop` **hard-codes `ro.boot.hypervisor.protected_vm.supported=1`** → init always starts the **protected** VM.
- If `protected_vm.supported` is empty, init starts a **non-protected** Trusty VM but does **not** set `trusty.security_vm.keymint.enabled` → no KeyMint → FBE/vold will likely hang. A software RPMB mock (`rpmb_dev.desktop.system`) already exists for `ro.boot.boot_source=external`.
- `/dev/tpm*` (GSC via `tpm_tis_*cr50`) is used only by weaver/pinweaver (only when pVM is on), StrongBox (optional), oemlock, and the installer's `reset_secure_storage`.

So the real "TPM-emulator problem" of Churro is **pKVM / KeyMint**:

1. **Try first with nothing:** Intel machine, VT-x + VT-d enabled. If x86 pKVM comes up, the stock path works as is.
2. Fallback A: in bootconfig, set `androidboot.hypervisor.protected_vm.supported` to empty or 0 (the ro.boot value from bootconfig should win over build.prop, *to verify*). Then start KeyMint against the non-protected VM. This needs an rc tweak, i.e. modified system_ext/vendor → AVB verification off.
3. Fallback B: an AOSP software KeyMint (Cuttlefish-style) as a last resort.

## 5. Installer

- `/vendor/bin/android-desktop-install` is a POSIX sh port of `chromeos-install` ("install from removable media to hard disk").
  - Usage: `android-desktop-install [SRC [DST]] [0|1|2|3]`. SRC can be a block device **or the `.bin` file** (it is loop-mounted). DST is auto-detected from `DEFAULT_ROOTDEV` (NVMe/SATA/eMMC PCI paths).
  - Steps: `sgdisk --zap` → `write_base_table` (from `partition-script.sh`) → optional wipe of userdata/metadata (asks y/N) → `dd` of boot, vendor_boot, init_boot, vbmeta, super, pvmfw, ESP and ota_recovery_a → zero misc → `reset_secure_storage`.
  - `reset_secure_storage` sends **raw GSC vendor commands to `/dev/tpm0`**. With `set -eu` it aborts on a PC without Ti50/Cr50, though only after all the copies. This needs a one-line patch, or skipping that step.
  - It is run as root from a shell. It has no SELinux file context, so it is not wired into any UI. On a `user` build the recovery console and adb are off. On a real Googlebook the end-user flow comes from firmware recovery mode, which we don't have on a PC.
- For Churro the simpler route: since the `.bin` already has the installed layout, **our own installer (from any Linux/WSL live)** can do it: write the GPT/partitions (or `dd` the image), grow userdata, format metadata, populate the ESP with a bootloader. We can reuse `partition-script.sh` as-is.

## 6. What replaces depthcharge (the actual "port")

Depthcharge's job on a PC: load `boot_a` kernel + `vendor_boot_a` ramdisks (platform + dlkm) + `init_boot_a` ramdisk, append **bootconfig**, pass the cmdline. The kernel has an EFI stub, so possible loaders are:

- **UKI** (systemd-stub/ukify): kernel + cmdline + one pre-concatenated initrd (`vendor_ramdisk00 + vendor_ramdisk02 + init_boot ramdisk + bootconfig trailer`) → `EFI/BOOT/BOOTX64.EFI`. No GRUB needed. Secure Boot off.
- GRUB with that single concatenated initrd.
- AOSP **GBL** (Generic Bootloader EFI app), which does A/B, AVB, boot v4 and bootconfig natively. Worth evaluating later.

Bootconfig must add what depthcharge normally supplies (to be validated on first boot):
`androidboot.slot_suffix=_a`, `androidboot.force_normal_boot=1`, `androidboot.boot_source=external|internal`, `androidboot.verifiedbootstate=orange`, `androidboot.vbmeta.device_state=unlocked`, `androidboot.serialno=…`, and a way to create `/dev/block/by-name` (`androidboot.boot_devices=<pci path>` or `boot_part_uuid`). Plus the vendor ones already present (`hardware=android-desktop`, `load_modules_parallel=true`).

## 7. Proposed generic approach (v0, Intel Gen12+, NVMe/USB)

1. **Boot-only test (no image changes):** script that, given the `.bin`, formats partition 12 as FAT32, extracts kernel + ramdisks with `unpack_bootimg.py` (or `dd` + offsets), builds the bootconfig and initrd, and drops a UKI/GRUB on the ESP. Write it to a USB (≥ 32 GB) and boot with `boot_source=external`. Goal: does Android reach SurfaceFlinger, and does pKVM/KeyMint come up?
2. **Firmware injection** (Croissant's "copy drivers", reduced to blobs): add linux-firmware GuC/HuC/DMC (and iwlwifi) for the target GPU to `vendor/firmware`. Rebuild vendor EROFS and set vbmeta flags = 2 (or re-sign with a test key).
3. **KeyMint fallback** only if step 1 shows the protected VM failing.
4. **Installer:** reuse `partition-script.sh` + dd, skip the GSC TPM commands, install the same ESP bootloader with `boot_source=internal`.

Out of scope for v0: AMD/NVIDIA GPUs, SATA, pre-Gen12 Intel (these need a custom GKI-compatible kernel + modules + Mesa).

## Open questions / to verify on hardware
- Does x86 pKVM initialise on a non-Googlebook Intel (VT-d, IOMMU, firmware quirks)?
- Exact `/dev/block/by-name` mechanism expected by android-desktop init/ueventd.
- Does bootconfig `ro.boot.hypervisor.protected_vm.supported` win over vendor build.prop?
- Do the HALs that expect EC/GSC/VPD (ec-executor, futility, oemlock, health, charge-control) fail gracefully?
