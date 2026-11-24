#!/bin/bash
# cpu.sh NAME [ENV=VAL ...]: phrase picks on the Mac CPU only (no Metal device, 4 threads,
# the instructions' state kept as on Windows), with a line per row. Outputs in cpu/NAME/.
set -uo pipefail
cd "$(dirname "$0")/../.."
S=build/faster-picks; mkdir -p $S
name=$1; shift
o=$S/cpu/$name; mkdir -p $o
env GGML_METAL_DEVICES=0 LONGYAN_GPU_LAYERS=0 LONGYAN_THREADS=4 LONGYAN_PRIME=1 LONGYAN_TIMING=1 LONGYAN_TIMING_ROWS=1 "$@" \
  .build/release/LongyanReader --eval-phrase notes/phrase-eval.tsv > $o/phrase.txt 2> $o/log.txt
tail -1 $o/phrase.txt
python3 scripts/faster-picks/rows.py $o/log.txt
