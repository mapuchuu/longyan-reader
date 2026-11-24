#!/bin/bash
# Writes Resources/parts-of-speech.tsv: the Mac's part of speech for each definition where it
# differs from what the core reads without an English tagger. The Windows app has no tagger,
# so it reads this table and labels every meaning as the Mac does. Rerun after changing
# PartOfSpeech, Gloss or the dictionary.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product LongyanReader --product longyan-core-check >/dev/null
tmp=$(mktemp)
.build/release/LongyanReader --gloss-table Resources/cedict_ts.u8 > "$tmp"
.build/release/longyan-core-check --parts-of-speech "$tmp" > Resources/parts-of-speech.tsv
rm -f "$tmp"
echo "$(wc -l < Resources/parts-of-speech.tsv) definitions in Resources/parts-of-speech.tsv"
