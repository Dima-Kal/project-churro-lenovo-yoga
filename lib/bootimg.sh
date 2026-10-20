# shellcheck shell=bash
# Minimal Android boot image v4 / vendor_boot v4 extractor in pure bash.
# Layouts: https://source.android.com/docs/core/architecture/bootloader/boot-image-header

u32() { od -An -tu4 -j "$2" -N4 "$1" | tr -d ' '; }            # u32 LE at offset
align() { echo $(( ($1 + $2 - 1) / $2 * $2 )); }                 # align $1 up to $2
cstr() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | tr -d '\0'; }

# bootimg_extract <boot|init_boot partition/file> <outdir>
# writes outdir/kernel (if any) and outdir/ramdisk (if any)
bootimg_extract() {
  local img=$1 out=$2 page=4096
  for _ in {1..10}; do [ -e "$img" ] && break; sleep 0.5; done
  [ -e "$img" ] || { echo "image file not found: $img" >&2; return 1; }
  [ "$(cstr "$img" 0 8)" = "ANDROID!" ] || { echo "not a boot image: $img" >&2; return 1; }
  local hv; hv=$(u32 "$img" 40)
  [ "$hv" -ge 3 ] || { echo "boot header v$hv unsupported" >&2; return 1; }
  local ksz rsz; ksz=$(u32 "$img" 8); rsz=$(u32 "$img" 12)
  mkdir -p "$out"
  [ "$ksz" -gt 0 ] && dd if="$img" of="$out/kernel" bs=$page skip=1 iflag=count_bytes count="$ksz" status=none
  local roff=$(( page + $(align "$ksz" $page) ))
  [ "$rsz" -gt 0 ] && dd if="$img" of="$out/ramdisk" iflag=skip_bytes,count_bytes skip="$roff" count="$rsz" status=none
  return 0
}

# vendorboot_extract <vendor_boot> <outdir>
# writes outdir/cmdline, outdir/bootconfig, outdir/ramdisk_<idx>_<type>_<name>
vendorboot_extract() {
  local img=$1 out=$2
  for _ in {1..10}; do [ -e "$img" ] && break; sleep 0.5; done
  [ -e "$img" ] || { echo "image file not found: $img" >&2; return 1; }
  [ "$(cstr "$img" 0 8)" = "VNDRBOOT" ] || { echo "not a vendor_boot image: $img" >&2; return 1; }
  local page vrsz hsz dtbsz tsz tnum tesz bcsz
  page=$(u32 "$img" 12); vrsz=$(u32 "$img" 24); hsz=$(u32 "$img" 2096)
  dtbsz=$(u32 "$img" 2100); tsz=$(u32 "$img" 2112); tnum=$(u32 "$img" 2116)
  tesz=$(u32 "$img" 2120); bcsz=$(u32 "$img" 2124)
  mkdir -p "$out"
  cstr "$img" 28 2048 > "$out/cmdline"
  local rbase; rbase=$(align "$hsz" "$page")
  local tbase=$(( rbase + $(align "$vrsz" "$page") + $(align "$dtbsz" "$page") ))
  local i e sz off typ name
  for ((i = 0; i < tnum; i++)); do
    e=$(( tbase + i * tesz ))
    sz=$(u32 "$img" $e); off=$(u32 "$img" $((e + 4))); typ=$(u32 "$img" $((e + 8)))
    name=$(cstr "$img" $((e + 12)) 32); name=${name:-none}
    dd if="$img" of="$out/ramdisk_${i}_${typ}_${name}" iflag=skip_bytes,count_bytes \
       skip=$(( rbase + off )) count="$sz" status=none
  done
  local bcoff=$(( tbase + $(align "$tsz" "$page") ))
  dd if="$img" of="$out/bootconfig" iflag=skip_bytes,count_bytes skip="$bcoff" count="$bcsz" status=none
}
