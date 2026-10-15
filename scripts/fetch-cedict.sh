#!/bin/bash
# Downloads CC-CEDICT (CC BY-SA 4.0, published by MDBG) into Resources/.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
curl -sSL -o "$tmp/cedict.zip" https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.zip
unzip -o -q "$tmp/cedict.zip" -d "$tmp"
mkdir -p Resources
mv "$tmp/cedict_ts.u8" Resources/cedict_ts.u8
rm -rf "$tmp"
echo "Resources/cedict_ts.u8: $(grep -vc '^#' Resources/cedict_ts.u8) entries"
