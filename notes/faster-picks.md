# Faster picks on a CPU (experiment, 2026-11-24)

The question: can a phrase card's rows come in sooner on a PC, and its pick prompts be
shorter, without worse picks? Branch `exp/faster-picks`, off `shared-core`. Nothing here is
on by default: every variant is an environment variable, so the app behaves as before.

## How it was measured

- Timing: the Mac's CPU with no Metal device (`GGML_METAL_DEVICES=0`, `LONGYAN_GPU_LAYERS=0`),
  4 threads, the instructions' state kept as on Windows (`LONGYAN_PRIME=1`). That reads
  prompts at about 45 tokens a second, like a PC. The set is `--eval-phrase
  notes/phrase-eval.tsv`; the numbers are the 87 pick requests with 2 or more words (3.8 on
  average). `LONGYAN_TIMING_ROWS=1` prints a line per row: tokens read and ms since the
  request started.
- Tokens are prompt tokens read for that request, without the 45 instruction tokens that
  are already kept.
- Quality: every pick eval on the Mac's GPU (`scripts/faster-picks/quality.sh`): `--eval`,
  `--eval-notes`, `--eval-phrase` on both files, `--eval-single`, real reading P and S, the
  27 bridge-check cards and the 184 eval picks (`eval-lookups.py`) through the bridge with the
  model. Bridge and pick columns count cards or picks that differ from the baseline.

## Noise

- On the GPU the picks are fixed: two baseline runs, and runs with priming on, flash
  attention off, and ubatch 128 and 64, all gave the same scores and the same 27 cards and
  184 picks.
- The CPU against the GPU (same prompts, different arithmetic): 2 of 27 cards and 3 of 184
  picks differ, phrase 83/95 on both, real P 132/136 on both (1 pick went wrong and 1 right).
- So a change of 1 or 2 on a set, or 2 to 3 changed cards or picks, is noise. Any change to
  the prompt's wording moves near ties both ways (b1 below: 3 real P picks went wrong and 3
  went right), so a set score matters more than how many picks changed.
- Timing: a second baseline run on the CPU was 4% faster than the first (9.5 s against 9.9 s
  to the first row). Differences under about 5% are noise.

## The variants

A. Rows one at a time:
- `prog` (`LONGYAN_PICK_PROGRESSIVE=1`): the instructions and passage are read once and
  their state kept (`EmbeddedModel.pickEach`). Each word is then asked as a one-word pick
  with its own short ending, from that state.
- `progl`: the same, with the start also naming every word on the card
  (`LONGYAN_PICK_WORDLIST=1`).
- `chain` (`LONGYAN_PICK_PROGRESSIVE=chain`): one request, a chat turn per word, so each word
  is read after the one before it is picked, and still sees the earlier words and answers.

B. Shorter prompts:
- `capN` (`LONGYAN_PICK_SENSES=N`): only the first N senses.
- `noex`: no example sentences. `nonote`: no note hints.
- `gloss2`, `gloss1` (`LONGYAN_PICK_GLOSS=N`): each gloss cut to its first N parts.
- `clean` (`LONGYAN_PICK_CLEAN=1`): no "(bound form)", "(Tw)" or pinyin cross-references.
- `pinyin` (`LONGYAN_PICK_PINYIN=auto`): no pinyin on words with one reading.
  `pinch` (`=change`): pinyin only where the reading changes from the sense before.
- `terse` (`LONGYAN_PICK_TERSE=1`): shorter instructions and lead-in.
- `b1`: clean, gloss2 and pinch. `b2`: b1 and cap8.

C. `c1`: progl and b1. `c2`: chain and b1.

## Results

Timing on the CPU (requests with 2 or more words; first and last row, mean):

| Variant | First row | Last row |
|---|---|---|
| baseline | 447 tok, 9.9 s | 458 tok, 10.2 s |
| prog (A) | 157 tok, 3.4 s | 542 tok, 11.8 s |
| progl (A) | 168 tok, 3.5 s | 553 tok, 11.4 s |
| chain (A) | 156 tok, 3.4 s | 558 tok, 12.2 s |
| b1 (B) | 348 tok, 7.3 s | 360 tok, 7.6 s |
| c1 (A+B) | 142 tok, 2.9 s | 452 tok, 9.3 s |

With 4 or more words (48 requests) the baseline's first row is 11.3 s; c1's is 2.9 s and
its last 11.1 s.

