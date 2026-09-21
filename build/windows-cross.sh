#!/usr/bin/env bash
# Cross-builds formcut's LGPL ffmpeg for x86_64 Windows with mingw-w64, from the
# pinned sources in dist/, and adds the encoders that give H.264 and HEVC with no
# GPL component:
#
#   Media Foundation  Windows' own H.264 and HEVC encoders, present on Windows 10
#                     and 11, hardware where a GPU offers it and Microsoft's
#                     software encoder otherwise. Headers ship with mingw-w64.
#   NVIDIA NVENC      header-only (nv-codec-headers, MIT); the driver is loaded
#                     at run time, so machines without it are unaffected.
#   AMD AMF           header-only (AMF SDK, MIT); likewise loaded at run time.
#
# formcut test-encodes every candidate before using it, so an encoder whose
# hardware or driver is missing is skipped rather than chosen.
#
# Needs mingw-w64, make, pkg-config, git, python3 and network access for the two
# header repositories. Run from anywhere: build/windows-cross.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${WORK:-/tmp/xbuild}
DEPS=$WORK/deps-win
OUT=$WORK/install-win
NVCODEC_TAG=n12.0.16.1   # oldest header set ffmpeg 7.1 accepts, for the widest range of drivers
JOBS=$(nproc)
mkdir -p "$WORK" "$DEPS"
cd "$WORK"

echo "== verifying the pinned sources against ffmpeg-licence.json"
python3 - "$HERE" <<'PY'
import hashlib, json, pathlib, sys, urllib.request
here = pathlib.Path(sys.argv[1])
record = json.loads((here / "ffmpeg-licence.json").read_text())["source"]
archives = {"ffmpeg": "ffmpeg-7.1.5.tar.xz", "libopus": "libopus-1.6.1.tar.gz", "libvpx": "libvpx-1.17.0.tar.gz"}
for name, file in archives.items():
    archive = here / "dist" / file
    if not archive.exists():
        # dist/ is not in git; CI fetches from the recorded upstream, then verifies as below.
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
(cd opus-1.6.1 && ./configure --host=x86_64-w64-mingw32 --prefix="$DEPS" --enable-static --disable-shared --disable-doc --disable-extra-programs >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

echo "== libvpx"
rm -rf libvpx-1.17.0 && tar xf "$HERE/dist/libvpx-1.17.0.tar.gz"
(cd libvpx-1.17.0 && CROSS=x86_64-w64-mingw32- ./configure --target=x86_64-win64-gcc --prefix="$DEPS" --enable-static --disable-shared --disable-examples --disable-tools --disable-docs --disable-unit-tests --enable-pic >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)

echo "== nv-codec-headers $NVCODEC_TAG"
rm -rf nv-codec-headers && git clone -q --depth 1 --branch "$NVCODEC_TAG" https://github.com/FFmpeg/nv-codec-headers.git
make -C nv-codec-headers install PREFIX="$DEPS" >/dev/null
git -C nv-codec-headers rev-parse HEAD > "$WORK/nv-codec-headers.commit"

echo "== AMF headers"
rm -rf AMF && git clone -q --depth 1 --filter=blob:none --sparse https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git
git -C AMF sparse-checkout set amf/public/include
mkdir -p "$DEPS/include/AMF" && cp -r AMF/amf/public/include/* "$DEPS/include/AMF/"
git -C AMF rev-parse HEAD > "$WORK/amf.commit"

# winpthreads statically: a directory holding only the static archive, searched
# before the toolchain's import library, so no DLL needs libwinpthread-1.dll.
mkdir -p "$WORK/static-pthread"
cp /usr/x86_64-w64-mingw32/lib/libwinpthread.a "$WORK/static-pthread/libwinpthread.a"
cp /usr/x86_64-w64-mingw32/lib/libwinpthread.a "$WORK/static-pthread/libpthread.a"

echo "== ffmpeg"
rm -rf ffmpeg-7.1.5 "$OUT" && tar xf "$HERE/dist/ffmpeg-7.1.5.tar.xz"
cd ffmpeg-7.1.5
PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" ./configure \
  --prefix="$OUT" --enable-shared --disable-static --disable-gpl --disable-nonfree --disable-version3 \
  --enable-pic --disable-debug --disable-doc --disable-ffplay --disable-sdl2 --disable-xlib --disable-libxcb \
  --disable-libxcb-shm --disable-libxcb-xfixes --disable-libxcb-shape --disable-alsa --disable-sndio \
  --pkg-config-flags=--static --enable-libvpx --enable-libopus \
  --enable-mediafoundation --enable-ffnvcodec --enable-nvenc --enable-amf \
  --arch=x86_64 --target-os=mingw32 --cross-prefix=x86_64-w64-mingw32- --enable-cross-compile --pkg-config=pkg-config \
  --extra-cflags="-I$DEPS/include" --extra-ldflags="-L$WORK/static-pthread -L$DEPS/lib" > "$WORK/configure.out"
grep -q "License: LGPL version 2.1 or later" "$WORK/configure.out" || { echo "configure did not report LGPL 2.1 or later"; exit 1; }
grep -qE "^#define CONFIG_(GPL|NONFREE) 1" config.h && { echo "config.h enables GPL or nonfree code"; exit 1; }
make -j"$JOBS" >/dev/null
make install >/dev/null

echo "== checks"
for dll in "$OUT"/bin/*.dll; do
  if x86_64-w64-mingw32-objdump -p "$dll" | grep -qi "libwinpthread"; then echo "$(basename "$dll") still needs libwinpthread-1.dll"; exit 1; fi
done
for encoder in h264_mf hevc_mf h264_nvenc hevc_nvenc h264_amf hevc_amf; do
  grep -qa "$encoder" "$OUT"/bin/avcodec-*.dll && echo "   $encoder: built in" || { echo "   $encoder: missing"; exit 1; }
done
echo "== done: $OUT"
