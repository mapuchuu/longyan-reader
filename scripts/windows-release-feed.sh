#!/bin/bash
# The release step that puts a Windows version in the update feed: windows-release.yml runs it
# on the live feed, and windows.yml's updates job on a local one, which the app then updates from.
#   scripts/windows-release-feed.sh FEED VERSION BUILD NOTES URL_PREFIX DIR
# DIR holds LongyanReader-Setup-VERSION-x64.exe and LongyanReader-Setup-VERSION-arm64.exe (one
# may be missing). BUILD is the build number the app was built with (the commit count). Each
# installer is signed with $WINDOWS_UPDATE_KEY and checked against the public key the app has
# ($UPDATE_PUBLIC_KEY, or windows/update-key.txt); without the key the item goes in unsigned,
# which the app refuses, and $REQUIRE_SIGNATURE=1 makes that an error. $INSTALLER_ARGS go on the
# command line WinSparkle runs the installer with.
set -euo pipefail
[ $# -eq 6 ] || { echo "usage: $0 FEED VERSION BUILD NOTES URL_PREFIX DIR" >&2; exit 1; }
feed=$1 version=$2 build=$3 notes=$4 prefix=$5 dir=$6
here=$(cd "$(dirname "$0")" && pwd)
py=${PYTHON:-python3}
pub=${UPDATE_PUBLIC_KEY:-$(cat "$here/../windows/update-key.txt" 2>/dev/null || true)}
[ -s "$notes" ] || { echo "no release notes in $notes: an update with no notes looks broken" >&2; exit 1; }
installers=()
for arch in x64 arm64; do
  f="$dir/LongyanReader-Setup-$version-$arch.exe"
  [ -f "$f" ] && installers+=(--installer "$arch=$f")
done
[ ${#installers[@]} -gt 0 ] || { echo "no LongyanReader-Setup-$version-x64.exe or -arm64.exe in $dir" >&2; exit 1; }
extra=()
[ -n "${INSTALLER_ARGS:-}" ] && extra+=(--installer-args "$INSTALLER_ARGS")
[ "${REQUIRE_SIGNATURE:-}" = 1 ] && extra+=(--require-signature)
"$py" "$here/windows-feed.py" add "$feed" --version "$version" --build "$build" --notes "$notes" \
  --url-prefix "$prefix" "${installers[@]}" "${extra[@]+"${extra[@]}"}"
if [ -n "${WINDOWS_UPDATE_KEY:-}" ]; then
  [ -n "$pub" ] || { echo "no public key to check the signatures with (windows/update-key.txt)" >&2; exit 1; }
  [ "$("$py" "$here/windows-feed.py" public-key)" = "$pub" ] \
    || { echo "WINDOWS_UPDATE_KEY isn't the key in windows/update-key.txt: installed copies would refuse the update" >&2; exit 1; }
  "$py" "$here/windows-feed.py" verify "$feed" "$pub" "$dir"
fi
