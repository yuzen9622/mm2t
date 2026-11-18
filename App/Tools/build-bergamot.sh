#!/bin/bash
# Builds Vendor/Bergamot.xcframework: Mozilla's Bergamot translation engine (bergamot-translator,
# Marian) as one static library per architecture, behind the C API in App/Tools/bergamot.
#
# Everything is pinned and everything happens under .build/bergamot:
#   - upstream source: browsermt/bergamot-translator at BERGAMOT_COMMIT, submodules as that commit pins them
#   - patches:         App/Tools/bergamot/patches/*.patch, applied with patch -p1 at the checkout root
#   - build tools:     cmake and ninja from PyPI at the versions below, in a private venv
# Only what translation needs is built: no Python bindings, no WASM, no tests, no CUDA, one thread,
# matrix products through Accelerate (sgemm) and ruy (arm64) or intgemm (x86_64) for int8.
#
# Usage: App/Tools/build-bergamot.sh [arm64] [x86_64]     (default: both)
set -euo pipefail

BERGAMOT_REPO=https://github.com/browsermt/bergamot-translator.git
BERGAMOT_COMMIT=9271618ebbdc5d21ac4dc4df9e72beb7ce644774   # main, "Update submodule", 2024-05-12 (v0.4.5)
CMAKE_VERSION=4.4.5
NINJA_VERSION=1.13.2
DEPLOYMENT_TARGET=14.2

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/App/Tools/bergamot"
WORK="$ROOT/.build/bergamot"
SRC="$WORK/src"
OUT="$ROOT/Vendor/Bergamot.xcframework"
ARCHS=("$@")
[ ${#ARCHS[@]} -eq 0 ] && ARCHS=(arm64 x86_64)

mkdir -p "$WORK"
# Also reaches nested CMake runs (ssplit's pcre2) that do not get the command-line cache.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# Build tools, kept off the system and out of the internal disk.
if [ ! -x "$WORK/tools/bin/cmake" ] || [ ! -x "$WORK/tools/bin/ninja" ]; then
  python3 -m venv "$WORK/tools"
  "$WORK/tools/bin/pip" install --quiet "cmake==$CMAKE_VERSION" "ninja==$NINJA_VERSION"
fi
CMAKE="$WORK/tools/bin/cmake"
NINJA="$WORK/tools/bin/ninja"

# Source at the pinned commit with its pinned submodules.
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet "$BERGAMOT_REPO" "$SRC"
fi
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$BERGAMOT_COMMIT" ]; then
  git -C "$SRC" fetch --quiet origin "$BERGAMOT_COMMIT"
  git -C "$SRC" checkout --quiet --detach "$BERGAMOT_COMMIT"
fi
git -C "$SRC" submodule update --init --recursive --quiet

for patch in "$HERE"/patches/*.patch; do
  if patch -p1 -d "$SRC" --dry-run --reverse --force --silent < "$patch" > /dev/null 2>&1; then
    echo "patch already applied: $(basename "$patch")"
  else
    patch -p1 -d "$SRC" --forward --silent < "$patch"
    echo "patch applied: $(basename "$patch")"
  fi
done

merged=()
for arch in "${ARCHS[@]}"; do
  case "$arch" in
    # Apple M1 is the oldest arm64 Mac; LLVM models it as Armv8.4-A. Never -march=native.
    arm64) build_arch=armv8.4-a ;;
    # Every Intel Mac that runs macOS 14 has SSE4.2.
    x86_64) build_arch=x86-64-v2 ;;
    *) echo "unknown architecture: $arch" >&2; exit 2 ;;
  esac
  build="$WORK/build-$arch"
  "$CMAKE" -S "$HERE" -B "$build" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DBERGAMOT_SOURCE_DIR="$SRC" \
    -DBUILD_ARCH="$build_arch" \
    -DGIT_SUBMODULE=OFF \
    -DUSE_WASM_COMPATIBLE_SOURCE=ON \
    -DUSE_ONNX_SGEMM=OFF \
    -DUSE_APPLE_ACCELERATE=ON \
    -DCOMPILE_WITHOUT_EXCEPTIONS=OFF \
    -DCOMPILE_PYTHON=OFF \
    -DCOMPILE_WASM=OFF \
    -DCOMPILE_TESTS=OFF \
    -DCOMPILE_UNIT_TESTS=OFF \
    -DCOMPILE_CUDA=OFF \
    -DUSE_DOXYGEN=OFF \
    -DUSE_NCCL=OFF \
    -DUSE_MKL=OFF \
    > "$build.configure.log"
  "$NINJA" -C "$build" mm2t-bergamot-cli

  # Merge every archive the CLI links into one, in link order.
  archives=()
  while IFS= read -r archive; do archives+=("$archive"); done < <(
    "$NINJA" -C "$build" -t commands mm2t-bergamot-cli | tail -1 | tr ' ' '\n' | grep '\.a$' |
      awk -v build="$build" '{ path = (substr($0, 1, 1) == "/") ? $0 : build "/" $0 } !seen[path]++ { print path }')
  mkdir -p "$WORK/lib/$arch"
  libtool -static -no_warning_for_no_symbols -o "$WORK/lib/$arch/libBergamot.a" "${archives[@]}" 2> "$build.libtool.log" || {
    cat "$build.libtool.log" >&2; exit 1; }
  merged+=("$WORK/lib/$arch/libBergamot.a")
done

# One fat archive, so the app's universal build finds both slices in one xcframework library.
mkdir -p "$WORK/lib/universal" "$WORK/headers"
lipo -create "${merged[@]}" -output "$WORK/lib/universal/libBergamot.a"
cp "$HERE/include/mm2t_bergamot.h" "$HERE/include/module.modulemap" "$WORK/headers/"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework -library "$WORK/lib/universal/libBergamot.a" -headers "$WORK/headers" -output "$OUT" > /dev/null

echo "built $OUT ($(lipo -archs "$WORK/lib/universal/libBergamot.a"))"
du -sh "$OUT"
# The archive SwiftPM would download once the binary is hosted, and its checksum for Package.swift.
rm -f "$WORK/Bergamot.xcframework.zip"
(cd "$(dirname "$OUT")" && ditto -c -k --sequesterRsrc --keepParent Bergamot.xcframework "$WORK/Bergamot.xcframework.zip")
echo "zip: $WORK/Bergamot.xcframework.zip"
shasum -a 256 "$WORK/Bergamot.xcframework.zip"
