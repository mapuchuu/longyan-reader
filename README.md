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
   - **Anything longer** gets the phrase card. It opens at once and fills in from the top:
     - a translation, typed in as it's written. With the local model it comes from Qwen, which handles slang and idioms far better than Apple's Translation framework (内卷 "involution" rather than "internal entanglement", 小意思 "a small token" rather than "a little interesting", 佛系 "laid-back" rather than "Buddhist"). Apple's translator is the fallback;
     - then each word with its meaning in this passage, the rows filling in top to bottom as the model picks them. Opening a row never changes it; click a word for its other meanings or to pick one yourself.

     The work starts as soon as the selection button appears, while you move to click it, so it's often finished by the time the card opens. The local model picks all the words in one streamed request (the model answers one request at a time, so word-by-word calls would queue up): the translation starts in about 0.15 s and a sentence's words are done in about 1–2 s. With Apple's model the words are picked separately, a few seconds per sentence, and still shown in reading order.

     With Apple's model, words whose meaning is settled without it skip the model call: grammar words by position (了 at the end of a sentence, 地, 得 after a verb), then a sense the translation agrees with, except for words with notes. `notes/phrase-eval.tsv` holds labelled sentences, half for tuning (D) and half held out (H): `--eval-phrase notes/phrase-eval.tsv H` scores the current sense picker.

     Words are split by the system tokenizer plus dictionary rules: neighbouring single characters that make a dictionary word are joined (slang the tokenizer doesn't know: 躺平, 摸鱼, 破防, 内卷), and a degree adverb is split off a word it was glued to (真心|疼 → 真|心疼).

If the model is unavailable or rejects a prompt, the cards still show the dictionary senses in their usual order.

**Cards.** Both cards sit on the translucent popover material with continuous rounded corners. They spring in once measured (a word card also waits up to 0.4 s for its answer, usually started when the text was selected, so it opens complete), cross-fade the model's answer and notes, fade rows open, resize smoothly as content changes (keeping the edge nearest the selection fixed), and fade out on close. Drag the bottom-right corner to zoom the card: text, spacing and dots scale together (0.8× to 2.2×) and the height follows the content. The zoom is remembered separately for word and phrase cards, and double-clicking the grip resets it to 1×. Tone and note colours are muted, appearance-aware tones rather than the bright system colours. A clean near-white (near-black in dark mode) surface sits over the material so cards don't read grey, and the selection button uses the same style. The menu's **Appearance** submenu sets the cards and button to Match System, Light or Dark, and picks a style: **Classic** (the material and clean surface) or **Liquid Glass** (macOS 26 only: the system glass, `.glassEffect`, with a light frosted tint, and an interactive glass selection button).

Size changes animate inside the card, never by animating the window: the window is a transparent frame with room for the card's own shadow, resized instantly (growing before an expansion, shrinking after a contraction), so no rectangular window edge or stale shadow can flash mid-animation.

## Install

Download `LongyanReader-<version>.zip` from Releases, unzip it, and move **Longyan Reader** to Applications. It needs macOS 15 or later on Apple silicon. On macOS 15 the sense picker and translations come only from the local Qwen model (downloaded from the menu), since Apple's on-device model and translator need macOS 26, and cards use the Classic style.

The app is free and open source, so it isn't signed with a paid Apple Developer ID, and macOS blocks it the first time:

1. Open it once. macOS says it can't verify the developer; click **Done**.
2. Go to System Settings → Privacy & Security, scroll down, and click **Open Anyway** next to Longyan Reader. Confirm with your password.

A welcome window then asks for **Accessibility** (System Settings → Privacy & Security → Accessibility), which is how it reads the text you highlight. It notices as soon as you turn it on. No other permissions are used.

**Updates.** On its second launch the app asks whether to check for updates automatically; **Check for Updates…** in the menu checks any time. Updates are downloaded from this repository's GitHub releases, verified against the key built into the app, and installed in place. Every release is signed with the same certificate, so Accessibility stays allowed after updating.

**Uninstall.** Quit it, then move these to the Trash: **Longyan Reader** from Applications, `~/Library/Application Support/LongyanReader` (the downloaded model, 2.7 GB) and `~/Library/Logs/LongyanReader` (lookup history), and remove it from the Accessibility list.

## Privacy

Lookups are processed on your Mac: the dictionary is bundled and the model runs locally. Lookup history is **on** by default: **History…** (⌘Y in the menu) lists every word with the meaning it had in its sentence and every phrase with its translation, searchable, and exports them as Anki flashcards (a text file Anki's File › Import reads straight into a "Longyan Reader" deck) or a CSV spreadsheet, one row per word and meaning. Lookup History in the menu turns it off, keeps 30 days, shows the file, or moves it to the Trash. Nothing in it leaves your Mac unless you export it. The app goes online only to download the model when you ask for it and to check for updates (automatically only if you agreed, otherwise when you choose Check for Updates); an update check sends nothing beyond the request for the feed file. It's saved to `~/Library/Logs/LongyanReader/lookups.jsonl`, readable only by your account.

## Build and run

You need the Xcode Command Line Tools with the macOS 26 SDK (the app itself runs on macOS 15 and later). Full Xcode isn't required.

```bash
scripts/build-app.sh
open "build/Longyan Reader.app"
```

`scripts/build-app.sh --release` builds the download: a plain ad-hoc signature and `build/LongyanReader-<version>.zip`, with its SHA-256 printed for the release notes.

The eye icon in the menu bar shows the status of the dictionary, the model and the permission, and lets you turn the selection button off. Local builds are ad-hoc signed with a requirement on the bundle ID, so the permission survives rebuilds. Release builds aren't: that requirement would let any app using the same bundle ID inherit the permission.

## Testing without the hotkey

```bash
B=".build/release/LongyanReader"
$B --status                                         # dictionary and model availability
$B --lookup "他长得很高。" 长                        # segment, list senses, choose one
$B --phrase "快递员每天晚上都要上夜班分拣包裹。"       # the phrase card's pipeline: translation, then every word's sense
$B --segment-file sentences.txt                     # each line's word split, for comparing segmenter changes
$B --eval                                           # labelled cases: word, sense and tag accuracy
scripts/evals.sh                                    # every test, compared with scripts/eval-baseline.tsv
$B --check-data                                     # every note, example, cue and sense-order line still matches the dictionary
$B --render "明朝实行海禁，闭关锁国。" 锁 out.png       # draw the word card to a PNG
$B --render-phrase "明朝实行海禁，闭关锁国。" out.png 闭关锁国   # draw the phrase card, one word expanded
```

A scripted usage simulation drives the real cards through the same code paths as clicks and checks the results: tint and surface before and after picking another meaning in every style and mode, early picks not overwritten by the model, hint timers not closing the next card, phrase-row picking and switching with the window always holding the card, live style switching, and rapid lookups leaving one card. It needs a dev build, `scripts/build-app.sh --dev`: only that build listens for the probe notification, since any local process can post one. Trigger it with the notification `simulate` (report in `~/Library/Logs/LongyanReader/simulation.txt`; it restores your settings afterwards).

Each lookup appends a line to `~/Library/Logs/LongyanReader/lookups.jsonl`, a few hundred bytes each. Misses record why the selection couldn't be read.

## Status

The sense picker is Qwen 3.5 4B (Q4_K_M), run inside the app with [llama.cpp](https://github.com/ggml-org/llama.cpp) (release b11588's Metal framework, a SwiftPM binary target, bundled in `Contents/Frameworks`). The model file isn't bundled: **Download Qwen Model (2.7 GB)…** in the menu fetches `Qwen3.5-4B-Q4_K_M.gguf` from `unsloth/Qwen3.5-4B-GGUF` at a pinned revision, from hf-mirror.com and then huggingface.co, resuming if interrupted and keeping it only if its SHA-256 matches, into `~/Library/Application Support/LongyanReader/models/`. It's byte-identical to Ollama's `qwen3.5:4b`, so on a Mac with that installed the app uses Ollama's copy and needs no download (`LONGYAN_GGUF` points at any other file).

Without the file the app uses [Ollama](https://ollama.com) if it's running (`LONGYAN_BACKEND=ollama` forces it, for comparison), and Apple's on-device model otherwise; `apple` under Sense Picker or in `LONGYAN_MODEL` turns the local model off. The model gets a 2,048-token context and is unloaded after five idle minutes.

The embedded backend scores the same as Ollama on every test, with the same misses item for item. Qwen 3.5 is a hybrid model (its recurrent state can't be cut back to a shared prefix), so the state at the end of each of the last two prompts is saved and a repeated prompt (a card prepared, then opened) skips reading it. Each saved state is 58–81 MB (the recurrent state plus the prompt's cache); across the tests every reuse was of the latest one, so two (a card's pick and its translation) cover it, where six cost ~400 MB. Picks aren't written out: the answer's text up to each number (`{\n  "w01": `, or `等=` on a phrase's line) is added to the prompt and the number is read from the model's odds for the next token, one model pass per word instead of one per token of a written reply. Same prompts and answers as writing them (identical scores), in about half the time: single word ~0.13 s, phrase ~0.21 s; translation, which is written, ~0.23 s (`LONGYAN_PICK=generate` writes picks too, for comparison). The app's own memory is ~0.8 GB plus the 2.7 GB model file mapped from disk.

The dictionary ships compiled (`DictionaryFile.swift`): headwords sorted by their UTF-8 bytes and found by binary search in a file read straight from disk, so it opens in ~3 ms with almost nothing copied into memory, where parsing the text took ~1.4 s and ~85 MB. `scripts/build-app.sh` writes it with `--compile-dict`, which reads every headword back and fails on any difference from the text. Run from the repo, the CLI still parses `Resources/cedict_ts.u8`.

`scripts/evals.sh` runs every test and compares scores and timings with `scripts/eval-baseline.tsv` (exit 1 on fewer right answers, more wrong notes, or a timing over 15% slower; `--update` saves a new baseline). Each sense test also prints how often the model's picks were right at each confidence level; on real reading even its picks under 50% were mostly right (9 of 11), so no pick is held back for low confidence.

| Sense picker | Note test (52 held-out) | Wrong notes | Main test senses (29) | Per lookup | Memory in use |
|---|---|---|---|---|---|
| Apple 3B + tie-break rules | 38 | 5 | 22 | ~0.55 s | (system model) |
| **Qwen3.5 4B (default)** | **51** | **1** | **25** | **~0.15 s** | **2.9 GB** |
| Qwen3.5 2B (measured, not installed) | 35 | 2 | 22 | ~0.18 s | 1.6 GB |
| Qwen3.5 9B (measured, not installed) | 51 | 0 | 25 | ~0.62 s | 4.5 GB |

Rephrasing the question for Apple's model (meanings by name, examples in the prompt) did not help: 33–38/52 in every variant.

The tie-break rules (translation matching, a two-option question in both orders) only run with Apple's model; with Qwen they overrode correct answers.

Nuance notes are written ahead of time, one per dictionary sense that needs one, and shipped in `Resources/notes.json`. The pilot covers 502 words (95 idioms), written by Claude in a Claude Code session; see `notes/pilot/review.md`. Example sentences (`notes/pilot/examples.tsv`, 315 sentences for 198 senses) go into the local model's prompt, and `notes/pilot/note-covers.tsv` lets one note cover its paraphrase senses. For a full build, `NotesBuilder.swift` can also run the job through the Message Batches API (`--notes-submit`, `--notes-status`, `--notes-fetch`).

New notes come in batches: most looked-up words first, then by frequency (`notes/frequency.txt`, from jieba). `scripts/notes-batch.sh next` picks the next words into `notes/batches/NN/` and prints their senses. Write the notes into its `annotations.tsv`, `note-covers.tsv` and `examples.tsv` (a batch can be empty of notes for plain words; most senses need none). `scripts/notes-batch.sh finish NN` checks them, merges them into `Resources/`, runs the tests and saves the scores in the batch's folder. `scripts/notes-batch.sh status` shows progress. Example sentences go into the model's prompt and can pull other words off their right sense (时候 and 那个 both did), so add them only for senses that are really distinct, and take a drop in the `finish` scores seriously. To drop an example already merged, remove it from `Resources/examples.json` as well as the batch.

The model sees each noted sense with its note's first sentence, and a few fixed casual patterns it never reads correctly (这不科学, 你可以啊) are settled without it by `Resources/note-cues.json`. `notes/note-pick-eval.tsv` tests this with pairs: a casual use that should land on the noted sense, and a plain use that must not.

## Releases

`scripts/release.sh notes.md` builds the release, signs it and writes `build/release-<version>/` with the zip and `appcast.xml`; it prints the `gh release create` command that publishes both. Installed copies read the feed from the latest release, so publishing is what ships the update. Bump `version` in `scripts/build-app.sh` first; the build number is the commit count, so commit before releasing.

Two keys make releases, both kept outside the repo in `~/Library/Application Support/LongyanReader-signing/`, and both need a backup: the self-signed code-signing certificate (`longyan-codesign.p12`, password in the login keychain under `longyan-signing`), which keeps every version the same app to macOS, and Sparkle's update key (in the login keychain; exported as `sparkle-private-key.txt`), without which installed copies reject updates. Sparkle's tools (2.10.1) are in the same folder.

## Licences

The code is under the [MIT License](LICENSE). Data derived from CC-CEDICT (`Resources/cedict_ts.u8`, `Resources/sense-order.tsv`, `Resources/extra-words.u8`, and the app's compiled `cedict.bin`, shipped with the dictionary's license header in the app's `Contents/Resources/Licenses/`) stays under CC BY-SA 4.0, as CC-CEDICT requires. llama.cpp is MIT (`Resources/licenses/llama.cpp-LICENSE.txt`, shipped beside it), Sparkle is MIT (`Resources/licenses/Sparkle-LICENSE.txt`, likewise), and the Qwen model, downloaded separately from Hugging Face, is Apache 2.0.

About Longyan Reader in the menu lists the credits below. Sense picks and translations come from a language model and can be wrong; the nuance notes were written by Claude and checked against the senses they attach to.

The Longyan eye icon is from the Longyan Chrome extension.

CC-CEDICT is © MDBG and contributors under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). The release used is committed (`Resources/cedict_ts.u8`, with its license header), so every build reads the same dictionary. `scripts/fetch-cedict.sh` moves to a newer release, keeping it only if `--check-data` still passes, and `scripts/build-app.sh` runs the same check.

的 and 了 skip sense picking. They show one fixed line (`GrammarWords.swift`), and opening them lists only that reading's meanings, in short wording; 了 after 不, or after 得 following a verb (受得了), reads liǎo; after a pronoun 得 is the verb (他得了感冒), so 了 reads le. Lists of meanings shorten any definition past about two lines, and the full text is in its tooltip.

Cards can be dragged from anywhere but the resize corner. A dragged card stays open through scrolling elsewhere, and the next card opens by its word as usual.
