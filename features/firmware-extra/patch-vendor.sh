#!/usr/bin/env bash
# Firmware the image's own drivers ask for but the Googlebook image doesn't ship (it only carries
# what its target needs, e.g. Panther Lake GPU firmware, its own Wi-Fi). Data-driven: the
# firmware names every vendor_dlkm/system_dlkm module declares (modinfo -F firmware) + extra.txt
# (names drivers build at runtime, e.g. Intel Bluetooth), minus skip.txt, fetched from a pinned
# linux-firmware tag into /vendor/firmware. Names linux-firmware only creates when installed
# (WHENCE "Link:", e.g. a dozen NVIDIA chips sharing one 60 MB GSP image) become hardlinks to a
# single copy. Downloads are cached; names upstream doesn't have are remembered.
set -euo pipefail
T=$1; FW=$T/firmware; F=$(dirname "$0")
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

# WHENCE links: "Link: nvidia/gb203 -> gb202" (a dir), "Link: x/a.bin -> ../y/a.bin" (a file)
[ -s "$C/WHENCE" ] || { curl -fsS --retry 3 -o "$C/WHENCE.tmp" "$URL/WHENCE?h=$TAG"; mv "$C/WHENCE.tmp" "$C/WHENCE"; }
declare -A LNK FIRST
while read -r a b; do LNK[$a]=$(realpath -m -s --relative-to=/ "/$(dirname "$a")/$b"); done \
  < <(sed -n 's/^Link: *\([^ ]*\) *-> *\([^ ]*\).*$/\1 \2/p' "$C/WHENCE")
# resolve <name>: the file stored in git behind a name (links on the name or any parent dir)
resolve() {
  local p=$1 pre rest n
  for n in 1 2 3 4 5 6 7 8; do
    pre=$p rest=
    while [ -z "${LNK[$pre]:-}" ] && [ "$pre" != "${pre%/*}" ]; do rest=/${pre##*/}$rest; pre=${pre%/*}; done
    [ -n "${LNK[$pre]:-}" ] || break
    p=${LNK[$pre]}$rest
  done
  echo "$p"
}
mapfile -t SKIP < <(grep -vE '^\s*(#|$)' "$F/skip.txt")
skip() { local s; for s in "${SKIP[@]}"; do case $1 in $s) return 0 ;; esac; done; return 1; }

{ find "$M" -name '*.ko' -exec modinfo -F firmware {} + 2>/dev/null
  grep -vE '^\s*(#|$)' "$F/extra.txt"; } | sort -u | while read -r f; do
  case $f in *'*'*|/*|*..*) continue ;; esac          # globs / odd paths: skip
  [ -e "$FW/$f" ] && continue                         # the image already has it
  skip "$f" && continue
  r=$(resolve "$f"); skip "$r" && continue
  grep -qxF "$r" "$C/.missing" && continue
  if [ ! -s "$C/$r" ]; then
    mkdir -p "$(dirname "$C/$r")"
    # linux-firmware moved some files into vendor dirs (iwlwifi-* -> intel/iwlwifi/); drivers
    # still ask for the old name, which is where it's installed.
    ok=0
    for u in "$r" "intel/iwlwifi/$r"; do
      curl -fsS --retry 3 -o "$C/$r.tmp" "$URL/$u?h=$TAG" 2>/dev/null && { ok=1; break; }
    done
    if [ $ok = 0 ]; then rm -f "$C/$r.tmp"; echo "$r" >> "$C/.missing"; continue; fi
    mv "$C/$r.tmp" "$C/$r"
  fi
  if [ -n "${FIRST[$r]:-}" ]; then mkdir -p "$(dirname "$FW/$f")"; ln "${FIRST[$r]}" "$FW/$f"
  else install -D -m 0644 -o root -g root "$C/$r" "$FW/$f"; FIRST[$r]=$FW/$f; fi
  echo "$FW/$f"
done > "$M/added"

# New files and dirs get the firmware dir's SELinux label (vendor_firmware_file).
lbl=$(getfattr --absolute-names --only-values -n security.selinux "$FW")
find "$FW" | while read -r x; do
  getfattr --absolute-names --only-values -n security.selinux "$x" >/dev/null 2>&1 || setfattr -n security.selinux -v "$lbl" "$x"
done
echo "   vendor: +$(wc -l < "$M/added") firmware files ($( (xargs -r du -cm < "$M/added" | tail -1 | cut -f1) || echo 0) MiB) from linux-firmware $TAG"
