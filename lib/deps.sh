# Host packages Churro needs (Debian/Ubuntu names). deps_ensure installs the missing ones in one go;
# on other distros it only lists them (install your distro's equivalents).
#   image: gdisk dosfstools parted grub-* cpio attr kmod openssl curl python3 binutils
#   kernel config/vmlinux extraction: lz4 zstd xz-utils bzip2 (extract-ikconfig fails with
#     "Cannot find kernel config" when the kernel's decompressor is missing)
#   builds (kernel, pahole, erofs-utils, Mesa, static helpers): the rest
CHURRO_PKGS="gdisk dosfstools parted grub-common grub-efi-amd64-bin cpio attr kmod openssl curl git unzip
  python3 python3-venv binutils lz4 zstd xz-utils bzip2 build-essential flex bison bc rsync pkg-config
  cmake ninja-build libssl-dev libelf-dev libdw-dev zlib1g-dev autoconf automake libtool liblz4-dev
  uuid-dev libselinux1-dev"

deps_ensure() {
  if ! command -v apt-get >/dev/null || ! command -v dpkg-query >/dev/null; then
    echo ">> not Debian/Ubuntu: make sure the equivalents of these are installed:" $CHURRO_PKGS; return 0
  fi
  local p miss=""
  for p in $CHURRO_PKGS; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || miss="$miss $p"; done
  [ -n "$miss" ] || return 0
  [ "$(id -u)" = 0 ] || { echo "churro: missing packages:$miss (run as root to install them)" >&2; exit 1; }
  echo ">> installing missing packages:$miss"
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $miss >/dev/null
}
