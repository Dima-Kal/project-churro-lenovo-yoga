#!/usr/bin/env bash
# Put the boot logger into the Churro ramdisk as /churro/logger (static: runs before bionic exists).
set -euo pipefail
R=$1; mkdir -p "$R/churro"
${CC:-cc} -static -Os -s -Wall -o "$R/churro/logger" "$(dirname "$0")/logger.c"
chmod 0750 "$R/churro/logger"
