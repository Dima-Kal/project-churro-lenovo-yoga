#!/usr/bin/env bash
# Build a "Churro kernel": Google's own GKI source at the image's exact commit, with the image's
# own config, plus extra drivers and without KMI symbol trimming. Same release string, same
# CRCs (gendwarfksyms over identical types) -> the image's vendor_dlkm/system_dlkm modules keep
# loading, but we can now add drivers the stock GKI can't take as modules (i915, simpledrm, ahci...).
#
# Usage: kmod/build-kernel.sh <ack src> <clang dir> <rust dir> <bindgen dir> <ikconfig> <kernel release> <profile> <out dir>
#   profile = kmod/profiles/<name>.conf with:  Y="SYSFB_SIMPLEFB ..."  M="DRM_I915 ..."  N="..."
set -euo pipefail
SRC=$1 CLANG=$2 RUST=$3 BINDGEN=$4 CFG=$5 REL=$6 PROF=$7 OUT=$8
HERE=$(cd "$(dirname "$0")" && pwd)
Y="" M="" N=""; . "$HERE/profiles/$PROF.conf"
export PATH="$CLANG/bin:$RUST/bin:$BINDGEN:$PATH"
# bindgen must use the Android clang's libclang, not a distro one (unknown -W options otherwise)
export LIBCLANG_PATH="$CLANG/lib"
O=$SRC/out-kernel-$PROF; mkdir -p "$O"
# kmod/patches/*.patch: small built-in fixes (no exported types touched -> CRCs unchanged).
# Applied copies are recorded in $SRC/.churro-applied: a patch that was edited or deleted since
# is reversed first, so the cached source tree always matches kmod/patches.
A=$SRC/.churro-applied; mkdir -p "$A"
for a in "$A"/*.patch; do
  [ -e "$a" ] || continue
  cmp -s "$a" "$HERE/patches/${a##*/}" || { patch -d "$SRC" -p1 -R -s < "$a"; rm "$a"; }
done
for p in "$HERE"/patches/*.patch; do
  [ -e "$p" ] && [ ! -e "$A/${p##*/}" ] || continue
  patch -d "$SRC" -p1 -s -N < "$p"; cp "$p" "$A/"
done
# KBUILD_GENDWARFKSYMS_STABLE: GKI computes symbol CRCs in "--stable" (kABI-aware) mode; without
# it every CRC touching a struct differs and vendor modules fail with "disagrees about version".
MK=(make -C "$SRC" -j"$(nproc)" LLVM=1 LLVM_IAS=1 ARCH=x86_64 O="$O" KBUILD_GENDWARFKSYMS_STABLE=1)
cp "$CFG" "$O/.config"; cp "$O/.config" "$O/.config.orig"
SC() { "$SRC/scripts/config" --file "$O/.config" "$@"; }
# same release string as the GKI build so vermagic matches the image's prebuilt modules
# (keep LOCALVERSION_AUTO: MODULE_SCMVERSION depends on it and changes struct module, i.e. the
#  module_layout CRC every vendor module checks; a source tarball has no SCM info to append anyway)
SC --set-str LOCALVERSION "-${REL#*-}"
# keep every export (no KMI trimming); unsigned (vendor) modules allowed
SC -d TRIM_UNUSED_KSYMS -d MODULE_SIG_FORCE
# Trust Google's GKI module signing key (from the image's vmlinux, tools/extract-certs.sh): GKI
# modules carry "protected" export flags baked in by Google's modpost, and a module whose
# signature we can't verify may not use them (system_dlkm zram -> zsmalloc refused otherwise).
[ -n "${CHURRO_GKI_CERTS:-}" ] && SC --set-str SYSTEM_TRUSTED_KEYS "$(realpath "$CHURRO_GKI_CERTS")"
for c in $Y; do SC -e "$c"; done; for c in $M; do SC -m "$c"; done; for c in $N; do SC -d "$c"; done
"${MK[@]}" olddefconfig >/dev/null
for f in $(grep -oE '_LIST="[^"]+"' "$O/.config" | cut -d'"' -f2); do [ -e "$SRC/$f" ] || : > "$SRC/$f"; done
echo "== config delta vs shipped kernel:"
diff <(grep -E '^CONFIG_' "$O/.config.orig" | sort) <(grep -E '^CONFIG_' "$O/.config" | sort) | grep -E '^[<>]' || true
echo "$(cat "$O/include/config/kernel.release" 2>/dev/null)"
"${MK[@]}" bzImage modules 2>&1 | grep -E 'error|Error|WARNING: modpost' | head -40 || true
mkdir -p "$OUT/modules"
cp "$O/arch/x86/boot/bzImage" "$OUT/kernel"
cat "$O/include/config/kernel.release" > "$OUT/kernel.release"
"${MK[@]}" INSTALL_MOD_PATH="$OUT/modroot" INSTALL_MOD_STRIP=1 modules_install >/dev/null
echo "built $(cat "$OUT/kernel.release") -> $OUT"
