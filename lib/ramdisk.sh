# shellcheck shell=bash
# Extra first-stage ramdisk: adds kernel modules from "module packs" on top of the
# vendor_boot dlkm ramdisk. A pack is a dir with *.ko + modules.load (+ optional modules.dep
# with bare file names, + optional firmware/ tree copied to /lib/firmware).

# ramdisk_build <workdir> [pack dir]...
ramdisk_build() {
  local W=$1; shift
  local R=$W/cr M; M=$W/cr/lib/modules
  mkdir -p "$M" "$W/dlkm"
  # start from the vendor dlkm ramdisk metadata so we extend rather than replace it
  (cd "$W/dlkm" && lz4 -dc "$W"/vboot/ramdisk_*_3_* | cpio -idm --quiet 2>/dev/null || true)
  cp "$W"/dlkm/lib/modules/modules.{load,dep,alias,softdep} "$M/" 2>/dev/null || true
  touch "$M/modules.load" "$M/modules.dep"
  local p ko
  for p in "$@"; do
    [ -d "$p" ] || { echo "module pack not found: $p" >&2; return 1; }
    while read -r ko; do
      [ -n "$ko" ] || continue
      cp "$p/$ko" "$M/"
      grep -qx "$ko" "$M/modules.load" || echo "$ko" >> "$M/modules.load"
    done < "$p/modules.load"
    if [ -f "$p/modules.dep" ]; then
      # pack deps use bare names: "a.ko: b.ko c.ko" -> first-stage init wants /lib/modules paths
      sed -E 's#([^ :]+\.ko)#/lib/modules/\1#g' "$p/modules.dep" >> "$M/modules.dep"
    fi
    [ -d "$p/firmware" ] && { mkdir -p "$R/lib/firmware"; cp -a "$p/firmware/." "$R/lib/firmware/"; }
  done
  # lz4 *legacy* like the vendor/generic ramdisks: the kernel's unlz4 cannot tell where a legacy
  # stream ends, so an uncompressed cpio after it fails with "Decoding failed" and is ignored.
  (cd "$R" && find . | cpio -o -H newc -R 0:0 --quiet) | lz4 -l -12 -q > "$W/churro.cpio"
}
