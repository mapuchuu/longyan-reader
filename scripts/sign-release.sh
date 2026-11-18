#!/bin/bash
# Signs a release build with the Longyan Reader self-signed certificate.
#   scripts/sign-release.sh "build/Longyan Reader.app"
#
# The certificate lives in its own keychain, ~/Library/Application Support/LongyanReader-signing/
# longyan-signing.keychain-db, whose password is in the login keychain (service
# "longyan-signing"). Back up longyan-codesign.p12 from that folder, with that password: a
# release signed with any other certificate is a different app to macOS, and users would
# have to grant Accessibility again. codesign only finds identities in the search list, so
# the keychain is added for the signing and the list put back afterwards.
set -euo pipefail
app="${1:?app path}"
dir="$HOME/Library/Application Support/LongyanReader-signing"
kc="$dir/longyan-signing.keychain-db"
identity="Longyan Reader (self-signed)"

if [ ! -f "$kc" ]; then
  # Sparkle installs any update whose EdDSA signature is good, whatever its code signature,
  # so an ad-hoc release would reach every user and cost them the Accessibility grant.
  # Only a fork or a test build, which can't ship to our users, may go ahead.
  if [ "${LONGYAN_ALLOW_ADHOC:-}" != 1 ]; then
    echo "no signing keychain at $kc: restore it from the backup (DEVELOPMENT.md, Releases)" >&2
    echo "LONGYAN_ALLOW_ADHOC=1 signs ad-hoc instead, for a fork or a test build only" >&2
    exit 1
  fi
  echo "warning: no signing keychain at $kc; signing ad-hoc" >&2
  codesign --force --deep --sign - "$app/Contents/Frameworks/"*.framework
  codesign --force --sign - "$app"
  exit 0
fi

password=$(security find-generic-password -a signing -s longyan-signing -w)
security unlock-keychain -p "$password" "$kc"
saved=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && saved+=("$line")
done < <(security list-keychains -d user)
restore() { security list-keychains -d user -s "${saved[@]}"; }
trap restore EXIT
security list-keychains -d user -s "${saved[@]}" "$kc"

# Inside out: Sparkle's helpers (as its documentation lists them), the frameworks, then the app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [ -d "$sparkle" ]; then
  codesign --force --sign "$identity" -o runtime "$sparkle/Versions/B/XPCServices/Installer.xpc"
  codesign --force --sign "$identity" -o runtime --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
  codesign --force --sign "$identity" -o runtime "$sparkle/Versions/B/Autoupdate"
  codesign --force --sign "$identity" -o runtime "$sparkle/Versions/B/Updater.app"
  codesign --force --sign "$identity" -o runtime "$sparkle"
fi
codesign --force --sign "$identity" "$app/Contents/Frameworks/llama.framework"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
codesign -dr - "$app" 2>&1 | grep designated
