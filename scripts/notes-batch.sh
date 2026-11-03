#!/bin/bash
# Nuance notes in batches. See "New notes come in batches" in the README.
#   scripts/notes-batch.sh next [count]   start the next batch and print its words
#   scripts/notes-batch.sh finish NN      check a batch, merge it, run the tests
#   scripts/notes-batch.sh status         progress
set -euo pipefail
cd "$(dirname "$0")/.."
bin=.build/release/LongyanReader
swift build -c release 2>&1 | grep -E "error:" && exit 1

case "${1:-}" in
next)
    last=$(ls notes/batches 2>/dev/null | sort -n | tail -1)
    n=$(printf "%02d" $((10#${last:-0} + 1)))
    echo "batch $n"
    "$bin" --notes-next "notes/batches/$n" "${2:-60}"
    ;;
finish)
    dir="notes/batches/${2:?batch number}"
    review=$("$bin" --notes-review "$dir/selection.json" "$dir/annotations.tsv" "$dir/notes.json" "$dir/review.md" "$dir/note-covers.tsv")
    echo "$review"
    if echo "$review" | grep -qE "flagged [1-9]|unmatched [1-9]"; then echo "fix the notes above, then run this again"; exit 1; fi
    examples=$("$bin" --examples-build "$dir/selection.json" "$dir/examples.tsv" "$dir/examples.json")
    echo "$examples"
    if echo "$examples" | grep -qE "unmatched [1-9]"; then echo "fix the examples above, then run this again"; exit 1; fi
    "$bin" --notes-merge "$dir/notes.json" "$dir/examples.json"
    {
        "$bin" --eval-notes | tail -1
        "$bin" --eval | tail -1
        "$bin" --eval-phrase notes/phrase-eval.tsv | tail -1
        "$bin" --eval-phrase notes/note-pick-eval.tsv | tail -1
        "$bin" --eval-single notes/note-pick-eval.tsv | tail -1
    } | tee "$dir/scores.txt"
    "$bin" --notes-progress
    ;;
status)
    "$bin" --notes-progress
    ;;
*)
    sed -n 3,5p "$0"
    exit 1
    ;;
esac
