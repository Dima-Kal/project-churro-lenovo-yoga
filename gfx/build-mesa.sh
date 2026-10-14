#!/usr/bin/env bash
# Build Mesa for Android x86_64 with the NDK (no AOSP tree needed: -Dandroid-stub=true).
# Gives Churro GPU support the Googlebook vendor image lacks:
#   GL/GLES (ro.hardware.egl=mesa): iris (Intel Gen8+, e.g. Broadwell HD 5300), crocus (Gen4-7),
#                                   virgl (QEMU virtio-gpu-gl), softpipe (software, any GPU)
#   Vulkan (ro.hardware.vulkan=...): intel_hasvk (Gen7/8), radeon (AMD via RADV/ACO)
# Usage: gfx/build-mesa.sh <work dir>      -> <work dir>/install/... (meson DESTDIR)
set -euo pipefail
WORK=$1
MESA_VER=${MESA_VER:-26.2.4}
NDK_VER=${NDK_VER:-r28c}
API=${ANDROID_API:-35}
mkdir -p "$WORK"; cd "$WORK"
# Mesa 26 needs meson >= 1.4 (Ubuntu 24.04 ships 1.3): private venv with the python bits
[ -x venv/bin/meson ] || { python3 -m venv venv && venv/bin/pip -q install 'meson>=1.4' mako pyyaml ply packaging; }
export PATH=$WORK/venv/bin:$PATH
[ -d "android-ndk-$NDK_VER" ] || { curl -fsSL -o ndk.zip "https://dl.google.com/android/repository/android-ndk-$NDK_VER-linux.zip"; unzip -q ndk.zip; rm ndk.zip; }
[ -d "mesa-$MESA_VER" ] || curl -fsSL "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" | tar -xJ
NDK=$WORK/android-ndk-$NDK_VER; TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
cat > cross-android-x86_64 <<EOF
[binaries]
ar = '$TC/llvm-ar'
c = ['$TC/x86_64-linux-android$API-clang']
cpp = ['$TC/x86_64-linux-android$API-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$TC/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$WORK/pkgconfig', '/usr/bin/pkg-config']
[host_machine]
system = 'android'
cpu_family = 'x86_64'
cpu = 'amd64'
endian = 'little'
EOF
mkdir -p pkgconfig
cd "mesa-$MESA_VER"
# Intel drivers precompile OpenCL-C kernels at build time: build the host tools (mesa_clc,
# vtn_bindgen2) natively first - they need LLVM/Clang/libclc/SPIRV-LLVM-Translator on the host.
if [ ! -x "$WORK/host-tools/bin/mesa_clc" ]; then
  apt-get install -y -qq llvm-18-dev libclang-18-dev libclc-18-dev libllvmspirvlib-18-dev clang-18 \
    libdrm-dev libexpat1-dev zlib1g-dev >/dev/null
  rm -rf build-host
  meson setup build-host --prefix="$WORK/host-tools" --buildtype release \
    -Dgallium-drivers= -Dvulkan-drivers= -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled \
    -Dllvm=enabled -Dshared-llvm=enabled -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
    -Dprecomp-compiler=enabled -Dinstall-precomp-compiler=true 2>&1 | tail -5
  ninja -C build-host 2>&1 | tail -3
  meson install -C build-host --no-rebuild >/dev/null
fi
export PATH=$WORK/host-tools/bin:$PATH
# libdrm for the target (Mesa won't take it as a subproject here): cross-build into a sysroot
LIBDRM_VER=${LIBDRM_VER:-2.4.133}
SYS=$WORK/sysroot
if [ ! -f "$SYS/lib64/pkgconfig/libdrm.pc" ]; then
  (cd "$WORK" && { [ -d "libdrm-$LIBDRM_VER" ] || curl -fsSL "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM_VER.tar.xz" | tar -xJ; } \
   && cd "libdrm-$LIBDRM_VER" && rm -rf build-android \
   && meson setup build-android --cross-file ../cross-android-x86_64 --prefix=/ --libdir lib64 --buildtype release \
        -Ddefault_library=static \
        -Dintel=disabled -Damdgpu=enabled -Dradeon=enabled -Dnouveau=disabled -Dvmwgfx=disabled \
        -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false | tail -3 \
   && ninja -C build-android | tail -2 && DESTDIR=$SYS meson install -C build-android --no-rebuild >/dev/null)
  sed -i "s#^prefix=.*#prefix=$SYS#" "$SYS"/lib64/pkgconfig/*.pc
fi
sed -i "s#PKG_CONFIG_LIBDIR=[^']*#PKG_CONFIG_LIBDIR=$SYS/lib64/pkgconfig#" ../cross-android-x86_64
rm -rf build-android
meson setup build-android --cross-file ../cross-android-x86_64 \
  --libdir lib64 --buildtype release -Db_ndebug=true \
  -Dplatforms=android -Dplatform-sdk-version=$API -Dandroid-stub=true -Dandroid-libbacktrace=disabled \
  -Dgallium-drivers=iris,crocus,virgl,softpipe -Dvulkan-drivers=intel_hasvk,amd \
  -Dllvm=disabled -Dgbm=disabled -Dglx=disabled -Degl=enabled -Dgles1=enabled -Dgles2=enabled \
  -Degl-lib-suffix=_mesa -Dgles-lib-suffix=_mesa \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled -Dmesa-clc=system -Dprecomp-compiler=system \
  --force-fallback-for=expat -Dexpat:default_library=static 2>&1 | tail -40
# libdrm/expat are linked statically: Android's "sphal" linker namespace (where apps load EGL/Vulkan
# drivers) only sees LL-NDK + same-process-HAL libs, not the vendor's own libdrm/libexpat.
ninja -C build-android 2>&1 | tail -15
rm -rf "$WORK/install"; DESTDIR=$WORK/install meson install -C build-android --no-rebuild --strip >/dev/null
find "$WORK/install" -name '*.so*' | head -40
