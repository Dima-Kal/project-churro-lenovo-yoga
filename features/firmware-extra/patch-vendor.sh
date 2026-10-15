#!/usr/bin/env bash
# Firmware the image's own drivers ask for but the Googlebook image doesn't ship (it only carries
# what its target needs, e.g. Panther Lake GPU firmware, its own Wi-Fi). Data-driven: the
# firmware names every vendor_dlkm/system_dlkm module declares (modinfo -F firmware) + extra.txt
# (names drivers build at runtime, e.g. Intel Bluetooth), fetched from a pinned linux-firmware
# tag into /vendor/firmware. Downloads are cached; names upstream doesn't have are remembered.
set -euo pipefail
T=$1; FW=$T/firmware
TAG=${CHURRO_LINUX_FIRMWARE:-20260916}
C=${CHURRO_CACHE:-/var/cache/churro}/linux-firmware-$TAG; mkdir -p "$C"; touch "$C/.missing"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

# The modules live on vendor_dlkm/system_dlkm (other LP partitions of the same super).
M=$(mktemp -d); trap 'rm -rf "$M"' EXIT
for p in vendor_dlkm_a system_dlkm_a; do
  read -r off size < <(python3 "$CHURRO_HERE/lib/lpinfo.py" "$CHURRO_SUPER" "$p") || continue
  L=$(losetup -f --show -r -o "$off" --sizelimit "$size" "$CHURRO_SUPER")
  "$EROFS_BIN/fsck.erofs" --extract="$M/$p" "$L" >/dev/null || true
  losetup -d "$L"
done

{ find "$M" -name '*.ko' -exec modinfo -F firmware {} + 2>/dev/null
  grep -vE '^\s*(#|$)' "$(dirname "$0")/extra.txt"; } | sort -u | while read -r f; do
  case $f in *'*'*|/*|*..*) continue ;; esac          # globs / odd paths: skip
  [ -e "$FW/$f" ] && continue                         # the image already has it
  grep -qxF "$f" "$C/.missing" && continue
  if [ ! -s "$C/$f" ]; then
    mkdir -p "$(dirname "$C/$f")"
    # linux-firmware moved some files into vendor dirs (iwlwifi-* -> intel/iwlwifi/); drivers
    # still ask for the old name, which is where it's installed.
    ok=0
    for u in "$f" "intel/iwlwifi/$f"; do
      curl -fsS --retry 3 -o "$C/$f.tmp" "$URL/$u?h=$TAG" 2>/dev/null && { ok=1; break; }
    done
    if [ $ok = 0 ]; then rm -f "$C/$f.tmp"; echo "$f" >> "$C/.missing"; continue; fi
    mv "$C/$f.tmp" "$C/$f"
  fi
  install -D -m 0644 -o root -g root "$C/$f" "$FW/$f"
  echo "$FW/$f"
done > "$M/added"

# New files and dirs get the firmware dir's SELinux label (vendor_firmware_file).
lbl=$(getfattr --only-values -n security.selinux "$FW")
find "$FW" | while read -r x; do
  getfattr --only-values -n security.selinux "$x" >/dev/null 2>&1 || setfattr -n security.selinux -v "$lbl" "$x"
done
echo "   vendor: +$(wc -l < "$M/added") firmware files ($( (cat "$M/added" | xargs -r du -cm | tail -1 | cut -f1) || echo 0) MiB) from linux-firmware $TAG"
