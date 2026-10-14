#!/usr/bin/env bash
# Take a screenshot of the running QEMU test VM (PNG) via QMP; optional: send keys.
# Usage: tools/qemu-shot.sh <out.png> [logdir]      |  tools/qemu-shot.sh --key ret [logdir]
set -euo pipefail
if [ "$1" = "--key" ]; then K=$2; LOG=${3:-/tmp/churro-qemu}
  printf '{"execute":"qmp_capabilities"}\n{"execute":"human-monitor-command","arguments":{"command-line":"sendkey %s"}}\n' "$K" \
    | timeout 3 socat - UNIX-CONNECT:"$LOG/qmp.sock" >/dev/null; exit 0; fi
OUT=$1; LOG=${2:-/tmp/churro-qemu}
printf '{"execute":"qmp_capabilities"}\n{"execute":"screendump","arguments":{"filename":"%s","format":"png"}}\n' "$OUT" \
  | timeout 5 socat - UNIX-CONNECT:"$LOG/qmp.sock" >/dev/null
ls -la "$OUT"
