# Development

## Building

You need the Xcode Command Line Tools with the macOS 26 SDK. Full Xcode isn't required. The app itself runs on macOS 15 and later, Apple silicon only.

```bash
scripts/build-app.sh
open "build/Longyan Reader.app"
```

`scripts/build-app.sh --dev` adds the debug notification used by the probe and the usage simulation (see below). It's never in release builds, since any local process can post one.

Local builds are ad-hoc signed with a designated requirement on the bundle ID only, so the Accessibility permission carries over between rebuilds. Release builds don't do this, because that requirement would let any app with the same bundle ID inherit the permission.

## How a lookup works

1. **Trigger.** When you finish a selection (a drag or a double-click) the eye button appears near the pointer. It goes away on the next click, key press or scroll, or after 6 seconds. ⌃⌥L does the same from the keyboard, and with nothing selected it looks up the word under the pointer.
2. **Reading the selection.** The app asks the frontmost app for the selected text and the paragraph around it through the Accessibility API. Native text views report a character range, web views (Safari, Chrome) a text-marker range, and Chrome and Electron apps have their accessibility tree switched on the first time. If an app won't report its selection, the app sends ⌘C, reads the clipboard and puts the old clipboard back. That route has no surrounding context.
3. **Word or phrase.** A single dictionary word gets the word card; anything longer gets the phrase card.
   - The word card shows the [CC-CEDICT](https://cc-cedict.org/) sense the model picked for this sentence, plus any note. The model only ever picks from the dictionary's list. It never writes definitions.
   - The phrase card opens straight away and fills in from the top: the translation as it's generated, then each word's meaning as the model picks it.

Work starts when the eye appears, while you move to click it, so the card is often ready when it opens. All the words in a phrase are picked in one streamed request, since the model answers one request at a time and per-word calls would queue up. The translation starts in about 0.15 s and a sentence's words are done in 1 to 2 s.

Words are split by the system tokenizer plus dictionary rules: neighbouring single characters that form a dictionary word are joined (slang the tokenizer doesn't know, like 躺平, 摸鱼, 破防), and a degree adverb glued to the next word is split off (真心|疼 → 真|心疼).

的 and 了 skip sense picking and show one fixed line (`GrammarWords.swift`). 了 reads liǎo after 不, or after 得 following a verb (受得了); after a pronoun 得 is the verb (他得了感冒), so 了 reads le.

If the model is unavailable or fails, cards still show the dictionary senses in their usual order.

## Cards

Cards use the popover material with a near-white (near-black in dark mode) surface on top, so they don't look grey. Appearance in the menu sets Light, Dark or Match System, and a style: Classic, or Liquid Glass on macOS 26.

Size changes are animated inside the card, never by animating the window. The window is a transparent frame with room for the card's shadow and is resized instantly (grown before an expansion, shrunk after a contraction), so no window edge or stale shadow shows mid-animation.

Dragging the bottom-right corner zooms the card from 0.8× to 2.2×. Word and phrase cards remember their zoom separately, and double-clicking the grip resets it. Cards can be dragged from anywhere else, and a dragged card stays open while you scroll.

## The model

The sense picker and translator is Qwen 3.5 4B (Q4_K_M), run in the app with [llama.cpp](https://github.com/ggml-org/llama.cpp) (release b11588's Metal framework, a SwiftPM binary target bundled in `Contents/Frameworks`).

The model file isn't bundled. `ModelDownloader.swift` fetches `Qwen3.5-4B-Q4_K_M.gguf` from `unsloth/Qwen3.5-4B-GGUF` at a pinned revision, trying hf-mirror.com first and then huggingface.co. It resumes partial downloads and keeps the file only if its SHA-256 matches. It goes to `~/Library/Application Support/LongyanReader/models/`. The file is byte-identical to Ollama's `qwen3.5:4b`, so if Ollama has it the app uses that copy instead. `LONGYAN_GGUF` points at any other file.

Without the file the app uses [Ollama](https://ollama.com) if it's running, and Apple's on-device model otherwise (macOS 26 only). `LONGYAN_BACKEND=ollama` forces Ollama for comparison. Choosing `apple` under Sense Picker, or setting `LONGYAN_MODEL=apple`, turns the local model off.

Some details:

- The context is 2,048 tokens. The model is unloaded after five idle minutes.
- The weights are mapped from disk, not copied, so the app's own memory footprint with the model loaded is about 0.5 GB. macOS can drop the mapped pages under memory pressure and read them back later.
- Qwen 3.5 is a hybrid model, and its recurrent state can't be cut back to a shared prefix. So the state at the end of each of the last two prompts is saved (58 to 81 MB each), and a repeated prompt, such as a card prepared and then opened, skips re-reading it.
- Picks aren't generated as text. The answer up to each number (`{\n  "w01": `, or `等=` on a phrase's line) is added to the prompt and the number is read from the model's probabilities for the next token. That's one pass per word instead of one per token, with identical results in about half the time: a single word takes about 0.13 s, a phrase 0.21 s. `LONGYAN_PICK=generate` generates them instead, for comparison.
- On real reading, even picks with under 50% confidence were mostly right (9 of 11), so no pick is held back for low confidence.

| Sense picker | Note test (52 held out) | Wrong notes | Main test (29) | Per lookup |
|---|---|---|---|---|
| Apple 3B + tie-break rules | 38 | 5 | 22 | ~0.55 s |
| **Qwen 3.5 4B (default)** | **51** | **1** | **25** | **~0.15 s** |
| Qwen 3.5 2B (not used) | 35 | 2 | 22 | ~0.18 s |
| Qwen 3.5 9B (not used) | 51 | 0 | 25 | ~0.62 s |

Rewording the prompt for Apple's model (meanings by name, examples in the prompt) didn't help: 33 to 38 out of 52 in every variant. The tie-break rules (matching against the translation, asking a two-option question both ways round) only run with Apple's model; with Qwen they overrode correct answers. With Apple's model, words whose meaning is settled without it skip the model call: grammar words by position, then a sense the translation agrees with, except for words that have notes.

## The dictionary

The dictionary ships compiled (`DictionaryFile.swift`): headwords sorted by their UTF-8 bytes and found by binary search in a file read straight from disk. It opens in about 3 ms with almost nothing copied into memory, where parsing the text took 1.4 s and 85 MB. `scripts/build-app.sh` writes it with `--compile-dict`, which reads every headword back and fails on any difference. Run from the repo, the CLI still parses `Resources/cedict_ts.u8`.

The CC-CEDICT release is committed, so every build uses the same dictionary. `scripts/fetch-cedict.sh` moves to a newer release, keeping it only if `--check-data` still passes.

## Testing

The binary has a command-line mode for testing without the hotkey:

```bash
B=".build/release/LongyanReader"
$B --status                                         # dictionary and model availability
$B --lookup "他长得很高。" 长                        # segment, list senses, pick one
$B --phrase "快递员每天晚上都要上夜班分拣包裹。"       # the phrase card's pipeline
$B --segment-file sentences.txt                     # word split for each line
$B --eval                                           # labelled cases: word, sense and tag accuracy
$B --check-data                                     # notes, examples, cues and sense order still match the dictionary
$B --render "明朝实行海禁，闭关锁国。" 锁 out.png       # draw the word card to a PNG
$B --render-phrase "明朝实行海禁，闭关锁国。" out.png 闭关锁国   # draw the phrase card with one word expanded
$B --render-onboarding offer out.png                # draw a state of the welcome window
```

`LONGYAN_APPEARANCE=light|dark` sets the appearance of renders, and `LONGYAN_RENDER_CLEAR=1` drops the backdrop (used for the website's images).

`scripts/evals.sh` runs every test and compares scores and timings with `scripts/eval-baseline.tsv`. It exits with 1 on fewer right answers, more wrong notes, or anything more than 15% slower. `--update` saves a new baseline.

`notes/phrase-eval.tsv` has labelled sentences, half for tuning (D) and half held out (H): `--eval-phrase notes/phrase-eval.tsv H` scores the current picker. `notes/note-pick-eval.tsv` tests noted senses in pairs: a casual use that should land on the noted sense, and a plain use that shouldn't.

### Usage simulation

A scripted simulation drives the real cards through the same code paths as clicks and checks the results: the tint and surface before and after picking another meaning in every style and mode, early picks not being overwritten by the model, hint timers not closing the next card, picking and switching in phrase rows, live style switching, and fast repeated lookups leaving one card. It needs a `--dev` build. Post the notification `simulate`; the report goes to `~/Library/Logs/LongyanReader/simulation.txt`, and your settings are restored afterwards.

Each lookup appends a few hundred bytes to `~/Library/Logs/LongyanReader/lookups.jsonl`. Misses record why the selection couldn't be read.

## Notes

Notes are written ahead of time, one per dictionary sense that needs one, and shipped in `Resources/notes.json`. Read `notes/style.md` before writing any: notes are one or two short, plain sentences.

New notes come in batches, most looked-up words first, then by frequency (`notes/frequency.txt`, from jieba):

- `scripts/notes-batch.sh next` picks the next words into `notes/batches/NN/` and prints their senses.
- Write the notes into the batch's `annotations.tsv`, `note-covers.tsv` (one note covering its paraphrase senses) and `examples.tsv`. Most senses need no note.
- `scripts/notes-batch.sh finish NN` checks them, merges them into `Resources/`, runs the tests and saves the scores in the batch folder.
- `scripts/notes-batch.sh status` shows progress.

Example sentences go into the model's prompt and can pull other words off their right sense (时候 and 那个 both did), so only add them for senses that are really distinct, and take a drop in the `finish` scores seriously. To drop an example that's already merged, remove it from `Resources/examples.json` as well as the batch.

The model sees each noted sense with the first sentence of its note. A few fixed casual patterns it never reads correctly (这不科学, 你可以啊) are settled without it by `Resources/note-cues.json`.

`NotesBuilder.swift` can also run a notes job through the Message Batches API (`--notes-submit`, `--notes-status`, `--notes-fetch`).

## Releases

1. Bump `version` in `scripts/build-app.sh` and commit. The build number is the commit count, so the tree has to be clean.
2. Run `scripts/release.sh notes.md`, where `notes.md` is what's new (shown in the update window).
3. Run the `gh release create` command it prints.

The release is signed, zipped, and written to `build/release-<version>/` with `appcast.xml`. Installed copies read the feed from the latest release, so publishing the release is what ships the update. The zip is uploaded twice: once with the version in its name, which the appcast points to, and once as `LongyanReader.zip`, which the website's download button links to.

Two keys are needed to make releases. Both are kept outside the repo in `~/Library/Application Support/LongyanReader-signing/`, and both need a backup:

- The self-signed code-signing certificate, `longyan-codesign.p12` (password in the login keychain under `longyan-signing`). It keeps every version the same app as far as macOS is concerned, so Accessibility stays allowed after an update.
- Sparkle's update key (in the login keychain, exported as `sparkle-private-key.txt`). Without it, installed copies will reject updates.

Sparkle's tools (2.10.1) are in the same folder.

## Website

[longyan.app](https://longyan.app) is the static page in `site/`, deployed to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that changes it. The domain's DNS is on Cloudflare, set to DNS only (not proxied) so GitHub can renew the HTTPS certificate. `site/DESIGN.md` has the design decisions.

- `hero.js` draws the opening on one canvas: mountains halftoned in Chinese characters, and the Longyan eye built from its geometry (see the comment at the top), set in the `PAGE` sentences of `scripts/site-data.py`. The characters come in many sizes, whole, never cut; on the outline they may stand a hair past the edge, and a few small ones bridge the pupil's point to the wedge. Each has a fixed pearl tint. Pointing at a character shows the app's reading of it in its sentence. On scroll the eye breaks up and its characters, mostly the big ones, float into the demo sentence, which then hands over to `try.js` in one frame. The scroll is paced in `progressAt`: three quarters of a screen to form the sentence, then 0.8 of a screen held to try it, while `holdAt` plays the selection and bars in seconds. `?t=9` starts the animation nine seconds in, `?p=0.4` jumps to that point of the story, and `?og` draws the social preview (`images/og.jpg`, 1200×630).
- `card.js` is the app's card for the web: the word card, the phrase card and the peek card, ported from `CardChrome.swift`, `Popup.swift` and `PhraseCard.swift` with the same sizes, dark colors, Liquid Glass, springs, row highlights, Listen, Copy, Pin, moving and resizing, and the "Part of" row a lone character's card shows. `openWord(data, anchor, inline)` with an element as `inline` builds the card into the page instead, as the statement's 躺平 card is: it stays put and isn't closed by clicks or scrolling. Keep it in step when the cards change.
- `try.js` makes the demo sentence something to try: select any run of characters, as in any Mac text; the selection stays as made and the card opens for what the app reads there, widened to whole words as the app does (⌃⌥L works too). It also builds the statement's card. The content is the app's own: `scripts/site-data.py` runs `LongyanReader --site-json` on each demo sentence, which runs the cards' state classes on every selection the sentence allows (trimmed and widened to whole words as `App.show` does) and writes what they'd show to `site/data.js`. For the hero's `PAGE` sentences it runs `--site-words`, which does the same for just their words. Rerun it after a release build when the data changes, or after changing `DEMO`.
- `paper.js` draws the backdrops (sheets of colour over a night ground, like a Mac wallpaper) with one WebGL context. `motion.js` does the scroll reveals, pins the statement and shows its three lines one at a time with a progress bar per line, stepping its card along with them (meanings, then the pick, then the note), and loads the video.
- `tiles.js` brings new words into the History tile; the other tiles' loops are CSS, run while `motion.js` marks a tile "live". `install.js` plays the install steps on the Mac screen: each scene is a CSS animation started by a class on the desk (`s0` to `s3`), laid out at 760 px (620 on a phone) and scaled to fit.
- `index.html` loads the stylesheet and scripts with a version stamp (`?v=…`). Change it when they change, so browsers and GitHub Pages' cache don't serve old copies.
- The recording is `site/media/reading-3.mp4` (HEVC, 2240×1260, about 2.6 Mbit/s, no audio, fast start) with `reading-3-h264.mp4` (H.264, 4.5 Mbit/s) for browsers without HEVC, and `reading-3.jpg` as its first frame. To replace it, use new file names (browsers cache these) and update `index.html`; if its shape changes, match `aspect-ratio` on `.screen`.
- To preview, serve the folder (`python3 -m http.server --directory site`). `?still` turns off scroll motion for screenshots.

## Licenses

Data derived from CC-CEDICT (`Resources/cedict_ts.u8`, `Resources/sense-order.tsv`, `Resources/extra-words.u8`, and the compiled `cedict.bin`, shipped with the dictionary's license header in `Contents/Resources/Licenses/`) is CC BY-SA 4.0, as CC-CEDICT requires. llama.cpp and Sparkle are MIT; their licenses are in `Resources/licenses/` and ship with the app.
