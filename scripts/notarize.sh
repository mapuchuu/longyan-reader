#!/bin/bash
# Sends a signed release build to Apple's notary service, then staples the ticket to it, so
# Gatekeeper opens it without asking to go online and without the Open Anyway step.
#   scripts/notarize.sh "build/Longyan Reader.app"
#
# Needs the notary login in the login keychain, saved once with (it asks for an
# app-specific password from account.apple.com, which never goes in a file):
#   xcrun notarytool store-credentials longyan-notary --apple-id <Apple ID> --team-id <team>
set -euo pipefail
app="${1:?app path}"
profile=longyan-notary
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# The service takes a zip of the app; the ticket is then stapled to the app itself.
ditto -c -k --norsrc --noextattr --keepParent "$app" "$tmp/notarize.zip"
echo "notarizing (usually a few minutes)…"
xcrun notarytool submit "$tmp/notarize.zip" --keychain-profile "$profile" --wait \
  --output-format plist > "$tmp/result.plist" || true
status=$(/usr/libexec/PlistBuddy -c "Print status" "$tmp/result.plist" 2>/dev/null || echo "no answer")
id=$(/usr/libexec/PlistBuddy -c "Print id" "$tmp/result.plist" 2>/dev/null || true)
if [ "$status" != Accepted ]; then
  echo "notarization: $status" >&2
  # The log says which file failed and why (an unsigned binary, no timestamp, no hardened runtime).
  [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$profile" >&2
  exit 1
fi
echo "notarization: Accepted ($id)"
xcrun stapler staple -q "$app"
xcrun stapler validate -q "$app"
spctl --assess --type execute -vv "$app" 2>&1 | grep -q "source=Notarized Developer ID" \
  || { echo "Gatekeeper doesn't see it as notarized" >&2; spctl --assess --type execute -vv "$app" >&2; exit 1; }
echo "stapled; Gatekeeper accepts it as Notarized Developer ID"
