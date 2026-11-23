# Card gallery

Each `NAME.json` here is a card as the bridge sends it. `scripts/card-gallery.sh` makes them
on a Mac with the model, and draws the Mac's version of each into `mac/`. The Windows app
draws them with `LongyanReader.exe --render windows/gallery OUT` (gallery.yml).

## Filming a live card: --show

`--show CARD.json X Y` opens the real, live card for one of these files, on either app, with
no model. Both open it the same way, so the two can be filmed side by side doing the same
things: the reveal, hover, Show All, picking a meaning, the note, Copy, Pin, Listen, moving,
resizing, Esc and clicking away.

Mac, from the repo:

    swift build -c release --product LongyanReader
    .build/release/LongyanReader --show windows/gallery/word-mianzi.json 300 200

Windows, in the app's folder:

    LongyanReader.exe --show C:\path\to\windows\gallery\word-mianzi.json 300 200

- X and Y are where the selection would be: the box (X, Y, 60, 20), measured from the top-left
  of the main screen. Points on the Mac (the screen with the menu bar), DIPs on Windows (the
  primary screen). The card opens below it, 8 under its bottom edge, as for a real lookup.
- When the card closes it opens again a second later in the same place, for another take.
  Quit with Ctrl+C on the Mac, and from the icon's menu ("Quit card show") on Windows.
- The card starts at the usual size, unpinned. Resizing and pinning last for the run only, and
  nothing goes in the history.
- The dictionary gives each card's meanings and rows; the JSON gives what the model said. A
  phrase row that's opened shows the dictionary's meanings with the JSON's pick, so
  phrase-ming.json's 明朝 opens just as phrase-ming-open.json shows it.
- Nothing asks the model. "Part of" opens the whole word still reading the sentence, and so
  does a row that's still loading in the JSON (phrase-pending.json). A JSON with "back" (a
  meaning the reader picked) opens with the model's meaning instead.
- On the Mac, Esc and clicks in other apps close the card only if the terminal it runs from has
  Accessibility, as the app does.

### Options

Both apps take the same options after X and Y, in any order:

- `--script "PLAN"` or `--script @FILE` works the card from inside the app, with no hand on
  the mouse, each time it opens. A plan is steps `t,action[,target]` split by `;` (or one per
  line in a file, `#` lines skipped). `t` is seconds after the reveal has finished (0.5 s after
  it starts). Actions: `hover T`, `unhover`, `press T`, `release`, `click T` (press, then
  release 70 ms later), `esc`, `close` (a click elsewhere), `reopen`. Targets: `row1`... (the
  meanings in the order shown; in a phrase card, the open row's), `phrase-row1`..., `pin`,
  `copy`, `listen`, `anki`, `note`, `back`, `showall`, `partof`, `badge`. A step goes through
  the same handlers a real pointer does, so hover, press and the click look and act the same.
  The real mouse still works beside it. Each step is a line on stderr, `script mono=SECONDS
  STEP`, with the time since boot, to line the two films up; Windows also puts them in the
  event log (LONGYAN_CARD_LOG) as `"event":"script"`. Ready plans: `plans/word.txt`
  (word-mianzi, word-bgsg) and `plans/phrase.txt` (phrase-ming).
- `--appearance light|dark` holds the card in light or dark for the run. Nothing in the system
  or the app's settings changes.
- `--trace FILE` writes one JSON line for every frame drawn while anything on the card moves
  (a line only when something differs from the last): `mono` (ms since boot), `card` (which
  card), the window's `alpha` and `frame` (x, y, width, height from the main screen's
  top-left, as X and Y; the window has the shadow margin around the card), the card's reveal
  `scale`, `dy` and `height`, and `elements`, each moving part by name with its `opacity`,
  `scale`, `rotation` or `dy`: `row1-hover`, `row1-checkmark`, `phrase-row1-chevron`,
  `showall-chevron`, `back-to`, `note-box`, `detail`, `pin-badge`, `copy-hover`,
  `copy-press`, and the same for pin, listen and anki. The Mac reads SwiftUI's own values each
  frame (a probe beside each animated modifier) and the window's alpha on the display's clock;
  Windows reads the animated values on each rendered frame. Not in both: Windows adds
  `copy-symbol` (and the other buttons' symbols: the checkmark's pop), which the Mac draws with
  an SF Symbols transition it can't read; the Mac adds `badge-hover` and `badge-press`. On the
  Mac a part that has gone keeps its last value; on Windows it drops out of the line.

For example, on the Mac:

    .build/release/LongyanReader --show windows/gallery/word-mianzi.json 300 200 \
        --script @windows/gallery/plans/word.txt --appearance dark --trace /tmp/mac-trace.jsonl

and on Windows:

    LongyanReader.exe --show C:\path\to\windows\gallery\word-mianzi.json 300 200 --script @C:\path\to\windows\gallery\plans\word.txt --appearance dark --trace C:\temp\win-trace.jsonl 2> C:\temp\win-script.txt

Good cases to film: word-mianzi (a note, three meanings to pick from), word-bgsg (tone colours,
two meanings) and phrase-ming (rows that open).
