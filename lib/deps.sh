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
  local p miss=""
  if ! command -v apt-get >/dev/null || ! command -v dpkg-query >/dev/null; then
    echo ">> not Debian/Ubuntu: make sure the equivalents of these are installed:" $CHURRO_PKGS
  else
    for p in $CHURRO_PKGS; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' || miss="$miss $p"; done
  fi
  if [ -n "$miss" ]; then
    [ "$(id -u)" = 0 ] || { echo "churro: missing packages:$miss (run as root to install them)" >&2; exit 1; }
    echo ">> installing missing packages:$miss"
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $miss >/dev/null
  fi
  # erofs-utils that can extract SELinux xattrs isn't packaged (Ubuntu 24.04 has 1.7.1): built once
  # into tools/bin, which is not in git (a fresh clone or zip doesn't have it).
  local b=$HERE/tools/bin
  [ -x "$b/fsck.erofs" ] && [ -x "$b/dump.erofs" ] && [ -x "$b/mkfs.erofs" ] && return 0
  echo ">> building erofs-utils into tools/bin (once)"
  bash "$HERE/tools/build-erofs-utils.sh"
}
