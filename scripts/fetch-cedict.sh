#!/bin/bash
# Updates Resources/cedict_ts.u8 to the latest CC-CEDICT (CC BY-SA 4.0, published by MDBG).
# The file is committed, so builds don't depend on whatever MDBG serves that day; run this to
# move to a newer release on purpose. It keeps the update only if every note, example, cue and
# sense-order line still matches a sense (--check-data); otherwise it puts the old file back.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -sSL -o "$tmp/cedict.zip" https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.zip
unzip -o -q "$tmp/cedict.zip" -d "$tmp"
mkdir -p Resources
[ -f Resources/cedict_ts.u8 ] && cp Resources/cedict_ts.u8 "$tmp/previous.u8"
mv "$tmp/cedict_ts.u8" Resources/cedict_ts.u8
echo "Resources/cedict_ts.u8: $(grep -vc '^#' Resources/cedict_ts.u8) entries, $(grep -m1 '^#! date=' Resources/cedict_ts.u8 | cut -d= -f2)"
if [ -x .build/release/LongyanReader ] && ! .build/release/LongyanReader --check-data; then
    if [ -f "$tmp/previous.u8" ]; then
        mv "$tmp/previous.u8" Resources/cedict_ts.u8
        echo "Kept the previous dictionary: update the lines above (or the dictionary) first." >&2
    fi
    exit 1
fi
