# Longyan Reader

A macOS menu-bar prototype: highlight Chinese text in any app, then click the small Longyan eye that appears beside it (or press **⌃⌥L**). The popup explains the text *in context*. It runs fully offline, with no API key.

It's a sibling of [Longyan](https://github.com/mapuchuu/longyan), the Chrome extension, and is built on the same idea: say what a word means in context, not just list everything it can mean.

## How it works

1. **Trigger.** When you finish selecting text (a drag or a double-click), a small eye button appears near the pointer. Click it to look up the selection. It disappears on your next click, key press or scroll, or after 6 seconds. ⌃⌥L does the same from the keyboard. With nothing selected, ⌃⌥L looks up the word under the pointer.
2. **Read the selection.** It asks the app through the macOS Accessibility API for the selected text and the paragraph around it:
   - native text views (TextEdit, Notes, Pages, Preview) report a character range;
   - web pages (Safari, Chrome) report a text-marker range;
   - Chrome and Electron apps have their accessibility tree switched on the first time.

   If an app won't report its selection, clicking the eye sends ⌘C, reads the clipboard, and puts your previous clipboard back. That route has no surrounding context.
3. **One word or a phrase.**
   - **A single dictionary word** gets the word card. Apple's on-device model (FoundationModels) picks the [CC-CEDICT](https://cc-cedict.org/) sense that fits the passage, says what the word means here, and can add a *lost in translation* or *cultural context* note. It picks from the dictionary list and never writes definitions of its own.
   - **Anything longer** gets the phrase card:
     - a translation from Apple's on-device Translation framework;
     - each word with a quick gloss, using the sense that agrees with the translation;
     - click a word to have the model choose its sense in this passage.

If the model is unavailable or rejects a prompt, the cards still show the dictionary senses in their usual order.

## Build and run

You need macOS 26 and the Xcode Command Line Tools. Full Xcode isn't required.

```bash
scripts/build-app.sh
open "build/Longyan Reader.app"
```

On first run, allow **Accessibility** in System Settings → Privacy & Security. It's needed to read the selection and to see when you select text. No other permissions are used.

The eye icon in the menu bar shows the status of the dictionary, the model and the permission, and lets you turn the selection button off. Builds are ad-hoc signed with a requirement on the bundle ID, so the permission normally survives rebuilds.

## Testing without the hotkey

```bash
B=".build/release/LongyanReader"
$B --status                                         # dictionary and model availability
$B --lookup "他长得很高。" 长                        # segment, list senses, choose one
$B --phrase "快递员每天晚上都要上夜班分拣包裹。"       # phrase words, translation, translation-aligned glosses
$B --eval                                           # labelled cases: word, sense and tag accuracy
$B --render "明朝实行海禁，闭关锁国。" 锁 out.png       # draw the word card to a PNG
$B --render-phrase "明朝实行海禁，闭关锁国。" out.png 闭关锁国   # draw the phrase card, one word expanded
```

Each lookup appends a line to `~/Library/Logs/LongyanReader/lookups.jsonl`, a few hundred bytes each. Misses record why the selection couldn't be read.

## Status

Current `--eval` score: words 15/16, senses 13/16, no errors, about 0.35 s per lookup on an M5 Pro. When the model refuses a sentence, the sense is matched to an on-device translation of it instead.

The on-device model is about 3B parameters. It's decent at saying what a word means in context. It was confidently wrong when writing nuance notes (熟练 "skilled" tagged as cultural context), so it no longer writes them.

Next: write nuance notes at build time with a stronger model, per dictionary sense, for common words and idioms. Ship them with the app, and let the on-device model only pick the sense.

## Licences

The Longyan eye icon is from the Longyan Chrome extension.

CC-CEDICT is © MDBG and contributors under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). It's downloaded by `scripts/fetch-cedict.sh` and not committed here.
