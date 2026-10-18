#!/bin/sh
# churro-cputier — classify this CPU for Project Churro (reads /proc/cpuinfo flags).
# The image's userspace is built -march=pantherlake: it uses GFNI, AVX-VNNI (VEX) and
# AVX-IFMA (VEX) unconditionally, on top of AVX2/BMI2. This reports what the machine
# needs in order to boot. Classify another CPU: CPUINFO=/path/to/cpuinfo churro-cputier
c="${CPUINFO:-/proc/cpuinfo}"
f=" $(grep -m1 '^flags' "$c" | cut -d: -f2) "
has() { case "$f" in *" $1 "*) return 0;; *) return 1;; esac; }
has avx512_vnni || has avx512vnni; v512=$?
has avx512ifma  || has avx512_ifma; i512=$?

if ! has avx2 || ! has bmi2; then
  echo "UNSUPPORTED: no AVX2/BMI2 (pre-Haswell, or an Atom without AVX)"; exit 1
fi
if ! has gfni; then
  echo "TIER 2: no GFNI (Haswell..Comet Lake, Zen 1-3) - needs GFNI+VNNI+IFMA emulation (not implemented)"; exit 1
fi
miss=""
has avx_vnni || miss="$miss avx-vnni"
has avx_ifma || miss="$miss avx-ifma"
if [ -z "$miss" ]; then
  echo "NATIVE: boots as-is (Arrow/Lunar/Panther Lake, Zen 5)"; exit 0
fi
hard=""
case "$miss" in *avx-vnni*) [ $v512 -eq 0 ] || hard="$hard avx-vnni";; esac
case "$miss" in *avx-ifma*) [ $i512 -eq 0 ] || hard="$hard avx-ifma";; esac
if [ -z "$hard" ]; then
  echo "TIER 1 (easy): missing$miss - re-encode to AVX-512 (Ice/Tiger/Rocket Lake, Zen 4)"
else
  echo "TIER 1 (hard): no AVX-512 form for$hard - needs true emulation (Alder/Raptor/Meteor Lake)"
fi
