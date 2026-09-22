#!/usr/bin/env bash
# Builds formcut's LGPL ffmpeg for x86_64 Linux from the pinned sources, as the
# shipped build was made, and adds NVIDIA NVENC for H.264 and HEVC: header-only
# (nv-codec-headers, MIT), with the driver loaded at run time, so machines
# without it are unaffected and formcut's test encode skips it there.
#
# VA-API, the Intel and AMD route on Linux, is built in with libva and libdrm
# bundled beside ffmpeg's own libraries: ffmpeg links them at start-up, so a
# machine without them would otherwise not run ffmpeg at all. The bundled libva
# searches the usual driver directories of Debian and Ubuntu, Fedora, Arch and
# /usr/local, and loads the system's own Intel or AMD driver from there; where
# none loads, formcut's test encode skips VA-API and nothing else changes.
#
# Build on Ubuntu 22.04 or another glibc 2.35 system: the shipped build's floor.
# Needs gcc, make, nasm, pkg-config, patchelf, git, python3, meson and ninja.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/lbuild}
DEPS=$WORK/deps-linux
OUT=$WORK/install-linux
STAGE=$WORK/stage
TRIPLE=x86_64-unknown-linux-gnu
NVCODEC_TAG=n12.0.16.1
LIBDRM=libdrm-2.4.134
LIBDRM_SHA256=ac5e74d157830eb8bee44c6a6bf3ad49774ef0dd2a72bdad74a8f20308b52a95
LIBVA=libva-2.24.1
LIBVA_SHA256=eec6050b52876f229bd35e9df17cd31a06785e18e6f7990c445b584628483d67
VA_DRIVERS=/usr/lib/x86_64-linux-gnu/dri:/usr/lib64/dri:/usr/lib/dri:/usr/local/lib/dri
JOBS=$(nproc)
mkdir -p "$WORK" "$DEPS"
cd "$WORK"

