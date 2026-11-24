#!/bin/bash
# quality.sh NAME [ENV=VAL ...]: every pick eval on the Mac's GPU, outputs in runs/NAME/.
# Only summary lines are printed (real-eval output quotes a book: never print it).
set -uo pipefail
cd "$(dirname "$0")/../.."
S=build/faster-picks; mkdir -p $S
name=$1; shift
o=$S/runs/$name; mkdir -p $o
B=.build/release/LongyanReader
M="$HOME/Library/Application Support/LongyanReader/models/qwen3.5-4b-q4_k_m.gguf"
E=(env "$@")
"${E[@]}" $B --eval > $o/words.txt 2>&1
"${E[@]}" $B --eval-notes > $o/notes.txt 2>&1
"${E[@]}" LONGYAN_TIMING=1 LONGYAN_TIMING_ROWS=1 $B --eval-phrase notes/phrase-eval.tsv > $o/phrase.txt 2> $o/phrase-log.txt
"${E[@]}" $B --eval-single notes/note-pick-eval.tsv > $o/single.txt 2>&1
"${E[@]}" $B --eval-phrase notes/note-pick-eval.tsv > $o/phrase-notes.txt 2>&1
"${E[@]}" $B --eval-real notes/real-eval.tsv P > $o/real-P.txt 2>&1
"${E[@]}" $B --eval-real notes/real-eval.tsv S > $o/real-S.txt 2>&1
python3 scripts/eval-lookups.py notes/note-pick-eval.tsv notes/phrase-eval.tsv > $S/evals184.txt
"${E[@]}" .build/bridge-check/check .build/bridge-check/Resources scripts/bridge-check.txt "$M" 2>/dev/null | python3 scripts/bridge-normalize.py > $o/bridge.norm
"${E[@]}" .build/bridge-check/check .build/bridge-check/Resources $S/evals184.txt "$M" > $o/evals184.raw 2>/dev/null
python3 scripts/pick-parity.py picks $S/evals184.txt $o/evals184.raw > $o/picks184.txt
{
printf 'words\t%s\n' "$(grep -oE 'words [0-9]+/[0-9]+' $o/words.txt | head -1)"
printf 'senses\t%s\n' "$(grep -oE 'senses [0-9]+/[0-9]+' $o/words.txt | head -1)"
printf 'notes\t%s\n' "$(grep -oE 'right [0-9]+/[0-9]+' $o/notes.txt | head -1); wrong notes $(sed -nE 's/.*wrong notes shown ([0-9]+).*/\1/p' $o/notes.txt | tail -1)"
for f in phrase single phrase-notes; do printf '%s\t%s\n' $f "$(grep -oE 'right [0-9]+/[0-9]+' $o/$f.txt | tail -1)"; done
for k in P S; do printf 'real-%s\t%s\n' $k "$(grep -E "^$k: right" $o/real-$k.txt | tail -1 | grep -oE 'right [0-9]+/[0-9]+')"; done
printf 'bridge27\t%s lines\n' "$(wc -l < $o/bridge.norm)"
printf 'picks184\t%s lines\n' "$(wc -l < $o/picks184.txt)"
} | tee $o/summary.txt
