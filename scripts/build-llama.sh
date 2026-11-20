#!/bin/bash
# Builds llama.cpp b11588 with patches/llama.cpp-output-tokens.patch into Vendor/llama.xcframework
# (arm64 macOS, Metal), the framework Package.swift links. Built as the release's framework is, but
# without Xcode: cmake and ninja come from pip if they aren't installed. Headers, module map and
# Info.plist come from the release's framework.
#   LLAMA_SRC=dir  an unpatched b11588 source tree instead of downloading one
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=b11588
ZIP_SHA=4efb28d65a9e4bade3e1d0aeeaf6094206de85b7ad77da2cb585a938bfb1f052
W=.vendor-download; mkdir -p "$W"

if ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  [ -x "$W/tools/bin/cmake" ] || { python3 -m venv "$W/tools" && "$W/tools/bin/pip" -q install cmake ninja; }
  PATH=$PWD/$W/tools/bin:$PATH
fi

zip=$W/llama-$TAG-xcframework.zip
[ -f "$zip" ] || curl -fL -o "$zip" "https://github.com/ggml-org/llama.cpp/releases/download/$TAG/llama-$TAG-xcframework.zip"
echo "$ZIP_SHA  $zip" | shasum -a 256 -c --quiet
rm -rf "$W/release"; mkdir "$W/release"; unzip -q "$zip" -d "$W/release"
REL=$(find "$W/release" -maxdepth 4 -path "*macos-arm64*/llama.framework" | head -1)

src=$W/llama.cpp-$TAG
rm -rf "$src"
if [ -n "${LLAMA_SRC:-}" ]; then
  cp -R "$LLAMA_SRC" "$src"
else
  [ -f "$W/llama.cpp-$TAG.tar.gz" ] || curl -fL -o "$W/llama.cpp-$TAG.tar.gz" "https://github.com/ggml-org/llama.cpp/archive/refs/tags/$TAG.tar.gz"
  mkdir "$src"; tar -xzf "$W/llama.cpp-$TAG.tar.gz" -C "$src" --strip-components 1
fi
patch -d "$src" -p1 --quiet < patches/llama.cpp-output-tokens.patch

b=$W/llama-build
flags="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument"
cmake -S "$src" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_MTMD=OFF -DLLAMA_OPENSSL=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS_DEFAULT=ON -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
  -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" > "$W/llama-build.log"
cmake --build "$b" -j "$(sysctl -n hw.logicalcpu)" >> "$W/llama-build.log"
rm -f "$b/combined.a"
xcrun libtool -static -o "$b/combined.a" $(find "$b" -name "*.a" | grep -E "libllama|libggml|libvendor") 2>/dev/null

X=Vendor/llama.xcframework; F=$X/macos-arm64/llama.framework
rm -rf "$X"; mkdir -p "$X/macos-arm64"
ditto --arch arm64 "$REL" "$F"
xcrun clang++ -dynamiclib -arch arm64 -mmacosx-version-min=13.3 -Wl,-force_load,"$b/combined.a" \
  -framework Foundation -framework Metal -framework Accelerate \
  -install_name "@rpath/llama.framework/Versions/Current/llama" -o "$F/Versions/A/llama"
cp "$src/include/llama.h" "$F/Versions/A/Headers/llama.h"
cat > "$X/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>AvailableLibraries</key><array><dict>
<key>BinaryPath</key><string>llama.framework/Versions/A/llama</string>
<key>LibraryIdentifier</key><string>macos-arm64</string>
<key>LibraryPath</key><string>llama.framework</string>
<key>SupportedArchitectures</key><array><string>arm64</string></array>
<key>SupportedPlatform</key><string>macos</string>
</dict></array>
<key>CFBundlePackageType</key><string>XFWK</string>
<key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict></plist>
PL
shasum -a 256 patches/llama.cpp-output-tokens.patch scripts/build-llama.sh > Vendor/llama.stamp
echo "built $X"
