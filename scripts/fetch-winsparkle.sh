#!/bin/bash
# WinSparkle (MIT), the Windows app's updater: the release's prebuilt WinSparkle.dll for x64 and
# ARM64, into Vendor/winsparkle/<arch>/. The csproj copies the one for the build's arch.
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.9.4
sha=6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976
out=Vendor/winsparkle
[ "$(cat "$out/version" 2>/dev/null)" = "$version" ] && exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/ws.zip" "https://github.com/vslavik/winsparkle/releases/download/v$version/WinSparkle-$version.zip"
echo "$sha  $tmp/ws.zip" | (command -v sha256sum >/dev/null && sha256sum -c - || shasum -a 256 -c -)
unzip -q "$tmp/ws.zip" -d "$tmp/x"
rm -rf "$out"
for arch in x64 ARM64; do
  mkdir -p "$out/$arch"
  cp "$tmp/x/WinSparkle-$version/$arch/Release/WinSparkle.dll" "$out/$arch/"
done
echo "$version" > "$out/version"
ls -l "$out"/*/WinSparkle.dll
