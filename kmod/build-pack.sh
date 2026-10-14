#!/usr/bin/env bash
# Build extra kernel modules against the exact GKI kernel shipped in a Googlebook image.
# Inputs: ACK source tree at the image's commit, its clang, the image's IKCONFIG and
# Google's vmlinux.symvers for the same build -> modules with matching vermagic + CRCs.
#
# Usage: kmod/build-pack.sh <ack src> <clang dir> <ikconfig> <vmlinux.symvers> <pack name> <out dir>
# Pack definitions live in kmod/packs/<name>.conf:  CONFIGS="DRM_I915 ..."  DIRS="drivers/gpu/drm/i915 ..."
set -euo pipefail
SRC=$1 CLANG=$2 CFG=$3 SYMVERS=$4 PACK=$5 OUT=$6
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/packs/$PACK.conf"
export PATH="$CLANG/bin:$PATH"
MK=(make -C "$SRC" -j"$(nproc)" LLVM=1 LLVM_IAS=1 ARCH=x86_64 O="$SRC/out-churro")
mkdir -p "$SRC/out-churro"
cp "$CFG" "$SRC/out-churro/.config"
cp "$SRC/out-churro/.config" "$SRC/out-churro/.config.orig"
# unsigned vendor modules are fine on GKI (MODULE_SIG_PROTECT only guards GKI's own symbols)
"$SRC/scripts/config" --file "$SRC/out-churro/.config" -d MODULE_SIG_ALL -d TRIM_UNUSED_KSYMS -d MODULE_SIG_PROTECT
for c in $CONFIGS; do "$SRC/scripts/config" --file "$SRC/out-churro/.config" -m "$c"; done
"${MK[@]}" olddefconfig >/dev/null
# anything that flipped to =y would have to live in vmlinux -> report it, it won't work as a module
echo "== config changes vs shipped kernel:"
diff <(grep -E '^CONFIG_' "$SRC/out-churro/.config.orig" | sort) <(grep -E '^CONFIG_' "$SRC/out-churro/.config" | sort) | grep -E '^[<>]' || true
"${MK[@]}" modules_prepare >/dev/null
cp "$SYMVERS" "$SRC/out-churro/Module.symvers"
# GKI's modpost wants its protected-module list; vendor modules are by definition not on it
for f in $(grep -oE 'MODULE_SIG_PROTECT_LIST="[^"]+"|PROTECTED_EXPORTS_LIST="[^"]+"' "$SRC/out-churro/.config" | cut -d'"' -f2); do
  [ -e "$SRC/$f" ] || : > "$SRC/$f"; done
for d in $DIRS; do
  echo "== building $d"
  "${MK[@]}" KBUILD_MODPOST_WARN=1 M="$d" modules 2>&1 | grep -E 'WARNING|ERROR|error:' || true
done
mkdir -p "$OUT"
# kbuild writes M=<in-tree dir> objects next to the sources
for d in $DIRS; do find "$SRC/$d" -name '*.ko' -newer "$SRC/out-churro/.config" -exec cp {} "$OUT/" \; ; done
ls -la "$OUT"
