#!/usr/bin/env bash
# GKI 6.18 is built with pahole 1.31 (BTF); distro 1.25 produces BTF the kernel's resolve_btfids
# rejects. Build the matching pahole into the given bin dir.
set -euo pipefail
OUT=${1:?bin dir}; VER=${PAHOLE_VER:-v1.31}
command -v cmake >/dev/null || apt-get install -y -qq cmake >/dev/null
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git clone -q --depth 1 -b "$VER" https://git.kernel.org/pub/scm/devel/pahole/pahole.git "$T/src" 2>/dev/null \
  || git clone -q --depth 1 -b "$VER" https://github.com/acmel/dwarves.git "$T/src"
cmake -S "$T/src" -B "$T/b" -D__LIB=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
make -C "$T/b" -s -j"$(nproc)" pahole >/dev/null
mkdir -p "$OUT"; cp "$T/b/pahole" "$OUT/pahole"; "$OUT/pahole" --version
