#!/bin/bash
# Builds "Longyan Reader.app" into build/. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Resources/cedict_ts.u8 ] || scripts/fetch-cedict.sh
# --dev adds the debug notification (probe, usage simulation; see App.swift), never in releases.
# --release makes the download: a plain ad-hoc signature and build/LongyanReader-<version>.zip.
mode="${1:-}"
flags=()
[ "$mode" = "--dev" ] && flags=(-Xswiftc -DDEV_TOOLS)
version=1.0
# The build number Sparkle compares to decide what's newer: the commit count, which only grows.
build=$(git rev-list --count HEAD)
# Updates: the feed is appcast.xml on the latest GitHub release (scripts/release.sh writes it),
# and each update must be signed with the private half of this key.
feed="https://github.com/mapuchuu/longyan-reader/releases/latest/download/appcast.xml"
update_key="PKOL1Dilin5y1JcMc78qN9FeLJboDyoMX44FSMKti50="
swift build -c release "${flags[@]+"${flags[@]}"}"
# Every note, example, cue and sense-order line must still match a dictionary sense.
.build/release/LongyanReader --check-data
app="build/Longyan Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
cp .build/release/LongyanReader "$app/Contents/MacOS/LongyanReader"
# llama.cpp (the local model runs in-process). ditto keeps the framework's symlinks and,
# with --arch, keeps only the slice the app is built for (the binary is this Mac's arch).
mkdir -p "$app/Contents/Frameworks"
ditto --arch "$(uname -m)" .build/release/llama.framework "$app/Contents/Frameworks/llama.framework"
codesign --force --sign - "$app/Contents/Frameworks/llama.framework"   # re-signed for releases
# Sparkle (updates) with its helpers: Autoupdate, Updater.app and the XPC services.
ditto .build/release/Sparkle.framework "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework"   # re-signed for releases
# The dictionary ships compiled (DictionaryFile.swift): opens in ~1 ms instead of ~1.4 s of
# parsing. Compiling checks every headword against the text.
.build/release/LongyanReader --compile-dict "$app/Contents/Resources/cedict.bin"
# CC BY-SA asks for the license notice with every copy: the text's header, which now names
# the compiled file as a modified copy (the README's Licences section has the details).
{ sed -n '/^#/p;/^[^#]/q' Resources/cedict_ts.u8
  echo "#"
  echo "# Longyan Reader ships this dictionary modified: compiled into cedict.bin, with the"
  echo "# additions in extra-words.u8. Source: https://github.com/mapuchuu/longyan-reader"
} > "$app/Contents/Resources/Licenses/CC-CEDICT.txt"
cp LICENSE "$app/Contents/Resources/Licenses/Longyan-Reader.txt"
cp Resources/licenses/llama.cpp-LICENSE.txt "$app/Contents/Resources/Licenses/llama.cpp.txt"
cp Resources/licenses/Sparkle-LICENSE.txt "$app/Contents/Resources/Licenses/Sparkle.txt"
cp Resources/AppIcon.icns Resources/longyan-mark.png Resources/notes.json Resources/examples.json Resources/note-cues.json Resources/sense-order.tsv "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.mapuchuu.longyanreader</string>
  <key>CFBundleName</key><string>Longyan Reader</string>
  <key>CFBundleExecutable</key><string>LongyanReader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>SUFeedURL</key><string>$feed</string>
  <key>SUPublicEDKey</key><string>$update_key</string>
  <key>NSHumanReadableCopyright</key><string>Free and open source (MIT)</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
if [ "$mode" = "--release" ]; then
  # Signed with the project's self-signed certificate (scripts/sign-release.sh): the app's
  # designated requirement names that certificate, so every release is the same app to
  # macOS and Accessibility stays granted across updates. Without the certificate (a fork,
  # another Mac) it falls back to plain ad-hoc, where each version needs the grant again.
  scripts/sign-release.sh "$app"
  zip="build/LongyanReader-$version.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app" "$zip"
  echo "built $app and $zip"
  shasum -a 256 "$zip"
else
  # Ad-hoc signatures are identified by a hash of the binary, so each rebuild would
  # lose the Accessibility and Screen Recording grants. An explicit requirement on the
  # bundle identifier lets the grants carry over between local builds.
  codesign --force --sign - -r='designated => identifier "com.mapuchuu.longyanreader"' "$app"
  echo "built $app"
fi
