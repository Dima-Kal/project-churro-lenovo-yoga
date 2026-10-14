#!/usr/bin/env bash
# Dev helper: restore pristine vbmeta_a + selected logical partitions (default vendor_a) from the
# original recovery image into a test image, so churro.sh can be re-run in place quickly.
# Usage: tools/dev-restore.sh <original.bin> <test.img> [lp partition]...
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
ORIG=$1 IMG=$2; shift 2; LPS=${*:-vendor_a}
sect() { sgdisk -p "$ORIG" | awk -v l="$1" '$NF == l {print $2, $3 - $2 + 1}'; }
copy() { dd if="$ORIG" of="$IMG" bs=4M iflag=skip_bytes,count_bytes oflag=seek_bytes skip="$1" seek="$1" count="$2" conv=notrunc status=none; }
read -r s n < <(sect vbmeta_a); copy $((s * 512)) $((n * 512)); echo "restored vbmeta_a"
read -r s n < <(sect super)
copy $((s * 512)) $((1024 * 1024)); echo "restored LP metadata"   # churro may relocate partitions
T=$(mktemp)
dd if="$ORIG" of="$T" bs=1M skip=$((s * 512)) iflag=skip_bytes,count_bytes count=$((64 * 1024)) status=none
for lp in $LPS; do
  read -r off size < <(python3 "$HERE/lib/lpinfo.py" "$T" "$lp")
  copy $((s * 512 + off)) "$size"; echo "restored $lp"
done
rm -f "$T"
