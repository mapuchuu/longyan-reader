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
version=0.1
swift build -c release "${flags[@]+"${flags[@]}"}"
# Every note, example, cue and sense-order line must still match a dictionary sense.
.build/release/LongyanReader --check-data
app="build/Longyan Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/LongyanReader "$app/Contents/MacOS/LongyanReader"
# llama.cpp (the local model runs in-process). ditto keeps the framework's symlinks and,
# with --arch, keeps only the slice the app is built for (the binary is this Mac's arch).
mkdir -p "$app/Contents/Frameworks"
ditto --arch "$(uname -m)" .build/release/llama.framework "$app/Contents/Frameworks/llama.framework"
codesign --force --sign - "$app/Contents/Frameworks/llama.framework"
cp Resources/cedict_ts.u8 Resources/longyan-mark.png Resources/notes.json Resources/examples.json Resources/note-cues.json Resources/sense-order.tsv Resources/extra-words.u8 "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.mapuchuu.longyanreader</string>
  <key>CFBundleName</key><string>Longyan Reader</string>
  <key>CFBundleExecutable</key><string>LongyanReader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
if [ "$mode" = "--release" ]; then
  # Plain ad-hoc: the grant is tied to this exact binary. (The identifier-only requirement
  # below would let any app calling itself com.mapuchuu.longyanreader inherit the
  # Accessibility grant, which is fine on the developer's own Mac only.) Updating means
  # granting Accessibility again.
  codesign --force --sign - "$app"
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
