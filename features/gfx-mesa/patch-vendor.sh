#!/usr/bin/env bash
# Add Mesa (built by gfx/build-mesa.sh) to the vendor partition and make the GL/Vulkan driver
# selectable at boot (androidboot.churro.gfx=native|mesa), instead of the hardcoded
# ro.hardware.egl=angle / ro.hardware.vulkan=intel (Intel Gen12+ only).
# Usage: patch-vendor.sh <extracted vendor tree>       env: CHURRO_MESA=<mesa install dir>
set -euo pipefail
V=$1
M=${CHURRO_MESA:?set CHURRO_MESA to the meson DESTDIR of gfx/build-mesa.sh}
L=$(find "$M" -type d -name lib64 | head -1)
SPHAL=u:object_r:same_process_hal_file:s0
put() { install -D -m 0644 -o root -g root "$1" "$2"; setfattr -n security.selinux -v "$SPHAL" "$2"; }

# 1. drivers: EGL/GLES (loaded by name from lib64/egl), Vulkan HALs (lib64/hw/vulkan.<name>.so)
mkdir -p "$V/lib64/egl"; setfattr -n security.selinux -v u:object_r:vendor_file:s0 "$V/lib64/egl"
for f in "$L"/libEGL_mesa.so "$L"/libGLESv1_CM_mesa.so "$L"/libGLESv2_mesa.so; do
  [ -f "$f" ] && put "$f" "$V/lib64/egl/$(basename "$f")"; done
# Vulkan drivers are big (~20 MB each): only the requested ones (CHURRO_MESA_VULKAN="radeon intel_hasvk")
for vk in ${CHURRO_MESA_VULKAN:-}; do
  [ -f "$L/libvulkan_$vk.so" ] && put "$L/libvulkan_$vk.so" "$V/lib64/hw/vulkan.$vk.so"
done

# 2. their non-platform dependencies (libgallium-*.so, libdrm_amdgpu.so, ...), closure
todo=("$V"/lib64/egl/*_mesa.so "$V"/lib64/hw/vulkan.radeon.so "$V"/lib64/hw/vulkan.intel_hasvk.so); added=""
while [ ${#todo[@]} -gt 0 ]; do
  f=${todo[0]}; todo=("${todo[@]:1}"); [ -f "$f" ] || continue
  for n in $(readelf -d "$f" | awk '/NEEDED/ {gsub(/[][]/, "", $NF); print $NF}'); do
    [ -e "$V/lib64/$n" ] && continue
    src=$(find "$M" "${CHURRO_MESA_SYSROOT:-/nonexistent}" -name "$n" -type f 2>/dev/null | head -1)
    [ -n "$src" ] || continue                       # LL-NDK (libc, liblog, libnativewindow, ...)
    put "$src" "$V/lib64/$n"; added="$added $n"; todo+=("$V/lib64/$n")
  done
done

# 3. graphics props move from build.prop to boot-time selection (see zz-churro-gfx.rc)
sed -i -E '/^(ro\.hardware\.egl|ro\.hardware\.vulkan|ro\.hwui\.use_vulkan|debug\.renderengine\.vulkan|debug\.renderengine\.backend)=/d' "$V/build.prop"
echo "   vendor: Mesa installed (+libs:$added)"

# 4. every DRM node is a GPU/display device. The image only labels card0/card1/renderD128/129;
# with simpledrm + vgem in front, the real GPU becomes card2 (labelled plain "device") and
# SurfaceFlinger/composer get SELinux denials -> abort loop. In place: keeps the file's xattr.
grep -q 'card\[0-9\]' "$V/etc/selinux/vendor_file_contexts" || cat >> "$V/etc/selinux/vendor_file_contexts" <<'EOF'
/dev/dri/card[0-9]+          u:object_r:gpu_device:s0
/dev/dri/renderD[0-9]+       u:object_r:gpu_device:s0
EOF
