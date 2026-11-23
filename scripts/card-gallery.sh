#!/bin/bash
# The card states in windows/gallery/cases.tsv, from this Mac with the reading model:
#   windows/gallery/mac/NAME[-dark].png   the Mac card, drawn by the app's --render commands
#   windows/gallery/NAME.json             the same card's contents from the bridge, which the
#                                         Windows app draws with --render (windows.yml)
# so the two cards can be compared side by side. Needs the model in Application Support.
set -euo pipefail
cd "$(dirname "$0")/.."
model="$HOME/Library/Application Support/LongyanReader/models/qwen3.5-4b-q4_k_m.gguf"
swift build -c release --product LongyanReader --product LongyanBridge >/dev/null
scripts/bridge-check.sh >/dev/null || true   # builds the check program and stages Resources
out=windows/gallery
mkdir -p "$out/mac"
lookups=$(mktemp)
python3 - "$out/cases.tsv" > "$lookups" <<'PY'
import sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("#") or not line.strip(): continue
    name, passage, sel, expand = (line.rstrip("\n").split("\t") + ["", ""])[:4]
    expand = "" if expand == "-" else expand
    i = passage.index(sel); a = len(passage[:i].encode("utf-16-le")) // 2; b = a + len(sel.encode("utf-16-le")) // 2
    print(f"{passage}\t{a}\t{b}\t{expand}")
PY
# Rows to open are named by word in cases.tsv; the check wants the row's token number, so a
# first pass finds them.
.build/bridge-check/check .build/bridge-check/Resources "$lookups" "$model" 2>/dev/null > "$lookups.cards"
python3 - "$lookups" "$lookups.cards" <<'PY'
import json, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
cards = open(sys.argv[2], encoding="utf-8").read().splitlines()
out = []
for line, card in zip(lines, cards):
    p = line.split("\t"); expand = p[3]
    token = -1
    if expand:
        c = json.loads(card).get("card", {})
        token = -2 if expand == "ALL" else next((r["token"] for r in c.get("rows", []) if r["text"] == expand), -1)
    out.append("\t".join(p[:3] + [str(token)]))
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
.build/bridge-check/check .build/bridge-check/Resources "$lookups" "$model" 2>/dev/null > "$lookups.cards"
# The cards as they open, before the model answers: the reading and translating states.
CHECK_FIRST=1 .build/bridge-check/check .build/bridge-check/Resources "$lookups" "$model" 2>/dev/null > "$lookups.first"
python3 - "$out/cases.tsv" "$lookups.cards" "$lookups.first" "$out" <<'PY'
import json, sys
cases = [(l.rstrip("\n").split("\t") + ["", "", ""])[:5] for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.startswith("#")]
settled = open(sys.argv[2], encoding="utf-8").read().splitlines()
first = open(sys.argv[3], encoding="utf-8").read().splitlines()
card = lambda line: json.loads(line).get("card", json.loads(line))
for (name, _, _, _, state), done, opening in zip(cases, settled, first):
    c = card(opening) if state in ("reading", "translating", "pending") else card(done)
    if state == "pending": c["translation"] = card(done).get("translation")
    json.dump(c, open(f"{sys.argv[4]}/{name}.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1, sort_keys=True)
PY
rm -f "$lookups" "$lookups.cards" "$lookups.first"
while IFS=$'\t' read -r name passage sel expand state; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    [ "$expand" = "-" ] && expand=""
    for mode in light dark; do
        suffix=$([ $mode = dark ] && echo "-dark" || true)
        if [ "$sel" = "$passage" ]; then
            LONGYAN_RENDER_STATE=$state LONGYAN_APPEARANCE=$mode .build/release/LongyanReader --render-phrase "$passage" "$out/mac/$name$suffix.png" ${expand:+"$expand"} >/dev/null
        else
            LONGYAN_RENDER_STATE=$state LONGYAN_APPEARANCE=$mode .build/release/LongyanReader --render "$passage" "$sel" "$out/mac/$name$suffix.png" >/dev/null
        fi
    done
    echo "$name"
done < "$out/cases.tsv"
