# shellcheck shell=bash
# Build a kernel bootconfig blob that is appended at the very end of the initrd.
# Format (Documentation/admin-guide/bootconfig.rst):
#   [data, NUL-padded to 4 bytes][u32 size][u32 checksum]["#BOOTCONFIG\n"]
# size = padded data size, checksum = 32-bit sum of all data bytes.

le32() { local v=$1; printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $(((v >> 24) & 255)); }

# bootconfig_pack <text file> <out blob>
bootconfig_pack() {
  local in=$1 out=$2 tmp
  tmp=$(mktemp)
  # one key=value per line, drop blanks/comments, terminate with NUL like Android's tooling
  grep -vE '^\s*(#|$)' "$in" > "$tmp"
  printf '\0' >> "$tmp"
  local sz pad sum
  sz=$(stat -c %s "$tmp"); pad=$(( (4 - sz % 4) % 4 ))
  head -c "$pad" /dev/zero >> "$tmp"
  sz=$(( sz + pad ))
  sum=$(od -An -v -tu1 "$tmp" | awk '{for (i = 1; i <= NF; i++) s += $i} END {printf "%d", s % 4294967296}')
  { cat "$tmp"; printf "$(le32 "$sz")"; printf "$(le32 "$sum")"; printf '#BOOTCONFIG\n'; } > "$out"
  rm -f "$tmp"
}
