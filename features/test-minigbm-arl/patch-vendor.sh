#!/usr/bin/env bash
# TEST ONLY (not a default feature): Google's minigbm (buffer allocator + mapper) only accepts the
# GPU IDs compiled into it; Arrow Lake isn't there ("Xe driver is not supported on your platform:
# 0x7d67") although it is the same graphics generation (Xe-LPG) as Meteor Lake.
# The ID lists are compiled to immediate compares, not read from a table (patching the .rodata
# copy did nothing). Meteor Lake = a bitmask test for 7d40/7d45/7d55/7d60 plus a lone
# `cmp $0x7dd5,%eax` (bytes 3d d5 7d 00 00). We retarget that compare to 7d67, so Arrow Lake takes
# the Meteor Lake path and MTL model 7dd5 stops working with this image.
# Two compare sites per lib (two copies of the ID lookup); refuse to patch on any other count.
# The real fix is our own allocator (docs/05).
set -euo pipefail
T=$1
for f in "$T"/lib64/libminigbm_gralloc.so "$T"/lib64/libgbm.so; do
  offs=$(LC_ALL=C grep -obUaP '\x3d\xd5\x7d\x00\x00' "$f" | cut -d: -f1)
  [ "$(echo "$offs" | grep -c .)" = 2 ] || { echo "   vendor: $(basename "$f"): expected 2 'cmp 0x7dd5' sites, not patched" >&2; continue; }
  for o in $offs; do printf '\x67' | dd of="$f" bs=1 seek=$((o + 1)) conv=notrunc status=none; done   # in place: keeps xattrs
  echo "   vendor: $(basename "$f"): GPU id 7dd5 -> 7d67 at 2 sites (TEST)"
done
