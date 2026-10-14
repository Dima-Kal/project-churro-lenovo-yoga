#!/usr/bin/env bash
# Extract the X.509 certificates built into a kernel (vmlinux) as PEM.
# Used to make the Churro kernel trust Google's GKI module signing key: GKI modules on
# system_dlkm (zram, ...) are signed with a per-build key, and a module whose signature the
# kernel can't verify may not use "protected" GKI exports (zram -> zsmalloc fails otherwise).
# Usage: tools/extract-certs.sh <vmlinux> > certs.pem
set -euo pipefail
V=$1
# Candidates: DER SEQUENCE headers "30 82 LL LL 30 82" (a certificate starts with two of them).
LC_ALL=C grep -obUaP '\x30\x82..\x30\x82' "$V" | cut -d: -f1 | while read -r off; do
  len=$(( $(od -An -tu1 -j $((off + 2)) -N1 "$V") * 256 + $(od -An -tu1 -j $((off + 3)) -N1 "$V") + 4 ))
  [ "$len" -lt 4096 ] || continue
  dd if="$V" bs=1 skip="$off" count="$len" status=none | openssl x509 -inform DER -outform PEM 2>/dev/null || true
done
