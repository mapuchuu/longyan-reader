# Mac regression check: shared-core against main

2026-11-24. main at bbfd314, shared-core at 8984051 (origin). Both built in Release with `scripts/build-app.sh` in their own worktrees and run from their build folders. Real model (Qwen 3.5 4B Q4_K_M) on the Mac's GPU.

Result: the Mac app on shared-core behaves the same as on main. Nothing found that should stop the merge for the Mac.

## Results

| Check | Result | Numbers |
|---|---|---|
| parity.py (segment, clicks, selections, senses, check-data) | same | 69,695 lines in 7 sections, all identical (217,276 with the gloss table) |
| parity.py gloss-table (wording and part of speech of every definition) | same | 147,581 lines identical. main has no `--gloss-table`, so it was added to a scratch build of main for this |
| Card gallery, light and dark, 20 cases plus the eye | same | 40 of 40 PNGs pixel identical once both draw in sRGB (see below) |
| Gallery states only shared-core can draw (reading, all, pinned, translating, picked) | n/a on main | all 10 render |
| Eye render (`--render-chip`) | same | 108x108, identical light and dark |
| bridge-check.sh | matches expected | 27 of 27 |
| longyan-core-check against core-check-expected.txt | matches | 146 of 146 lines |
| evals.sh (words, senses, notes, wrong notes, phrase, single, phrase-notes, real P/S/T) | same | every output identical apart from timing figures, in two rounds each. Scores: 27/29, 24/29, 51/52, 1, 83/95, 85/90, 82/90, 132/136, 36/39, 49/52 on both |
| Eval lookups (eval-lookups.py, 184 lookups, `--lookup`) | same | word, pick and meaning identical on all 184 |
| Same lookups through the bridge with the model | 181 of 184 | the 3 others are a different word, not a different pick: the bridge points at a character (start = end), `--lookup` takes a character index (老实/老实说, 爱面子/面子, 一对/对) |
| `--show` traces, word (word-mianzi) and phrase (phrase-ming) | n/a on main | two runs agree within a frame or two. Motion constants in the source are the same on both branches |
| Word card timing (地道, pick) | same | median 218 ms main, 216 ms shared-core, 5 runs each |
| Phrase card timing (快递员…) | same | translation prompt 139 / 148 ms, answer 430 / 417 ms, picks 665 / 642 ms. Same translation and picks every run |
| History export (`--history-export`, temp profile) | same | csv and anki exports byte identical |
| Add to Anki (bridge against fake-ankiconnect.py) | same as the Mac reference | addNote fields match windows/UiCheck/anki-mac.json |
| `--status` | same | |
| Info.plist, feed, signing | same | SUFeedURL is appcast.xml on releases/latest, same EdDSA key, same designated requirement, same bundled resources |
| Live feed | Mac only | one item, 1.1 (build 193), no `sparkle:os` items |

Another agent ran Mac evals on exp/faster-picks at the same time, so every timing was 20 to 100% over scripts/eval-baseline.tsv on both branches, and evals.sh reported SLOWER on both. Runs alternated between the branches, and the medians are within noise of each other.

## Differences found

- Gallery PNGs differ on every pixel in the raw comparison (max channel difference 27). Cause: 62ef779 ("Mac gallery drawn in sRGB") changed `--render` to write an sRGB bitmap instead of Generic RGB. That only changes the PNG writer in CLI.swift, not the card on screen. With that one hunk applied to main, all 40 images are identical.
- Build number: main builds as 199, shared-core as 418 (the commit count). It goes up, so Sparkle is fine after the merge.

## Mac-only parts

Read from `git diff main...shared-core -- Sources`:

- Unchanged files: HotKey.swift (the shortcut), LoginItem.swift, Updates.swift (Sparkle), AppMover.swift. Chip.swift (the eye), HistoryWindow.swift, TextCapture.swift, Onboarding.swift and ModelDownloader.swift only gain `import LongyanCore`. "Report a Problem" in App.swift is untouched.
- Selection reading: `Selection` moved to the core unchanged. `isSingleWord` and the `alone` check became `isOneWord` and `isAlone` with the same code.
- Word card opening (`LookupState.opening`), `pickFailed` and `receivePartOf` are the old App.swift code moved over.
- NLTokenizer, NLTagger, Apple's model and Translation now come through `AppleServices`. Same calls; the script check returns the same answers (parity confirms).
- `\p{Han}` became `\p{scx=Han}` in two regexes. Same results on the Mac (gloss-table and senses identical).
- EmbeddedModel: priming prefixes is off on the Mac (`LONGYAN_PRIME` defaults to off outside Windows), the prefix minimum stays 64, and the rest is Windows-only or behind new env vars. The CPU checks don't exist on the Mac (`tooSlow` is false).
- `LookupState`, `PhraseState` and `AnkiButtonModel` moved from ObservableObject to @Observable. The renders and traces look right, but this is the one change the renders can't fully cover. The usage simulation would, and it wasn't run here (below).
- Card buttons gained script and trace hooks. With no `--script` or `--trace` they read nil and add no modifiers.

## Not run

- The usage simulation. It needs a `--dev` build opened with `open`, writes to the real history, changes settings while it runs and sends mouse events for the drag checks. The plan says it passed the same 123 checks as main on shared-core.
- Selection reading in real apps, the shortcut, login item and a real Sparkle update. None of that code changed.
- `--show` on main: main has no `--show`, `--trace` or `--script`, so the traces were checked against each other and against the source's motion constants.

## How to repeat

Scripts used are in the session scratch folder, but the steps are: parity.py with each binary; `windows/gallery/cases.tsv` drawn by each binary's `--render` and `--render-phrase` using only the env vars main has, then compared pixel by pixel; `scripts/evals.sh` in each worktree, alternating; `--lookup` on the output of `scripts/eval-lookups.py notes/note-pick-eval.tsv notes/phrase-eval.tsv`; `--lookup` and `--phrase` with `LONGYAN_TIMING=1` for timings. The defaults domains LongyanReader and com.mapuchuu.longyanreader and the history file were the same before and after.
