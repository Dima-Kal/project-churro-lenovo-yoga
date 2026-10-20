#!/usr/bin/env bash
# Project Churro - Lenovo Yoga 7 14IAL7 (82QE) Power, Thermal & Convertible Mode Patch.
# 1. Compiles churro-yoga (convertible tablet mode & 4-way auto-rotation daemon).
# 2. Configures Ultra-Cool 90Hz profile:
#    - 16-thread hybrid powerhint.json: uclamp.min=0, E-core-first cpusets (8-15),
#      workqueue & GPU IRQ affinity ff00 (E-cores), balance-power EPP.
#    - Active RAPL thermal limits: 8W PL1 (sustained) / 12W PL2 (burst).
#    - V/F frequency sweet-spot caps: P-cores 2.6 GHz, E-cores 2.2 GHz, Iris Xe iGPU 850 MHz.
#    - Lenovo EC platform_profile = low-power.
#    - Stops crash-looping ChromeOS services (timberslide, hal_desktop_charge_control, sound_card_init).
set -euo pipefail
T=$1; F=$(dirname "$0"); S=$T/etc/selinux
CFG=u:object_r:vendor_configs_file:s0

# 1. Compile churro-yoga daemon
# Labelled touchpad_inhibitor_exec so init transitions into touchpad_inhibitor domain
${CC:-cc} -static -Os -s -Wall -Werror -o "$T/bin/churro-yoga" "$F/churro-yoga.c"
chown root:2000 "$T/bin/churro-yoga"; chmod 0755 "$T/bin/churro-yoga"
setfattr -n security.selinux -v u:object_r:touchpad_inhibitor_exec:s0 "$T/bin/churro-yoga"

