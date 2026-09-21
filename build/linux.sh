#!/usr/bin/env bash
# Builds formcut's LGPL ffmpeg for x86_64 Linux from the pinned sources, as the
# shipped build was made, and adds NVIDIA NVENC for H.264 and HEVC: header-only
# (nv-codec-headers, MIT), with the driver loaded at run time, so machines
# without it are unaffected and formcut's test encode skips it there.
#
# VA-API, the Intel and AMD route on Linux, is not added yet: ffmpeg would then
# need libva at start-up, and on a machine without it ffmpeg would not run at
# all. It comes with libva bundled beside the other libraries, in its own step.
#
# Build on Ubuntu 22.04 or another glibc 2.35 system: the shipped build's floor.
# Needs gcc, make, nasm, pkg-config, patchelf, git and python3.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/lbuild}
DEPS=$WORK/deps-linux
OUT=$WORK/install-linux
STAGE=$WORK/stage
TRIPLE=x86_64-unknown-linux-gnu
NVCODEC_TAG=n12.0.16.1
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

echo "== ffmpeg"
rm -rf ffmpeg-7.1.5 "$OUT" && tar xf "$HERE/dist/ffmpeg-7.1.5.tar.xz"
cd ffmpeg-7.1.5
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" ./configure \
  --prefix="$OUT" --enable-shared --disable-static --disable-gpl --disable-nonfree --disable-version3 \
  --enable-pic --disable-debug --disable-doc --disable-ffplay --disable-sdl2 --disable-xlib --disable-libxcb \
  --disable-libxcb-shm --disable-libxcb-xfixes --disable-libxcb-shape --disable-alsa --disable-sndio \
  --pkg-config-flags=--static --enable-libvpx --enable-libopus --enable-ffnvcodec --enable-nvenc \
  --extra-cflags="-I$DEPS/include" --extra-ldflags="-L$DEPS/lib" > "$WORK/configure.out"
grep -q "License: LGPL version 2.1 or later" "$WORK/configure.out" || { echo "configure did not report LGPL 2.1 or later"; exit 1; }
grep -qE "^#define CONFIG_(GPL|NONFREE) 1" config.h && { echo "config.h enables GPL or nonfree code"; exit 1; }
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "== the shipped layout: programs beside lib-$TRIPLE/, found through RUNPATH"
rm -rf "$STAGE" && mkdir -p "$STAGE/lib-$TRIPLE"
cp "$OUT/bin/ffmpeg" "$STAGE/ffmpeg-$TRIPLE" && cp "$OUT/bin/ffprobe" "$STAGE/ffprobe-$TRIPLE"
cp -P "$OUT"/lib/lib*.so* "$STAGE/lib-$TRIPLE/"
for program in "$STAGE/ffmpeg-$TRIPLE" "$STAGE/ffprobe-$TRIPLE"; do patchelf --set-rpath "\$ORIGIN/lib-$TRIPLE" "$program"; done
for library in "$STAGE/lib-$TRIPLE"/*.so.*; do [ -L "$library" ] || patchelf --set-rpath '$ORIGIN' "$library"; done

echo "== checks"
"$STAGE/ffmpeg-$TRIPLE" -hide_banner -encoders | grep -qE " h264_nvenc " && echo "   h264_nvenc: built in" || { echo "   h264_nvenc: missing"; exit 1; }
"$STAGE/ffmpeg-$TRIPLE" -hide_banner -encoders | grep -qE " hevc_nvenc " && echo "   hevc_nvenc: built in" || { echo "   hevc_nvenc: missing"; exit 1; }
highest=$(objdump -T "$STAGE/ffmpeg-$TRIPLE" "$STAGE/lib-$TRIPLE"/*.so.* 2>/dev/null | grep -oE "GLIBC_[0-9.]+" | sort -Vu | tail -1)
echo "   highest glibc symbol: $highest"
[ "$(printf '%s\n' "$highest" GLIBC_2.35 | sort -V | tail -1)" = GLIBC_2.35 ] || { echo "needs newer glibc than 2.35"; exit 1; }
echo "== done: $STAGE"
