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

**Cards.** Both cards sit on the translucent popover material with continuous rounded corners. They spring in once measured, cross-fade the model's answer and notes, slide rows open, resize smoothly as content changes (keeping the edge nearest the selection fixed), and fade out on close. Drag the bottom-right corner to zoom the card: text, spacing and dots scale together (0.8× to 2.2×) and the height follows the content. The zoom is remembered separately for word and phrase cards, and double-clicking the grip resets it to 1×. Tone and note colours are muted, appearance-aware tones rather than the bright system colours. A clean near-white (near-black in dark mode) surface sits over the material so cards don't read grey, and the selection button uses the same style. The menu's **Appearance** submenu sets the cards and button to Match System, Light or Dark, and picks a style: **Classic** (the material and clean surface) or **Liquid Glass** (macOS 26's system glass, `.glassEffect`, with a light frosted tint, and an interactive glass selection button).

Size changes animate inside the card, never by animating the window: the window is a transparent frame with room for the card's own shadow, resized instantly (growing before an expansion, shrinking after a contraction), so no rectangular window edge or stale shadow can flash mid-animation.

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

The sense picker uses a local model through [Ollama](https://ollama.com) when it is running (default `qwen3.5:4b`; choose it in the menu under Sense Picker, or set `LONGYAN_MODEL`, or `apple` to turn it off), and falls back to Apple's on-device model otherwise. The model gets a 2,048-token context and is unloaded after five idle minutes.

| Sense picker | Note test (52 held-out) | Wrong notes | Main test senses (29) | Per lookup | Memory in use |
|---|---|---|---|---|---|
| Apple 3B + tie-break rules | 38 | 5 | 22 | ~0.55 s | (system model) |
| **Qwen3.5 4B (default)** | **51** | **1** | **25** | **~0.39 s** | **2.9 GB** |
| Qwen3.5 9B (measured, not installed) | 51 | 0 | 25 | ~0.62 s | 4.5 GB |

Rephrasing the question for Apple's model (meanings by name, examples in the prompt) did not help: 33–38/52 in every variant.

The tie-break rules (translation matching, a two-option question in both orders) only run with Apple's model; with Qwen they overrode correct answers.

To set up Qwen without Ollama's downloader (for example behind a fake-IP proxy), download `Qwen3.5-4B-Q4_K_M.gguf` (2.74 GB) from the `unsloth/Qwen3.5-4B-GGUF` repo (hf-mirror.com works in China) and run `ollama create qwen3.5:4b -f Modelfile` with `FROM ./Qwen3.5-4B-Q4_K_M.gguf`.

Nuance notes are written ahead of time, one per dictionary sense that needs one, and shipped in `Resources/notes.json`. The pilot covers 502 words (95 idioms), written by Claude in a Claude Code session; see `notes/pilot/review.md`. Example sentences (`notes/pilot/examples.tsv`, 315 sentences for 198 senses) go into the local model's prompt, and `notes/pilot/note-covers.tsv` lets one note cover its paraphrase senses. For a full build, `NotesBuilder.swift` can also run the job through the Message Batches API (`--notes-submit`, `--notes-status`, `--notes-fetch`).

## Licences

The Longyan eye icon is from the Longyan Chrome extension.

CC-CEDICT is © MDBG and contributors under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). It's downloaded by `scripts/fetch-cedict.sh` and not committed here.
