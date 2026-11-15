#!/bin/bash
# Runs every eval and compares the scores and timings with scripts/eval-baseline.tsv.
#
#   scripts/evals.sh              compare with the baseline; exits 1 on a regression
#   scripts/evals.sh --update     run, then save the results as the new baseline
#   scripts/evals.sh --binary B   use another build (default: the app in build/)
#
# A regression is fewer right answers, more wrong notes shown, or a timing more than
# 15% slower (timings are this Mac's; refresh the baseline after changing machine).
# Environment variables reach the app, so LONGYAN_GGUF=… or LONGYAN_BACKEND=ollama
# evaluates another model. notes/real-eval.tsv quotes a book and isn't in the repo;
# its evals are skipped when it's missing. Raw outputs go to build/evals/.
set -euo pipefail
cd "$(dirname "$0")/.."

binary="build/Longyan Reader.app/Contents/MacOS/LongyanReader"
update=0
while [ $# -gt 0 ]; do
  case "$1" in
    --update) update=1 ;;
    --binary) binary="$2"; shift ;;
    *) echo "usage: scripts/evals.sh [--update] [--binary PATH]" >&2; exit 2 ;;
  esac
  shift
done
[ -x "$binary" ] || { echo "no build at $binary (run scripts/build-app.sh)" >&2; exit 2; }

out=build/evals
mkdir -p "$out"
results="$out/results.tsv"
printf '# eval\tright\ttotal\tms\n' > "$results"

# run NAME ARGS…: the eval's full output goes to build/evals/NAME.txt
run() {
  local name="$1"; shift
  printf '%-16s' "$name" >&2
  local start=$(date +%s)
  "$binary" "$@" > "$out/$name.txt" 2>&1
  echo "$(( $(date +%s) - start )) s" >&2
}
# The summary lines each eval prints, turned into rows of results.tsv.
fraction() { grep -oE "$1 [0-9]+/[0-9]+" | head -1 | awk '{ split($2, a, "/"); printf "%s\t%s", a[1], a[2] }'; }

run words --eval
f=$(fraction words < "$out/words.txt"); ms=$(sed -nE 's/.*avg ([0-9]+) ms.*/\1/p' "$out/words.txt")
printf 'words\t%s\t%s\n' "$f" "$ms" >> "$results"
printf 'senses\t%s\t-\n' "$(fraction senses < "$out/words.txt")" >> "$results"

run notes --eval-notes
printf 'notes\t%s\t-\n' "$(fraction right < "$out/notes.txt")" >> "$results"
# Fewer is better: stored as right=0 out of the count, so the check is reversed below.
printf 'wrong-notes\t%s\t0\t-\n' "$(sed -nE 's/.*wrong notes shown ([0-9]+).*/\1/p' "$out/notes.txt" | tail -1)" >> "$results"

# Phrase evals print a total time in seconds; stored per item.
per_item() { # file total
  local s=$(sed -nE 's/.*, ([0-9]+) s$/\1/p' "$1" | tail -1)
  echo $(( s * 1000 / $2 ))
}
for spec in "phrase notes/phrase-eval.tsv --eval-phrase" \
            "single notes/note-pick-eval.tsv --eval-single" \
            "phrase-notes notes/note-pick-eval.tsv --eval-phrase"; do
  set -- $spec
  run "$1" "$3" "$2"
  f=$(fraction right < "$out/$1.txt")
  printf '%s\t%s\t%s\n' "$1" "$f" "$(per_item "$out/$1.txt" "$(echo "$f" | cut -f2)")" >> "$results"
done

if [ -f notes/real-eval.tsv ]; then
  run real --eval-real notes/real-eval.tsv
  for k in P S T; do
    line=$(grep -E "^$k: right" "$out/real.txt" | tail -1)
    printf 'real-%s\t%s\t%s\n' "$k" "$(echo "$line" | fraction right)" \
      "$(echo "$line" | sed -nE 's/.*, ([0-9]+) ms each.*/\1/p')" >> "$results"
  done
else
  echo "real            skipped (notes/real-eval.tsv not present)" >&2
fi

baseline=scripts/eval-baseline.tsv
if [ $update = 1 ]; then
  cp "$results" "$baseline"
  column -t -s $'\t' "$baseline"
  echo "saved as $baseline"
  exit 0
fi
[ -f "$baseline" ] || { column -t -s $'\t' "$results"; echo "no baseline yet: run with --update" >&2; exit 0; }

# Compare row by row; a row missing from either side is reported but not a failure.
awk -F'\t' '
  NR == FNR { if ($1 !~ /^#/) { br[$1] = $2; bt[$1] = $3; bm[$1] = $4 }; next }
  $1 ~ /^#/ { next }
  {
    seen[$1] = 1
    if (!($1 in br)) { printf "%-14s %s/%s  (new)\n", $1, $2, $3; next }
    note = ""
    if ($1 == "wrong-notes") { if ($2 > br[$1]) { note = "  WORSE (was " br[$1] ")"; bad = 1 } }
    else if ($2 < br[$1]) { note = "  WORSE (was " br[$1] "/" bt[$1] ")"; bad = 1 }
    else if ($2 > br[$1]) note = "  better (was " br[$1] "/" bt[$1] ")"
    time = ""
    if ($4 != "-" && bm[$1] != "-" && bm[$1] > 0) {
      time = sprintf("%5d ms (%+.0f%%)", $4, ($4 - bm[$1]) * 100 / bm[$1])
      if ($4 > bm[$1] * 1.15) { note = note "  SLOWER (was " bm[$1] " ms)"; bad = 1 }
    }
    printf "%-14s %4s/%-4s %s%s\n", $1, $2, ($1 == "wrong-notes" ? "-" : $3), time, note
  }
  END {
    for (k in br) if (!(k in seen)) printf "%-14s not run\n", k
    if (bad) { print "REGRESSION"; exit 1 }
    print "no regressions"
  }
' "$baseline" "$results"
