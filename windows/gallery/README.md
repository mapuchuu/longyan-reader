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

Good cases to film: word-mianzi (a note, three meanings to pick from), word-bgsg (tone colours,
two meanings) and phrase-ming (rows that open).
