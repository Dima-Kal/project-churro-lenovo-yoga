#!/usr/bin/env bash
# Build the "virt" module pack (virtio-gpu, virtio-input, ...) from Google's own GKI CI build
# that matches the Googlebook kernel (same build id -> same KMI/CRCs, loads as-is).
# Usage: tools/fetch-virt-pack.sh <gki build id, e.g. 16302624> <out pack dir>
set -euo pipefail
BID=$1; OUT=$2
# virtio_pci* are already in the image's system_dlkm (GKI-signed); these unsigned copies would be
# refused ("Cannot use protected symbol"). virtio-gpu only needs to be registered early - it binds
# once ueventd loads virtio_pci in second stage.
WANT="virtio_dma_buf virtio-gpu virtio_input"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -fsSL -o "$T/initramfs.img" "https://ci.android.com/builds/submitted/$BID/kernel_virt_x86_64/latest/raw/initramfs.img"
(cd "$T" && mkdir x && cd x && lz4 -dc ../initramfs.img | cpio -idm --quiet)
MD=$(dirname "$(find "$T/x" -name modules.dep | head -1)")
mkdir -p "$OUT"; : > "$OUT/modules.load"; : > "$OUT/modules.dep"
for m in $WANT; do
  f=$(find "$MD" -name "$m.ko" | head -1); [ -n "$f" ] || { echo "missing $m" >&2; exit 1; }
  cp "$f" "$OUT/"; echo "$m.ko" >> "$OUT/modules.load"
  rel=${f#"$MD"/}
  grep "^$rel:" "$MD/modules.dep" | sed -E 's#[^ :]*/##g' >> "$OUT/modules.dep"
done
echo "pack ready: $OUT"; cat "$OUT/modules.dep"