echo "== fetching and verifying the pinned sources"
python3 - "$HERE" <<'PY'
import hashlib, json, pathlib, sys, urllib.request
here = pathlib.Path(sys.argv[1])
record = json.loads((here / "ffmpeg-licence.json").read_text())["source"]
archives = {"ffmpeg": "ffmpeg-7.1.5.tar.xz", "libopus": "libopus-1.6.1.tar.gz", "libvpx": "libvpx-1.17.0.tar.gz"}
for name, file in archives.items():
    archive = here / "dist" / file
    if not archive.exists():
        archive.parent.mkdir(exist_ok=True)
        print(f"   {file}: fetching {record[name]['url']}")
        urllib.request.urlretrieve(record[name]["url"], archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != record[name]["sha256"]:
        sys.exit(f"{archive.name}: sha256 {digest} is not the recorded {record[name]['sha256']}")
    print(f"   {archive.name}: matches the record")
PY

echo "== libopus"
rm -rf opus-1.6.1 && tar xf "$HERE/dist/libopus-1.6.1.tar.gz"
(cd opus-1.6.1 && CFLAGS="-O2 -fPIC" ./configure --prefix="$DEPS" --enable-static --disable-shared --disable-doc --disable-extra-programs >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

echo "== libvpx"
rm -rf libvpx-1.17.0 && tar xf "$HERE/dist/libvpx-1.17.0.tar.gz"
(cd libvpx-1.17.0 && ./configure --prefix="$DEPS" --enable-static --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-pic >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

echo "== nv-codec-headers $NVCODEC_TAG"
rm -rf nv-codec-headers && git clone -q --depth 1 --branch "$NVCODEC_TAG" https://github.com/FFmpeg/nv-codec-headers.git
make -C nv-codec-headers install PREFIX="$DEPS" >/dev/null
git -C nv-codec-headers rev-parse HEAD > "$WORK/nv-codec-headers.commit"

fetch() {  # name url sha256: download once into dist/ and refuse anything but the pinned archive
  local file="$HERE/dist/$1"
  [ -f "$file" ] || curl -sSfL -o "$file" "$2"
  echo "$3  $file" | sha256sum -c --quiet - || { echo "$1 is not the pinned archive"; exit 1; }
}

echo "== $LIBDRM (core only; the GPU-specific parts stay the system's)"
fetch "$LIBDRM.tar.xz" "https://dri.freedesktop.org/libdrm/$LIBDRM.tar.xz" "$LIBDRM_SHA256"
rm -rf "$LIBDRM" && tar xf "$HERE/dist/$LIBDRM.tar.xz"
(cd "$LIBDRM" && meson setup build --prefix="$DEPS" --libdir=lib -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled \
  -Dnouveau=disabled -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
  -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false >/dev/null && ninja -C build install >/dev/null)

echo "== $LIBVA (DRM only, searching the usual driver directories)"
fetch "$LIBVA.tar.bz2" "https://github.com/intel/libva/releases/download/${LIBVA#libva-}/$LIBVA.tar.bz2" "$LIBVA_SHA256"
rm -rf "$LIBVA" && tar xf "$HERE/dist/$LIBVA.tar.bz2"
(cd "$LIBVA" && PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" meson setup build --prefix="$DEPS" --libdir=lib -Dwith_x11=no -Dwith_glx=no \
  -Dwith_wayland=no -Denable_docs=false -Ddriverdir="$VA_DRIVERS" >/dev/null && ninja -C build install >/dev/null)

echo "== ffmpeg"
rm -rf ffmpeg-7.1.5 "$OUT" && tar xf "$HERE/dist/ffmpeg-7.1.5.tar.xz"
cd ffmpeg-7.1.5
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" ./configure \
  --prefix="$OUT" --enable-shared --disable-static --disable-gpl --disable-nonfree --disable-version3 \
  --enable-pic --disable-debug --disable-doc --disable-ffplay --disable-sdl2 --disable-xlib --disable-libxcb \
  --disable-libxcb-shm --disable-libxcb-xfixes --disable-libxcb-shape --disable-alsa --disable-sndio \
  --pkg-config-flags=--static --enable-libvpx --enable-libopus --enable-ffnvcodec --enable-nvenc --enable-vaapi \
  --extra-cflags="-I$DEPS/include" --extra-ldflags="-L$DEPS/lib" > "$WORK/configure.out"
grep -q "License: LGPL version 2.1 or later" "$WORK/configure.out" || { echo "configure did not report LGPL 2.1 or later"; exit 1; }
grep -qE "^#define CONFIG_(GPL|NONFREE) 1" config.h && { echo "config.h enables GPL or nonfree code"; exit 1; }
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "== the shipped layout: programs beside lib-$TRIPLE/, found through RUNPATH"
rm -rf "$STAGE" && mkdir -p "$STAGE/lib-$TRIPLE"
cp "$OUT/bin/ffmpeg" "$STAGE/ffmpeg-$TRIPLE" && cp "$OUT/bin/ffprobe" "$STAGE/ffprobe-$TRIPLE"
cp -P "$OUT"/lib/lib*.so* "$STAGE/lib-$TRIPLE/"
cp -P "$DEPS"/lib/libva.so* "$DEPS"/lib/libva-drm.so* "$DEPS"/lib/libdrm.so* "$STAGE/lib-$TRIPLE/"
for program in "$STAGE/ffmpeg-$TRIPLE" "$STAGE/ffprobe-$TRIPLE"; do patchelf --set-rpath "\$ORIGIN/lib-$TRIPLE" "$program"; done
for library in "$STAGE/lib-$TRIPLE"/*.so.*; do [ -L "$library" ] || patchelf --set-rpath '$ORIGIN' "$library"; done

echo "== checks"
"$STAGE/ffmpeg-$TRIPLE" -hide_banner -encoders | grep -qE " h264_nvenc " && echo "   h264_nvenc: built in" || { echo "   h264_nvenc: missing"; exit 1; }
"$STAGE/ffmpeg-$TRIPLE" -hide_banner -encoders | grep -qE " hevc_nvenc " && echo "   hevc_nvenc: built in" || { echo "   hevc_nvenc: missing"; exit 1; }
for encoder in h264_vaapi hevc_vaapi; do
  "$STAGE/ffmpeg-$TRIPLE" -hide_banner -encoders | grep -qE " $encoder " && echo "   $encoder: built in" || { echo "   $encoder: missing"; exit 1; }
done
if ldd "$STAGE/ffmpeg-$TRIPLE" | grep -E "lib(va|va-drm|drm)\.so" | grep -v "$STAGE" | grep -q .; then echo "libva or libdrm resolves outside the bundle"; exit 1; fi
echo "   libva, libva-drm and libdrm: loaded from the bundle"
highest=$(objdump -T "$STAGE/ffmpeg-$TRIPLE" "$STAGE/lib-$TRIPLE"/*.so.* 2>/dev/null | grep -oE "GLIBC_[0-9.]+" | sort -Vu | tail -1)
echo "   highest glibc symbol: $highest"
[ "$(printf '%s\n' "$highest" GLIBC_2.35 | sort -V | tail -1)" = GLIBC_2.35 ] || { echo "needs newer glibc than 2.35"; exit 1; }
echo "== done: $STAGE"
