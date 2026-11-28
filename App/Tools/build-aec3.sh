#!/bin/bash
set -euo pipefail

# Usage: build-aec3.sh /path/to/webrtc-audio-processing-1.3.tar.gz [Meson packagecache]
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE_ARCHIVE="${1:?Pass the official webrtc-audio-processing-1.3 release archive}"
[[ $(shasum -a 256 "$SOURCE_ARCHIVE" | cut -d ' ' -f 1) == 95552fc17faa0202133707bbb3727e8c2cf64d4266fe31bfdb2298d769c1db75 ]]
mkdir -p "$ROOT/.build"
WORK=$(mktemp -d "$ROOT/.build/aec3.XXXXXXXX")
mkdir -p "$WORK/src" "$WORK/tmp"
export TMPDIR="$WORK/tmp" MACOSX_DEPLOYMENT_TARGET=14.2
# Meson verifies both Abseil downloads against the hashes in the pinned release's wrap.
tar -xf "$SOURCE_ARCHIVE" -C "$WORK/src" --strip-components 1
if [[ $# -ge 2 ]]; then
  mkdir -p "$WORK/src/subprojects/packagecache"
  cp "$2/abseil-cpp-20230125.1.tar.gz" "$2/abseil-cpp_20230125.1-4_patch.zip" "$WORK/src/subprojects/packagecache/"
fi
BRIDGE="$ROOT/App/Tools/aec3"
for arch in arm64 x86_64; do
  cpu="$arch"
  [[ "$arch" != arm64 ]] || cpu=aarch64
  cat >"$WORK/$arch.ini" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
[host_machine]
system = 'darwin'
cpu_family = '$cpu'
cpu = '$cpu'
endian = 'little'
EOF
  meson setup "$WORK/build-$arch" "$WORK/src" --cross-file "$WORK/$arch.ini" --buildtype=release --prefix="$WORK/install-$arch" -Ddefault_library=static --force-fallback-for=absl_base
  meson compile -C "$WORK/build-$arch" -j 2
  meson install -C "$WORK/build-$arch"
  xcrun clang++ -arch "$arch" -mmacosx-version-min=14.2 -std=c++17 -O3 -DNDEBUG -Wno-deprecated-builtins \
    -I"$ROOT/Sources/CMm2tAEC3/include" -I"$WORK/src/webrtc" -I"$WORK/src/subprojects/abseil-cpp-20230125.1" -c "$BRIDGE/mm2t_aec3.cc" -o "$WORK/bridge-$arch.o"
  xcrun libtool -static -o "$WORK/$arch.a" "$WORK/bridge-$arch.o" "$WORK/install-$arch/lib/libwebrtc-audio-processing-1.a"
done
xcrun lipo -create "$WORK/arm64.a" "$WORK/x86_64.a" -output "$WORK/libMM2TAEC3.a"
for arch in arm64 x86_64; do
  xcrun lipo -verify_arch "$arch" "$WORK/libMM2TAEC3.a"
done
# SwiftPM places static XCFramework headers in one shared include directory. The
# SwiftPM C target supplies its own module map, avoiding a collision with Bergamot.
xcodebuild -create-xcframework -library "$WORK/libMM2TAEC3.a" -output "$WORK/MM2TAEC3.xcframework"
ditto -c -k --keepParent "$WORK/MM2TAEC3.xcframework" "$WORK/MM2TAEC3.xcframework.zip"
mv "$WORK/MM2TAEC3.xcframework.zip" "$ROOT/Vendor/"
stat -f '%z %N' "$WORK/libMM2TAEC3.a" "$ROOT/Vendor/MM2TAEC3.xcframework.zip"
