#!/bin/bash
# Makes the Windows app's update key, once. Run it on the Mac that holds the signing folder:
#   scripts/windows-update-key.sh
# The private half goes in ~/Library/Application Support/LongyanReader-signing/windows-update-key.txt
# and in the repo's WINDOWS_UPDATE_KEY secret (windows-release.yml signs with it); the public half
# goes in windows/update-key.txt, which the app is built with. Commit that file. Back up the
# private file with the others: without it, installed copies can never be updated.
set -euo pipefail
cd "$(dirname "$0")/.."
dir="$HOME/Library/Application Support/LongyanReader-signing"
private="$dir/windows-update-key.txt"
[ ! -e "$private" ] || { echo "$private already exists; a new key would stop installed copies from updating" >&2; exit 1; }
[ ! -s windows/update-key.txt ] || { echo "windows/update-key.txt already has a key" >&2; exit 1; }
mkdir -p "$dir"
python3 scripts/windows-feed.py new-key "$private" > windows/update-key.txt
gh secret set WINDOWS_UPDATE_KEY --repo mapuchuu/longyan-reader < "$private"
echo "public key: $(cat windows/update-key.txt) (in windows/update-key.txt: commit it)"
echo "private key: $private, and the WINDOWS_UPDATE_KEY secret. Back it up."
