# 08 — Lenovo Yoga 7 14IAL7 (LENOVO 82QE) Target Guide & Architecture

## Overview

The Lenovo Yoga 7 14IAL7 (`LENOVO 82QE`) is a 14" 2.8K 90Hz OLED 2-in-1 convertible laptop powered by an Intel 12th Gen Alder Lake Core i7-1260P (4 Performance cores / 8 Efficient cores / 16 threads) with Intel Iris Xe Graphics (96 EUs).

This document details the hardware characteristics, root-cause analyses of Googlebook OS issues encountered on this platform, the architectural solutions implemented in Project Churro, power & thermal tuning, and verification procedures.

---

## Hardware Specifications vs. Churro Support

| Component | Hardware Specification | Churro Support & Optimization |
|---|---|---|
| **CPU** | Intel Core i7-1260P (Alder Lake-P): 4P + 8E cores (16 threads) | 16-thread hybrid cpusets, E-core offloading, balance_power EPP, 8W PL1 / 12W PL2 RAPL caps |
| **GPU** | Intel Iris Xe Graphics (96 EUs / GT2) | Intel `xe` DRM driver + Mesa Vulkan/GLES, 850 MHz sweet-spot cap, PSR/DPT disabled, DC states restored |
| **Display** | 14.0" 2880×1800 16:10 90Hz OLED, 10-point multi-touch + USI pen | Native 90Hz refresh rate, 1-second zero-touch GRUB boot, auto-rotation daemon |
| **Convertible 360° Hinge** | Intel Integrated Sensor Hub (ISHTP) Hinge Angle Sensor | `churro-yoga` daemon reads `custom_intel_hinge` (`in_angl0_raw`), auto-inhibits keyboard & touchpad at $\ge 195^\circ$, emits `SW_TABLET_MODE` |
| **Orientation / Tilt** | ISHTP 3D Accelerometer (`accel_3d`) | `churro-yoga` computes 4-way rotation with hysteresis (0°, 90°, 180° tent, 270°) |
| **Keyboard & Touchpad** | AT Translated Set 2 Keyboard, Elan / Synaptics I²C Touchpad | Inhibited via `/sys/class/input/input*/inhibited` when flipped into tent/tablet mode |
| **Wireless / BT** | Intel Wi-Fi 7 BE200 / AX211 + Bluetooth 5.3 | `iwlwifi` with `c104.ucode`/`c105.ucode` aliases and `.pnvm` payload; Intel Bluetooth firmware |
| **Audio** | Realtek ALC3306 / Intel Smart Sound Technology (SOF) | `audio-generic` feature with SOF DSP + HDA codec fallback |
| **Storage** | M.2 2280 NVMe PCIe 4.0 SSD | High-performance in-tree NVMe driver |

---

## Root Cause Analyses & Solutions

### 1. Excessive Power Draw & High Fan Noise (25–35W $\to$ 4–6W)

#### Root Causes:
1. **Aggressive Vendor Power Hints:** Google's stock `/vendor/etc/powerhint.json` specified `TopAppUclamp = 75` at `DefaultIndex: 0`. This forced `intel_pstate` to keep CPU frequencies clamped at $\ge 75\%$ of maximum Turbo (3.6–4.7 GHz) for any foreground app and the desktop launcher.
2. **Missing E-Core Topology:** The stock power hints were designed for an 8-core CPU (`0-7`), assigning background tasks, system-background, restricted services, and camera daemons to cores `0-3` or `4-7`. On the i7-1260P, all 8 Efficient cores (`8-15`) remained completely unassigned to cpusets, forcing all workload onto power-hungry P-cores.
3. **Display C-States Blocked:** Booting with `xe.enable_dc=0` completely prevented Display C-states (DC5/DC6) and SoC Package C-states (PC8/PC10), creating a continuous ~6–8W uncore floor even with the screen idle.
4. **Crash-Looping ChromeOS Services:** Services like `timberslide`, `hal_desktop_charge_control_default`, and `sound_card_init` crashed and restarted every 5 seconds searching for missing ChromeOS embedded controller nodes (`/dev/cros_ec`), generating continuous wakeups.

#### Implemented Solutions:
- **16-Thread Hybrid `powerhint.json`:**
  - Removed top-app clamp (`TopAppUclamp` $\to 0$).
  - Directed background, system-background, restricted, and camera daemons onto E-cores (`8-15`).
  - Pinned Linux kernel workqueues and Xe GPU interrupts to E-cores (`smp_affinity` = `ff00`).
  - Default Energy Performance Preference (EPP) configured to `balance-power`.
- **Hardware Power Clamping (RAPL):** Injected active constraints into `/sys/class/powercap/intel-rapl` limiting package power to **8W PL1 (sustained)** and **12W PL2 (burst)**.
- **V/F Frequency Sweet-Spot Caps:**
  - P-cores capped at **2.6 GHz** (prevents high-voltage spikes $>1.0\text{V}$).
  - E-cores capped at **2.2 GHz**.
  - Iris Xe iGPU capped at **850 MHz** (halves UI compositing wattage).
