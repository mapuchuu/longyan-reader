#!/bin/bash
# Copies the data files the bridge reads (the Windows app's Resources folder) into DIR.
set -euo pipefail
cd "$(dirname "$0")/.."
dir=$1
mkdir -p "$dir"
for f in cedict_ts.u8 extra-words.u8 notes.json examples.json note-cues.json sense-order.tsv sense-everyday.tsv \
         output-tokens.txt parts-of-speech.tsv splitter.tsv; do
    cp "Resources/$f" "$dir/$f"
done
echo "$dir"
