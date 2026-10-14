#!/usr/bin/env bash
# Boot a Churro image in QEMU (UEFI/OVMF, KVM, NVMe disk, virtio-gpu) with serial log + QMP.
# Usage: tools/qemu-test.sh <image> [logdir]
#   serial 0 (ttyS0, Android's apgetty shell): $LOG/serial.sock + serial.log  -> tools/qemu-serial.sh
#   serial 1 (ttyS1, kernel console of the "debug" menu entries): $LOG/kernel.log
#   TPM=1 adds a swtpm-backed TPM 2.0 (tpm-tis), QEMU_EXTRA appends raw QEMU args,
#   GPU_ARGS replaces the display device (default virtio-gpu; "-vga std" = plain framebuffer,
#   i.e. the "no GPU driver" case: simpledrm + vgem + Mesa software rendering)
#   The image is not modified (QEMU snapshot: a first boot formats /data); SNAPSHOT=off keeps changes.
set -euo pipefail
IMG=$1; LOG=${2:-/tmp/churro-qemu}; mkdir -p "$LOG"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$LOG/vars.fd"
TPMARGS=()
if [ "${TPM:-0}" = 1 ]; then
  mkdir -p "$LOG/tpm"
  swtpm socket --tpm2 --tpmstate dir="$LOG/tpm" --ctrl type=unixio,path="$LOG/swtpm.sock" --daemon
  TPMARGS=(-chardev socket,id=chrtpm,path="$LOG/swtpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0)
fi
exec qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 6G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file="$LOG/vars.fd" \
  -drive if=none,id=d0,format=raw,file="$IMG",snapshot=${SNAPSHOT:-on} -device nvme,drive=d0,serial=churro0 \
  ${GPU_ARGS:--device virtio-gpu-pci} -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=n0 -device e1000e,netdev=n0 "${TPMARGS[@]}" \
  -chardev socket,id=s0,path="$LOG/serial.sock",server=on,wait=off,logfile="$LOG/serial.log" -serial chardev:s0 \
  -serial file:"$LOG/kernel.log" -qmp unix:"$LOG/qmp.sock",server,nowait \
  -display none -vnc 127.0.0.1:5 ${QEMU_EXTRA:-}