- **Lenovo Quiet Profile:** Injected `/sys/firmware/acpi/platform_profile` $\to$ `low-power`.
- **Service Pruning:** Permanently stopped `timberslide`, `hal_desktop_charge_control_default`, `sound_card_init`, and `vpd-executor`.

---

### 2. Convertible Tablet Mode & Auto-Rotation

#### Root Causes:
1. **Google EC Sensor HAL Incompatibility:** `/vendor/lib64/android.hardware.sensors@2.1-Desktop-IIO-Subhal.so` hardcodes ChromeOS EC sensor names (`cros-ec-accel`, `cros-ec-lid-angle`). It fails to recognize Intel ISHTP HID sensors (`custom_intel_hinge`, `accel_3d`).
2. **Touchpad Inhibitor Limitation:** `/vendor/bin/hw/touchpad-inhibitor` only responds to `SW_LID` events, ignoring hinge angle completely and lacking logic to inhibit the physical AT keyboard.
3. **Module Symbol Conflicts:** Prebuilt `kfifo_buf.ko` and `industrialio-triggered-buffer.ko` in Google's `vendor_dlkm` conflicted with kernel symbols, preventing `hid-sensor-accel-3d.ko` and `hid-sensor-custom-intel-hinge.ko` from loading.

#### Implemented Solutions:
- **Clean DLKM Build:** Stripped conflicting prebuilt IIO modules from `vendor_dlkm` before running `depmod`, allowing our fresh in-tree sensor drivers to link directly against `vmlinux`.
- **`churro-yoga` Daemon:**
  - Implemented as a lightweight static C daemon (`features/lenovo-yoga/churro-yoga.c`) running as root under SELinux `vendor_toolbox_exec`.
  - Creates a virtual switch device `"Churro Yoga Tablet Switch"` via `/dev/uinput` with `SW_TABLET_MODE`.
  - Discovers internal keyboard (`AT Translated Set 2 keyboard`) and touchpad nodes under `/sys/class/input/input*`.
  - **Hinge Angle $\ge 195^\circ$:** Writes `1` to `inhibited` for keyboard & touchpad, sends `SW_TABLET_MODE = 1`, and enables virtual keyboard (`settings put secure show_ime_with_hard_keyboard 1`).
  - **Hinge Angle $\le 175^\circ$:** Writes `0` to `inhibited`, sends `SW_TABLET_MODE = 0`, and resets rotation to landscape (0°).
  - **Accelerometer 4-Way Rotation:** Reads `in_accel_x_raw` and `in_accel_y_raw`, calculating display orientation with deadzone hysteresis:
    - Landscape (0°)
    - Portrait (90°)
    - Inverted Landscape / Tent (180°)
    - Inverted Portrait (270°)

---

### 3. Display Black Screen & Zero-Touch Boot

#### Root Causes:
- Googlebook OS vendor bootcmdline includes `xe.enable_psr=1` and `console=null`.
- On Alder Lake-P eDP displays, Xe Display Source Buffer (DSB) and Panel Self Refresh (PSR) cause Display Pipe Transcoder timeouts during boot, causing a permanent black screen after the Chrome logo.
- GRUB configuration required manual interaction to select the debug menu.

#### Implemented Solutions:
- Set `timeout=1` and `default=0` in `lib/esp.sh`.
- Removed `console=null`, `cpufreq.default_governor=[^ ]*`, `no_console_suspend`, and `xe.enable_psr=[^ ]*`.
- Enforced clean display parameters: `console=tty0 loglevel=3 xe.enable_dpt=0 xe.enable_psr=0 xe.enable_dsb=0`.
- Enabled active power savings: `cpufreq.default_governor=powersave pcie_aspm.policy=powersupersave snd_hda_intel.power_save=1`.

---

## How to Build

From the root of this repository:

```bash
sudo bash churro.sh auto android-desktop_signed_recovery_image.bin out/churro.img --gfx mesa
```

Kernel and Mesa builds are automatically cached in `/var/cache/churro/`. Subsequent repacks take ~2–3 minutes.

---

## Flashing & Verification

### 1. Flash to USB Drive
Use Rufus (in DD image mode) or Linux `dd`:

```bash
sudo dd if=out/churro.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### 2. Boot
- Power on laptop, press **F12** or **Fn+F12** to enter the boot menu.
- Select your USB drive.
- GRUB will automatically launch Googlebook OS after 1 second without user intervention.

### 3. Verification Commands in Root Terminal (`Alt+Ctrl+F2` or ADB)
- **Check CPU Power & RAPL Constraints:**
  ```bash
  cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
  # Output: 8000000 (8W PL1)
  cat /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw
  # Output: 12000000 (12W PL2)
  ```
- **Check CPU Frequencies:**
  ```bash
  cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
  # P-cores should idle at ~400-800 MHz and cap at 2.6 GHz.
  ```
- **Check Yoga Daemon Logs:**
  ```bash
  logcat -s churro-yoga
  ```
- **Test Convertible Mode:**
  - Fold the display past 195°.
  - Confirm keyboard and touchpad no longer register touches.
  - Confirm on-screen keyboard appears when tapping text fields.
  - Rotate 90° / 180° / 270° and observe smooth screen reorientation.
