#!/bin/bash
# The card states in windows/gallery/cases.tsv, from this Mac with the reading model:
#   windows/gallery/mac/NAME[-dark].png   the Mac card, drawn by the app's --render commands
#   windows/gallery/NAME.json             the same card's contents from the bridge, which the
#                                         Windows app draws with --render (windows.yml)
# so the two cards can be compared side by side. Needs the model in Application Support.
# Each Mac drawing is given the bridge's wording (meaning, translation), which the model can
# word differently from one run to the next, so both drawings show the same text.
set -euo pipefail
cd "$(dirname "$0")/.."
model="$HOME/Library/Application Support/LongyanReader/models/qwen3.5-4b-q4_k_m.gguf"
swift build -c release --product LongyanReader >/dev/null
swift build -c release --product LongyanBridge >/dev/null   # one product per build: a second --product wins
scripts/bridge-check.sh >/dev/null || true   # builds the check program and stages Resources
out=windows/gallery
mkdir -p "$out/mac"
only=${1:-}   # a case name: just that one
lookups=$(mktemp)
python3 - "$out/cases.tsv" "$only" > "$lookups" <<'PY'
import sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("#") or not line.strip(): continue
    name, passage, sel, expand = (line.rstrip("\n").split("\t") + ["", ""])[:4]
    if sys.argv[2] and name != sys.argv[2]: continue
    expand = "" if expand == "-" else expand
    i = passage.index(sel); a = len(passage[:i].encode("utf-16-le")) // 2; b = a + len(sel.encode("utf-16-le")) // 2
    # A word card for a word of two or more characters is asked for as the Mac's --render
    # finds it: by pointing at its first character, which also gives the other words there.
    if sel != passage and len(sel) > 1: b = a
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
    if expand.startswith("PICK:"): token = -100 - int(expand[5:])
    elif expand:
        c = json.loads(card).get("card", {})
        token = -2 if expand == "ALL" else next((r["token"] for r in c.get("rows", []) if r["text"] == expand), -1)
    out.append("\t".join(p[:3] + [str(token)]))
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
.build/bridge-check/check .build/bridge-check/Resources "$lookups" "$model" 2>/dev/null > "$lookups.cards"
# The cards as they open, before the model answers: the reading and translating states.
CHECK_FIRST=1 .build/bridge-check/check .build/bridge-check/Resources "$lookups" "$model" 2>/dev/null > "$lookups.first"
python3 - "$out/cases.tsv" "$lookups.cards" "$lookups.first" "$out" "$only" <<'PY'
import json, sys
cases = [(l.rstrip("\n").split("\t") + ["", "", ""])[:5] for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.startswith("#")]
cases = [c for c in cases if not sys.argv[5] or c[0] == sys.argv[5]]
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
    [[ -n "$only" && "$name" != "$only" ]] && continue
    [ "$expand" = "-" ] && expand=""
    pick=""; [[ "$expand" == PICK:* ]] && { pick=${expand#PICK:}; expand=""; }
    # The bridge's wording and the phrase's text as the bridge trimmed it, for the Mac drawing.
    IFS=$'\x1f' read -r meaning translation text < <(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print("\x1f".join(c.get(k) or "" for k in ("back" if "back" in c else "meaning","translation","text")))' "$out/$name.json")
    extra=()
    [ -n "$meaning" ] && extra+=("LONGYAN_RENDER_MEANING=$meaning")   # with a pick, the model's (Back to)
    [ -n "$pick" ] && extra+=("LONGYAN_RENDER_PICK=$pick")
    [ -n "$translation" ] && extra+=("LONGYAN_RENDER_TRANSLATION=$translation")
    for mode in light dark; do
        suffix=$([ $mode = dark ] && echo "-dark" || true)
        if [ "$sel" = "$passage" ]; then
            env ${extra[@]+"${extra[@]}"} LONGYAN_RENDER_STATE=$state LONGYAN_APPEARANCE=$mode .build/release/LongyanReader --render-phrase "${text:-$passage}" "$out/mac/$name$suffix.png" ${expand:+"$expand"} >/dev/null
        else
            env ${extra[@]+"${extra[@]}"} LONGYAN_RENDER_STATE=$state LONGYAN_APPEARANCE=$mode .build/release/LongyanReader --render "$passage" "$sel" "$out/mac/$name$suffix.png" >/dev/null
        fi
    done
    echo "$name"
done < "$out/cases.tsv"
# The eye (selection button), drawn by --render-chip.
if [ -z "$only" ]; then
    for mode in light dark; do
        suffix=$([ $mode = dark ] && echo "-dark" || true)
        LONGYAN_APPEARANCE=$mode .build/release/LongyanReader --render-chip "$out/mac/eye$suffix.png" >/dev/null
    done
    echo "eye"
fi