# 2. Generate 16-thread hybrid powerhint.json
cat > "$F/powerhint-yoga16.json" <<'EOF'
{
    "Nodes": [
        {
            "Name": "EnergyPerformancePreference",
            "Path": "vendor.powerhal.epp",
            "Values": [
                "maximum",
                "performance",
                "balance-performance",
                "balance-power",
                "power"
            ],
            "DefaultIndex": 3,
            "ResetOnInit": true,
            "Type": "Property"
        },
        {
            "Name": "PlatformProfile",
            "Path": "/sys/firmware/acpi/platform_profile",
            "Values": [
                "low-power",
                "balanced",
                "performance"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "TopAppUclamp",
            "Path": "/dev/cpuctl/top-app/cpu.uclamp.min",
            "Values": [
                "0",
                "20",
                "40"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "TopAppCpuset",
            "Path": "/dev/cpuset/top-app/cpus",
            "Values": [
                "0-15",
                "8-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "CDCpuset",
            "Path": "/dev/cpuset/camera-daemon/cpus",
            "Values": [
                "8-15",
                "0-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "FGCpuset",
            "Path": "/dev/cpuset/foreground/cpus",
            "Values": [
                "0-15",
                "8-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "FGWinCpuset",
            "Path": "/dev/cpuset/foreground_window/cpus",
            "Values": [
                "0-15",
                "8-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "BGCpuset",
            "Path": "/dev/cpuset/background/cpus",
            "Values": [
                "8-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "SysBGCpuset",
            "Path": "/dev/cpuset/system-background/cpus",
            "Values": [
                "8-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "RestrictedCpuset",
            "Path": "/dev/cpuset/restricted/cpus",
            "Values": [
                "8-15"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "SchedLoadBalance",
            "Path": "/dev/cpuset/sched_load_balance",
            "Values": [
                "1",
                "0"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "WorkQueueAffinity",
            "Path": "/sys/devices/virtual/workqueue/cpumask",
            "Values": [
                "ff00",
                "ffff"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        },
        {
            "Name": "XeIrqAffinity",
            "Path": "/dev/power/irq-by-name/xe/smp_affinity",
            "Values": [
                "ff00",
                "ffff"
            ],
            "DefaultIndex": 0,
            "ResetOnInit": true
        }
    ],
    "Actions": [
        {
            "PowerHint": "FIXED_PERFORMANCE",
            "Node": "EnergyPerformancePreference",
            "Duration": 0,
            "Value": "balance-performance"
        },
        {
            "PowerHint": "LOW_POWER",
            "Node": "EnergyPerformancePreference",
            "Duration": 0,
            "Value": "power"
        },
        {
            "PowerHint": "LOW_POWER",
            "Node": "TopAppCpuset",
            "Duration": 0,
            "Value": "8-15"
        },
        {
            "PowerHint": "PROFILE_MEDIA_PLAYBACK",
            "Node": "TopAppCpuset",
            "Duration": 0,
            "Value": "8-15"
        },
        {
            "PowerHint": "PROFILE_MEDIA_PLAYBACK",
            "Node": "FGCpuset",
            "Duration": 0,
            "Value": "8-15"
        },
        {
            "PowerHint": "PROFILE_MEDIA_PLAYBACK",
            "Node": "FGWinCpuset",
            "Duration": 0,
            "Value": "8-15"
        },
        {
            "PowerHint": "PROFILE_MEDIA_PLAYBACK",
            "Node": "TopAppUclamp",
            "Duration": 0,
            "Value": "0"
        },
        {
            "PowerHint": "LAUNCH",
            "Node": "TopAppUclamp",
            "Duration": 800,
            "Value": "20"
        }
    ]
}
EOF

for p in "$T/etc/powerhint.json" "$T/etc/powerhint_cpus_16.json" "$T/etc/power/fatcat/powerhint_cpus_16.json"; do
  mkdir -p "$(dirname "$p")"
  cp "$F/powerhint-yoga16.json" "$p"
  chown root:root "$p"; chmod 0644 "$p"; setfattr -n security.selinux -v "$CFG" "$p"
done

# 3. Disable AC_CPU_BOOST in perf_policy.json
if [ -f "$T/etc/power/perf_policy.json" ]; then
  cat > "$T/etc/power/perf_policy.json" <<'EOF'
{
  "profiles": [
    {
      "name": "VIDEO_PLAYBACK",
      "conditions": [
        { "source": "MEDIA_SESSION", "state": "PLAYING" },
        { "source": "TOP_APP", "fullscreen": true },
        { "source": "POWER_SOURCE", "charger": "false" }
      ],
      "actions": [
        { "type": "POWER_HINT", "name": "PROFILE_MEDIA_PLAYBACK" }
      ]
    }
  ]
}
EOF
  chown root:root "$T/etc/power/perf_policy.json"; chmod 0644 "$T/etc/power/perf_policy.json"
  setfattr -n security.selinux -v "$CFG" "$T/etc/power/perf_policy.json"
fi

# 4. Install active RAPL thermal configuration
if [ -f "$T/etc/thermal/ruby/thermal_info_config.json" ]; then
  cp "$T/etc/thermal/ruby/thermal_info_config.json" "$T/etc/thermal_info_config.json"
  chown root:root "$T/etc/thermal_info_config.json"; chmod 0644 "$T/etc/thermal_info_config.json"
  setfattr -n security.selinux -v "$CFG" "$T/etc/thermal_info_config.json"
fi

# 4b. Pre-authorize host ADB public key for zero-touch wireless updates
for k in /home/dimak/.android/adbkey.pub /root/.android/adbkey.pub; do
  if [ -f "$k" ]; then
    cp "$k" "$T/etc/churro_adbkey.pub"
    chown root:root "$T/etc/churro_adbkey.pub"; chmod 0644 "$T/etc/churro_adbkey.pub"
    setfattr -n security.selinux -v "$CFG" "$T/etc/churro_adbkey.pub"
    break
  fi
done

# 5. Create /vendor/etc/init/churro-power.rc
PWR_RC=$T/etc/init/churro-power.rc
cat > "$PWR_RC" <<'EOF'
# Project Churro - Lenovo Yoga 7 14IAL7 (82QE) Ultra-Cool Power & Convertible Service

service vendor.churro.yoga /vendor/bin/churro-yoga
    class main
    user root
    group root input system
    capabilities NET_ADMIN SYS_ADMIN

on post-fs-data
    # Seed host adb public key for pre-authorized wireless ADB
    mkdir /data/misc/adb 0750 system shell
    copy /vendor/etc/churro_adbkey.pub /data/misc/adb/adb_keys
    chmod 0640 /data/misc/adb/adb_keys
    chown system shell /data/misc/adb/adb_keys
    restorecon /data/misc/adb/adb_keys

on early-init
    write /dev/cpuctl/top-app/cpu.uclamp.min 0
    write /dev/cpuctl/foreground/cpu.uclamp.min 0

on boot
    # Lenovo IdeaPad Quiet / Cool EC platform profile
    write /sys/firmware/acpi/platform_profile low-power

    # Energy Performance Preference (balance_power on P-cores, power on E-cores)
    write /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu1/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu2/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu3/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu4/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu5/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu6/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu7/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu8/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu9/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu10/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu11/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu12/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu13/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu14/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu15/cpufreq/energy_performance_preference power

    # V/F Sweet-Spot Frequency Caps (Prevents >1.0V voltage spikes):
    # P-cores max 2.6 GHz, E-cores max 2.2 GHz
    write /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu1/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu2/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu3/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu4/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu5/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu7/cpufreq/scaling_max_freq 2600000
    write /sys/devices/system/cpu/cpu8/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu9/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu11/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu12/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu13/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu14/cpufreq/scaling_max_freq 2200000
    write /sys/devices/system/cpu/cpu15/cpufreq/scaling_max_freq 2200000

    # Intel Iris Xe iGPU Frequency Cap: 850 MHz (halves GPU compositing power)
    write /sys/class/drm/card0/device/tile0/gt0/freq0/max_freq 850

    # Start Yoga convertible & auto-rotation daemon (replaces stock touchpad-inhibitor)
    stop touchpad-inhibitor
    start vendor.churro.yoga

on property:sys.boot_completed=1
    # Intel RAPL Package Power Caps: PL1 (sustained) = 8W, PL2 (burst) = 12W
    write /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 8000000
    write /sys/class/powercap/intel-rapl:0/constraint_1_power_limit_uw 12000000
    write /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw 8000000
    write /sys/class/powercap/intel-rapl-mmio:0/constraint_1_power_limit_uw 12000000

    # Enforce balance_power / power EPP after powertool
    write /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu1/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu2/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu3/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu4/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu5/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu6/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu7/cpufreq/energy_performance_preference balance_power
    write /sys/devices/system/cpu/cpu8/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu9/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu10/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu11/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu12/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu13/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu14/cpufreq/energy_performance_preference power
    write /sys/devices/system/cpu/cpu15/cpufreq/energy_performance_preference power

    write /dev/cpuctl/top-app/cpu.uclamp.min 0
    write /dev/cpuctl/foreground/cpu.uclamp.min 0

    # Stop crash-looping ChromeOS services
    stop timberslide
    stop hal_desktop_charge_control_default
    stop sound_card_init
    stop ec_crash_collector
    stop vendor.biometrics.fingerprint-service.crosfp
    stop vendor.google.desktop.vpd_executor.vpd-executor

    # Enable Wireless ADB on port 5555 for zero-touch churro.sh ota updates
    setprop service.adb.tcp.port 5555
    setprop persist.adb.tcp.port 5555
    stop adbd
    start adbd
EOF
chown root:root "$PWR_RC"; chmod 0644 "$PWR_RC"; setfattr -n security.selinux -v "$CFG" "$PWR_RC"

# 6. SELinux policy rules
V=$(cat "$S/plat_sepolicy_vers.txt")
cat >> "$S/vendor_sepolicy.cil" <<EOF
; Project Churro lenovo-yoga: SELinux rules for churro-yoga (touchpad_inhibitor domain) & init
(typepermissive touchpad_inhibitor)
(allow vendor_init_$V sysfs_$V (file (getattr open read write)))
(allow init_$V sysfs_$V (file (getattr open read write)))
(allow init_$V uhid_device_$V (chr_file (getattr open read write ioctl)))
(allow init_$V input_device_$V (chr_file (getattr open read write ioctl)))
(allow init_$V input_device_$V (dir (search getattr open read)))
(allow init_$V iio_device_$V (chr_file (getattr open read write ioctl)))
(allow touchpad_inhibitor self (capability (dac_override dac_read_search net_admin sys_admin)))
(allow touchpad_inhibitor uhid_device_$V (chr_file (getattr open read write ioctl)))
(allow touchpad_inhibitor input_device_$V (dir (search getattr open read)))
(allow touchpad_inhibitor input_device_$V (chr_file (getattr open read write ioctl)))
(allow touchpad_inhibitor iio_device_$V (chr_file (getattr open read write ioctl)))
(allow touchpad_inhibitor sysfs_$V (dir (search getattr open read)))
(allow touchpad_inhibitor sysfs_$V (file (getattr open read write)))
(allow touchpad_inhibitor sysfs_$V (lnk_file (getattr read)))
(allow touchpad_inhibitor proc_$V (dir (search getattr open read)))
(allow touchpad_inhibitor proc_$V (file (getattr open read)))
EOF
if grep -q "adb_keys_file" "$S/vendor_sepolicy.cil" 2>/dev/null || grep -q "adb_keys_file" "$S/plat_pub_versioned.cil" 2>/dev/null; then
  cat >> "$S/vendor_sepolicy.cil" <<EOF
(allow init_$V adb_keys_file_$V (dir (search getattr open read write add_name remove_name)))
(allow init_$V adb_keys_file_$V (file (create getattr open read write append setattr unlink relabelfrom relabelto)))
EOF
fi
rm -f "$S"/precompiled_sepolicy "$S"/precompiled_sepolicy.*.sha256

echo "   vendor: lenovo-yoga: installed churro-yoga daemon, ultra-cool 8W/12W power profile & 16-thread cpusets"