Quality on the GPU, with prompt tokens per request (with the 45 instruction tokens):

| Variant | Tokens | Words | Notes (wrong) | Phrase /95 | Single /90 | Phrase notes /90 | Real P /136 | Real S /39 | Cards changed /27 | Picks changed /184 |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 501 | 27 | 51 (1) | 83 | 85 | 82 | 132 | 36 | 0 | 0 |
| prog | 210 first | 27 | 51 (1) | 83 | 85 | 81 | 125 | 36 | 5 | 0 |
| progl | 221 first | 27 | 51 (1) | 83 | 85 | 82 | 129 | 36 | 6 | 0 |
| chain | 210 first | 27 | 51 (1) | 81 | 85 | 82 | 131 | 36 | 4 | 0 |
| cap8 | 457 | 27 | 50 (2) | 82 | 84 | 81 | 132 | 36 | 2 | 3 |
| cap6 | 424 | 27 | 48 (1) | 79 | 82 | 79 | 130 | 36 | 3 | 10 |
| cap4 | 372 | 27 | 46 (1) | 71 | 73 | 71 | 129 | 34 | 5 | 28 |
| noex | 492 | 27 | 50 (1) | 84 | 84 | 78 | 131 | 36 | 0 | 7 |
| nonote | 493 | 27 | 50 (1) | 82 | 83 | 80 | 133 | 36 | 1 | 5 |
| gloss2 | 486 | 27 | 52 (0) | 81 | 85 | 82 | 133 | 36 | 2 | 2 |
| gloss1 | 462 | 27 | 52 (0) | 82 | 86 | 82 | 131 | 36 | 5 | 5 |
| clean | 482 | 27 | 51 (1) | 81 | 85 | 82 | 133 | 36 | 2 | 0 |
| pinyin | 432 | 27 | 50 (1) | 81 | 86 | 84 | 130 | 36 | 7 | 6 |
| pinch | 431 | 27 | 51 (1) | 82 | 86 | 83 | 131 | 35 | 4 | 9 |
| terse | 447 | 27 | 50 (2) | 83 | 86 | 80 | 131 | 36 | 6 | 11 |
| b1 | 402 | 27 | 52 (0) | 82 | 86 | 84 | 132 | 35 | 4 | 9 |
| b2 | 371 | 27 | 52 (0) | 81 | 85 | 83 | 131 | 35 | 5 | 12 |
| c1 | 195 first | 27 | 52 (0) | 85 | 86 | 81 | 128 | 35 | 7 | 9 |
| c2 | 184 first | 27 | 52 (0) | 83 | 86 | 82 | 130 | 35 | 7 | 9 |

Words is out of 29 (senses 24/29 everywhere but cap6, 23). The 184 eval picks are word cards,
which never use A, so A changes none of them.

## What it shows

- A works for speed: row 1 comes about 3 times sooner (9.9 s to 3.4 s), but the last row comes
  later (10.2 s to 11.4 to 12.2 s), since each word repeats the reply line and the chat
  markers. Every form of A loses on real reading P, beyond noise: 7 for prog, 3 with the word
  list, 4 for c1. Asked one word at a time, the model loses what the other words' senses tell
  it. chain keeps them but lost 2 on phrase on the GPU and 4 on the CPU (79/95).
- Fewer senses costs right away: cap8 loses 1 on most sets for 9% fewer tokens; cap6 and cap4
  are clearly worse. Examples and note hints earn their tokens (noex loses 4 on phrase notes).
- Pinyin is the biggest cheap cut. Tone-marked pinyin takes several tokens a line, and most
  senses repeat the one before. Shown only where it changes, it saves 14%.
- b1 saves 20% of the prompt (447 to 348 tokens read on the CPU) and every row comes 26%
  sooner (9.9 s to 7.3 s). Its scores are within noise of the baseline on every set, a net +2
  over all of them, and it shows no wrong note where the baseline shows one.

## Recommendation

b1: `LONGYAN_PICK_CLEAN=1 LONGYAN_PICK_GLOSS=2 LONGYAN_PICK_PINYIN=change`. It's the only
variant that is faster on every row with quality within noise. The 4 changed bridge cards
would need `scripts/bridge-check.sh --update` if it ships.

A is not worth it as is: rows start sooner but finish later, and real reading picks get worse.
c1 is the one to try if a first row at 3 s matters more than 4 of 136 real reading picks; its
last row still comes sooner than today's (9.3 s against 9.9 s).
