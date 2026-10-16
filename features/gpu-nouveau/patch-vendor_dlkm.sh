#!/usr/bin/env bash
# NVIDIA GPUs (nouveau) on machines where nothing else drives the display (discrete-only laptops,
# desktops without an iGPU): our kernel build's nouveau.ko joins the image's vendor_dlkm modules,
# loaded by ueventd when an NVIDIA GPU shows up (modules.alias). Its firmware comes from firmware-extra (vendor_dlkm
# is repacked first, so nouveau's firmware list is seen there). Hybrid machines: nouveau sees the
# other display controller and doesn't bind (kmod/patches/nouveau-hybrid-guard.patch).
# ABI: nouveau links against the image's own drm helper modules (Google's builds), so every
# symbol it takes from them must exist there with the same CRC. Where Google's copy lacks one
# (drm_ttm_helper: no fbdev console in the GKI config), our build of that module replaces it -
# only if it exports everything Google's does with identical CRCs, so its other users (xe) keep
# loading. Anything else: refuse to build.
set -euo pipefail
T=$1; D=$T/lib/modules; MP=/vendor/lib/modules
MD=$(ls -d "${CHURRO_KERNEL:?gpu-nouveau needs the Churro kernel (--kernel)}"/modroot/lib/modules/*/)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export LC_ALL=C
ours() { find "$MD" -name "$1.ko" | head -1; }
sec() { readelf -SW "$1" | sed 's/^ *\[ *//; s/\]//' | awk -v n="$2" '$2 ~ n {print $1, $5, $6}'; }
# exports <ko>: "sym crc" per exported symbol (__crc_<sym> symbols point into __kcrctab*)
exports() {
  local f=$1 idx off size
  sec "$f" '^__kcrctab' | while read -r idx off size; do
    od -An -tx4 -v -w4 -j $((16#$off)) -N $((16#$size)) "$f" | awk -v i="$idx" '{print i ":" (NR-1)*4, $1}'
  done | sort > "$W/val"
  readelf -sW "$f" | awk '$8 ~ /^__crc_/ {print $7, $2, substr($8, 7)}' | while read -r ndx v s; do
    echo "$ndx:$((16#$v)) $s"; done | sort > "$W/sym"
  join "$W/sym" "$W/val" | awk '{print $2, $3}' | sort
}
# imports <ko>: "sym crc" per symbol it needs (__versions + extended modversions)
imports() {
  local f=$1 x no ns co cs
  modprobe --dump-modversions "$f" | awk '{sub(/^0x/, "", $1); print $2, $1}'
  read -r x no ns < <(sec "$f" '^__version_ext_names$') || return 0
  read -r x co cs < <(sec "$f" '^__version_ext_crcs$')
  paste -d' ' <(tail -c +$((16#$no + 1)) "$f" | head -c $((16#$ns)) | tr '\0' '\n' | grep .) \
              <(od -An -tx4 -v -w4 -j $((16#$co)) -N $((16#$cs)) "$f" | awk '{print $1}')
}

N=$(ours nouveau); [ -n "$N" ] || { echo "gpu-nouveau: no nouveau.ko in $MD (profile without DRM_NOUVEAU?)" >&2; exit 1; }
deps=() q=($(modinfo -F depends "$N" | tr ',' ' '))           # dependency closure, our build's view
while [ ${#q[@]} -gt 0 ]; do
  m=${q[0]}; q=("${q[@]:1}"); [[ " ${deps[*]} " == *" $m "* ]] && continue
  deps+=("$m"); q+=($(modinfo -F depends "$(ours "$m")" | tr ',' ' '))
done
inst=(nouveau)                                                 # modules we install
while :; do
  n=${#inst[@]}
  for m in "${inst[@]}"; do imports "$(ours "$m")"; done | sort -u > "$W/need"
  for m in "${deps[@]}"; do
    [[ " ${inst[*]} " == *" $m "* ]] && continue
    [ -f "$D/$m.ko" ] || { inst+=("$m"); continue; }           # the image doesn't have it
    exports "$(ours "$m")" > "$W/o"; exports "$D/$m.ko" > "$W/g"
    join "$W/need" "$W/o" | awk '{print $1, $2}' | comm -23 - "$W/g" > "$W/miss"
    [ -s "$W/miss" ] || continue                               # Google's copy serves us
    if comm -23 "$W/g" "$W/o" | grep -q .; then
      echo "gpu-nouveau: the image's $m.ko lacks/differs on symbols nouveau needs, and our build can't stand in for it:" >&2
      head "$W/miss" >&2; exit 1
    fi
    echo "   vendor_dlkm: $m.ko replaced by our build (same exports and CRCs, plus: $(cut -d' ' -f1 "$W/miss" | tr '\n' ' '))"
    inst+=("$m")
  done
  [ ${#inst[@]} = "$n" ] && break
done

lbl=$(getfattr --absolute-names --only-values -n security.selinux "$(ls "$D"/*.ko | head -1)")
for m in "${inst[@]}"; do
  install -m 0644 -o root -g root "$(ours "$m")" "$D/$m.ko"; setfattr -n security.selinux -v "$lbl" "$D/$m.ko"
done
# dependency lines from depmod over the whole set, paths as the image has them
rel=$(basename "$MD"); R=$W/dm/lib/modules/$rel; mkdir -p "$R"; ln -s "$D"/*.ko "$R/"; depmod -b "$W/dm" "$rel" 2>/dev/null
for m in "${inst[@]}"; do
  grep -v "^$MP/$m.ko:" "$D/modules.dep" > "$W/dep" || true
  grep "^$m.ko:" "$R/modules.dep" | sed -E "s#([^ :]+\.ko)#$MP/\1#g" >> "$W/dep"
  cat "$W/dep" > "$D/modules.dep"                              # in place: keeps the SELinux label
done
# ueventd loads vendor_dlkm modules by device alias (like xe): nouveau only where an NVIDIA GPU is
for m in "${inst[@]}"; do
  modinfo -F alias "$D/$m.ko" | while read -r a; do
    grep -qxF "alias $a ${m//-/_}" "$D/modules.alias" || echo "alias $a ${m//-/_}" >> "$D/modules.alias"; done
done
echo "   vendor_dlkm: + ${inst[*]} ($(modinfo -F firmware "$N" | grep -c .) firmware names for firmware-extra)"
