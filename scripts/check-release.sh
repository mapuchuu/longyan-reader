#!/bin/bash
# After publishing: checks that what users get is what release.sh built.
#   scripts/check-release.sh [version]    default: the version in scripts/build-app.sh
# It reads the live feed and downloads the site's zip (about 12 MB), then checks:
#   - the feed's newest item is this version and build
#   - the site's zip and the feed's zip are byte for byte the local build/release-<version> zip
#   - the feed's length and EdDSA signature match that zip
#   - the app inside is signed with the project's Developer ID, notarized, and says this version
# LONGYAN_RELEASE_BASE points it somewhere else (a file:// folder) for testing.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-$(sed -n 's/^version=//p' scripts/build-app.sh)}"
team_id=$(sed -n 's/^team_id=//p' scripts/build-app.sh)
[ -n "$team_id" ] || { echo "set team_id in scripts/build-app.sh (the Developer ID team)" >&2; exit 1; }
out="build/release-$version"
base="${LONGYAN_RELEASE_BASE:-https://github.com/mapuchuu/longyan-reader/releases/latest/download}"
[ -f "$out/LongyanReader.zip" ] || { echo "no $out: run scripts/release.sh first" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

curl -fsSL "$base/appcast.xml" -o "$tmp/appcast.xml" || { echo "couldn't fetch $base/appcast.xml" >&2; exit 1; }
# The newest item comes first (generate_appcast's order).
item=$(awk '/<item>/{n++} n==1' "$tmp/appcast.xml")
attr() { printf '%s\n' "$item" | grep -o "$1=\"[^\"]*\"" | head -1 | cut -d'"' -f2; }
tag() { printf '%s\n' "$item" | sed -n "s|.*<$1>\(.*\)</$1>.*|\1|p" | head -1; }
feed_version=$(tag sparkle:shortVersionString); feed_build=$(tag sparkle:version)
feed_url=$(attr url); feed_len=$(attr length); feed_sig=$(attr sparkle:edSignature)
local_build=$(awk '/<item>/{n++} n==1' "$out/appcast.xml" | sed -n 's|.*<sparkle:version>\(.*\)</sparkle:version>.*|\1|p' | head -1)

[ "$feed_version" = "$version" ] && ok "feed says $version" || bad "feed says '$feed_version', expected $version"
[ "$feed_build" = "$local_build" ] && ok "feed build $feed_build" || bad "feed build '$feed_build', local build $local_build"

want=$(shasum -a 256 "$out/LongyanReader-$version.zip" | cut -d' ' -f1)
curl -fsSL "$base/LongyanReader.zip" -o "$tmp/site.zip" || bad "couldn't download $base/LongyanReader.zip"
[ -f "$tmp/site.zip" ] && [ "$(shasum -a 256 "$tmp/site.zip" | cut -d' ' -f1)" = "$want" ] \
  && ok "site zip matches the local build" || bad "site zip differs from $out/LongyanReader-$version.zip"
if [ -n "$feed_url" ]; then
  # In testing the feed's URL points at GitHub; fetch the same file name from the base instead.
  [ -n "${LONGYAN_RELEASE_BASE:-}" ] && feed_url="$base/$(basename "$feed_url")"
  curl -fsSL "$feed_url" -o "$tmp/feed.zip" || bad "couldn't download $feed_url"
  [ -f "$tmp/feed.zip" ] && [ "$(shasum -a 256 "$tmp/feed.zip" | cut -d' ' -f1)" = "$want" ] \
    && ok "feed zip matches the local build" || bad "feed zip differs from the local build"
else
  bad "feed item has no download url"
fi
size=$(stat -f %z "$out/LongyanReader-$version.zip")
[ "$feed_len" = "$size" ] && ok "feed length $size" || bad "feed length '$feed_len', zip is $size bytes"

# The EdDSA check needs the private key file; without it, sign_update would ask the keychain.
tools="$HOME/Library/Application Support/LongyanReader-signing/sparkle-2.10.1/bin"
keyfile="$HOME/Library/Application Support/LongyanReader-signing/sparkle-private-key.txt"
if [ -x "$tools/sign_update" ] && [ -f "$keyfile" ] && [ -n "$feed_sig" ]; then
  "$tools/sign_update" --verify --ed-key-file "$keyfile" "$out/LongyanReader-$version.zip" "$feed_sig" >/dev/null 2>&1 \
    && ok "EdDSA signature verifies" || bad "EdDSA signature doesn't verify"
else
  echo "skip  EdDSA signature (no key file or no signature)"
fi

if [ -f "$tmp/site.zip" ]; then
  mkdir "$tmp/app"; ditto -x -k "$tmp/site.zip" "$tmp/app"
  app="$tmp/app/Longyan Reader.app"
  if [ -d "$app" ]; then
    codesign --verify --deep --strict "$app" 2>/dev/null && ok "code signature valid" || bad "code signature invalid"
    codesign -dr - "$app" 2>&1 | grep -Eq "anchor apple generic.*certificate leaf\[subject\.OU\] = \"?$team_id\"?([ )]|$)" \
      && ok "signed with the project's Developer ID ($team_id)" || bad "not signed with the project's Developer ID ($team_id)"
    xcrun stapler validate -q "$app" 2>/dev/null && ok "notarization ticket stapled" || bad "no notarization ticket stapled"
    spctl --assess --type execute -vv "$app" 2>&1 | grep -q "source=Notarized Developer ID" \
      && ok "Gatekeeper accepts it as notarized" || bad "Gatekeeper doesn't accept it as notarized"
    v=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
    [ "$v" = "$version" ] && ok "app says $v" || bad "app says '$v', expected $version"
  else
    bad "the site zip doesn't hold 'Longyan Reader.app'"
  fi
fi
[ $fail = 0 ] && echo "release $version checks out" || { echo "release $version has problems" >&2; exit 1; }
