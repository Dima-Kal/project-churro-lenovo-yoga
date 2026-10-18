#!/usr/bin/env bash
# Boot a Churro image in QEMU with a gap CPU model (e.g. Ice Lake / Tiger Lake Tier 1)
# using TCG to reproduce #UD instruction faults (like vpdpwssd) without flashing real hardware.
# Usage: tools/qemu-gap-test.sh <image> [logdir] [cpu_model]
set -euo pipefail
IMG=$1; LOG=${2:-/tmp/churro-qemu-gap}; mkdir -p "$LOG"
CPU_MODEL=${3:-Icelake-Server}
ACCEL=${ACCEL:-tcg}

# Find OVMF firmware files across common Linux distro paths
OVMF_CODE=""
OVMF_VARS=""
for code in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/qemu/ovmf-x86_64-code.bin /usr/share/edk2/ovmf/OVMF_CODE.fd; do
  [ -f "$code" ] && { OVMF_CODE="$code"; break; }
done
for vars in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/qemu/ovmf-x86_64-vars.bin /usr/share/edk2/ovmf/OVMF_VARS.fd; do
  [ -f "$vars" ] && { OVMF_VARS="$vars"; break; }
done

[ -n "$OVMF_CODE" ] || { echo "error: OVMF code fd not found" >&2; exit 1; }
if [ -n "$OVMF_VARS" ]; then
  cp "$OVMF_VARS" "$LOG/vars.fd"
  VARS_DRIVE="-drive if=pflash,format=raw,file=$LOG/vars.fd"
else
  VARS_DRIVE=""
fi

echo ">> Booting QEMU with accel=$ACCEL, cpu=$CPU_MODEL..."
exec qemu-system-x86_64 -accel "$ACCEL" -machine q35 -cpu "$CPU_MODEL" -smp 4 -m 6G \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  $VARS_DRIVE \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -drive if=none,id=d0,format=raw,file="$IMG",snapshot=${SNAPSHOT:-on} -device ${DISK_DEV:-nvme,serial=churro0},drive=d0 \
  ${GPU_ARGS:--device virtio-gpu-pci} \
  -netdev user,id=n0 -device e1000e,netdev=n0 \
  -chardev socket,id=s0,path="$LOG/serial.sock",server=on,wait=off,logfile="$LOG/serial.log" -serial chardev:s0 \
  -serial file:"$LOG/kernel.log" -qmp unix:"$LOG/qmp.sock",server,nowait \
  -display none -vnc 127.0.0.1:5 ${QEMU_EXTRA:-}
