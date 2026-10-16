#!/usr/bin/env bash
# Replace the image's minigbm (graphics buffer allocator) libraries with our build of the same
# source (gfx/build-minigbm.sh + gfx/minigbm-patches/): Google's build rejects any GPU missing
# from its ID tables (e.g. Arrow Lake), ours accepts every Intel Xe GPU. The allocator service,
# mapper and gralloc0 module stay Google's and load these. Written in place: labels are kept.
set -euo pipefail
T=$1; O=${CHURRO_CACHE:-/var/cache/churro}/minigbm
bash "$CHURRO_HERE/gfx/build-minigbm.sh" "$O" "$T"
for so in libminigbm_gralloc.so libgbm.so; do cat "$O/out/$so" > "$T/lib64/$so"; done
echo "   vendor: minigbm built from source (any Intel Xe GPU, not just Google's ID list)"
