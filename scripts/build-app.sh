#!/bin/bash
# Builds "Longyan Reader.app" into build/. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Resources/cedict_ts.u8 ] || scripts/fetch-cedict.sh
# --dev adds the debug notification (probe, usage simulation; see App.swift), never in releases.
flags=()
[ "${1:-}" = "--dev" ] && flags=(-Xswiftc -DDEV_TOOLS)
swift build -c release "${flags[@]+"${flags[@]}"}"
# Every note, example, cue and sense-order line must still match a dictionary sense.
.build/release/LongyanReader --check-data
app="build/Longyan Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/LongyanReader "$app/Contents/MacOS/LongyanReader"
cp Resources/cedict_ts.u8 Resources/longyan-mark.png Resources/notes.json Resources/examples.json Resources/note-cues.json Resources/sense-order.tsv Resources/extra-words.u8 "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.mapuchuu.longyanreader</string>
  <key>CFBundleName</key><string>Longyan Reader</string>
  <key>CFBundleExecutable</key><string>LongyanReader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Ad-hoc signatures are identified by a hash of the binary, so each rebuild would
# lose the Accessibility and Screen Recording grants. An explicit requirement on the
# bundle identifier lets the grants carry over between local builds.
codesign --force --sign - -r='designated => identifier "com.mapuchuu.longyanreader"' "$app"
echo "built $app"
