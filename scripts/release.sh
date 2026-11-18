#!/bin/bash
# Makes a release: the signed app and zip, and the appcast.xml that tells installed copies
# about it. Upload both to a GitHub release tagged v<version>; the app reads the feed from
# the latest release (SUFeedURL), so publishing the release is what ships the update.
#   scripts/release.sh [notes.md]    notes.md: what's new, shown in the update window
#
# Needs the signing folder ~/Library/Application Support/LongyanReader-signing/ (the code
# signing certificate, scripts/sign-release.sh) and the update key in the login keychain,
# created by Sparkle's generate_keys (backup: sparkle-private-key.txt in that folder).
set -euo pipefail
cd "$(dirname "$0")/.."
tools="$HOME/Library/Application Support/LongyanReader-signing/sparkle-2.10.1/bin"
[ -x "$tools/generate_appcast" ] || { echo "Sparkle's tools aren't in $tools" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit first: the build number is the commit count" >&2; exit 1; }

scripts/build-app.sh --release
# Every release must be signed with the project certificate: installed copies take any update
# whose EdDSA signature is good, and an ad-hoc one would cost them the Accessibility grant.
codesign -dr - "build/Longyan Reader.app" 2>&1 | grep -q 'certificate root = H"0c8ae0b42d467fa1412ed3e5b8f6cd5354b99c99"' \
  || { echo "the app isn't signed with the Longyan Reader certificate; not releasing" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/Longyan Reader.app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "build/Longyan Reader.app/Contents/Info.plist")
out="build/release-$version"
rm -rf "$out"; mkdir -p "$out"
cp "build/LongyanReader-$version.zip" "$out/"
# Release notes travel with the zip: generate_appcast embeds a .md of the same name.
[ -n "${1:-}" ] && cp "$1" "$out/LongyanReader-$version.md"
# The update key: the exported file if it's there (no keychain prompt), else the login keychain.
keyfile="$HOME/Library/Application Support/LongyanReader-signing/sparkle-private-key.txt"
key=(); [ -f "$keyfile" ] && key=(--ed-key-file "$keyfile")
"$tools/generate_appcast" "${key[@]+"${key[@]}"}" --embed-release-notes \
  --download-url-prefix "https://github.com/mapuchuu/longyan-reader/releases/download/v$version/" \
  "$out"
# The same zip under a fixed name, for the website's download link
# (releases/latest/download/LongyanReader.zip). Added after the appcast so it isn't listed there.
cp "$out/LongyanReader-$version.zip" "$out/LongyanReader.zip"
echo
echo "release $version (build $build) in $out:"
ls -1 "$out"
echo
echo "publish:  gh release create v$version $out/LongyanReader-$version.zip $out/LongyanReader.zip $out/appcast.xml --title \"Longyan Reader $version\" --notes-file <notes>"
