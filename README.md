# Longyan Reader

A macOS menu-bar prototype: hover over a Chinese word in any app, press **⌃⌥L**, and a popup explains what that word means *in this sentence*. It works fully offline, with no API key.

It's a sibling of [Longyan](https://github.com/mapuchuu/longyan), the Chrome extension, and is built on the same idea: say what a word means in context, not just list everything it can mean.

## How it works

1. **Capture.** It reads the text under the cursor through the macOS Accessibility API, which gives exact text in apps that expose it. If the app doesn't, it falls back to on-device OCR (Vision) of a strip of screen around the cursor, which covers scanned PDFs, images and uncooperative apps.
2. **Segment.** It finds the word under the cursor with Apple's Chinese word tokenizer, checked against the dictionary. That separates 研究/生命 from 研究生, keeps four-character idioms whole, and takes 长得 rather than 长.
3. **Look up.** Definitions come from [CC-CEDICT](https://cc-cedict.org/), about 125k entries. Senses marked "(bound form)" are dropped when a character stands alone.
4. **Choose.** Apple's on-device model (FoundationModels, needs Apple Intelligence) is given the passage and the numbered senses. It returns what the word means here, which sense that is, and an optional *lost in translation* or *cultural context* note. It picks from the dictionary list and never writes definitions of its own.
5. **Show.** A Longyan-style popup appears: tone-coloured hanzi and pinyin, the meaning in context, the chosen sense highlighted, and the source sentence.

If the model is unavailable or rejects a prompt, the popup still shows the dictionary senses in their usual order.

## Build and run

You need macOS 26 and the Xcode Command Line Tools. Full Xcode isn't required.

```bash
scripts/build-app.sh
open "build/Longyan Reader.app"
```

On first run, allow both of these in System Settings → Privacy & Security:
- **Accessibility**, to read text under the cursor;
- **Screen Recording**, for the OCR fallback.

The 龍 menu-bar item shows the status of the dictionary, the model and both permissions. The app is ad-hoc signed, so macOS may ask for the permissions again after each rebuild.

## Testing without the hotkey

```bash
B=".build/release/LongyanReader"
$B --status                                   # dictionary and model availability
$B --lookup "他长得很高。" 长                  # segment, list senses, choose one
$B --eval                                     # labelled cases: word, sense and tag accuracy
$B --ocr image.png 0.35 0.16 --lookup         # OCR an image, take the character at (x, y from top)
$B --render "明朝实行海禁，闭关锁国。" 锁 out.png  # draw the popup to a PNG
```

Each real lookup also appends a line to `~/Library/Logs/LongyanReader/lookups.jsonl` and saves `last-popup.png`.

## Status

Current `--eval` score: words 15/16, senses 12/16, no errors, about 0.7 s per lookup on an M5 Pro.

The on-device model is about 3B parameters. It's good at saying what a word means in context, and weaker at:
- hard readings of single characters (行 in 行不行);
- grammar particles (了);
- writing nuance notes. Its notes are generic and well short of Longyan's quality.

The plan is to write those notes at build time with a larger model, per sense, and use the small model only to pick between them.

## Licences

CC-CEDICT is © MDBG and contributors under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). It's downloaded by `scripts/fetch-cedict.sh` and not committed here.
