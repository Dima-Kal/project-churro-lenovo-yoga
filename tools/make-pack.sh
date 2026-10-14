#!/usr/bin/env bash
# Make a module pack (for churro.sh --modules) out of a kernel module tree, pulling in deps.
# Usage: tools/make-pack.sh <modroot/lib/modules/<release>> <out pack dir> <module name>...
#   e.g. tools/make-pack.sh kernel-generic/modroot/lib/modules/6.18.21-... packs/i915 i915 ahci
set -euo pipefail
MD=$1 OUT=$2; shift 2
[ -f "$MD/modules.dep" ] || { echo "no modules.dep in $MD" >&2; exit 1; }
mkdir -p "$OUT"; : > "$OUT/modules.load"; : > "$OUT/modules.dep"
declare -A seen
path_of() { grep -E "(^|/)$1\.ko:" "$MD/modules.dep" | head -1 | cut -d: -f1; }
add() {  # depth-first: deps before the module itself
  local rel=$1 d; [ -n "${seen[$rel]:-}" ] && return 0; seen[$rel]=1
  for d in $(grep -E "^$rel:" "$MD/modules.dep" | cut -d: -f2); do add "$d"; done
  cp "$MD/$rel" "$OUT/"; basename "$rel" >> "$OUT/modules.load"
  grep -E "^$rel:" "$MD/modules.dep" | sed -E 's#[^ :]*/##g' >> "$OUT/modules.dep"
}
for m in "$@"; do
  p=$(path_of "${m//_/[_-]}") || true; [ -n "$p" ] || { echo "module not found: $m" >&2; exit 1; }
  add "$p"
done
echo "pack $OUT: $(wc -l < "$OUT/modules.load") modules"; cat "$OUT/modules.load" | tr '\n' ' '; echo
