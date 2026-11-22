# Development

## Building

You need the Xcode Command Line Tools with the macOS 26 SDK. Full Xcode isn't required. The app itself runs on macOS 15 and later, Apple silicon only.

```bash
scripts/build-app.sh
open "build/Longyan Reader.app"
```

The first build also builds llama.cpp into `Vendor/` (`scripts/build-llama.sh`, about 20 seconds): release b11588 with `patches/llama.cpp-output-tokens.patch`. It runs again whenever the patch changes. If cmake and ninja aren't installed, it gets them from pip. Run it once before a bare `swift build`.

`scripts/build-app.sh --dev` adds the debug notification used by the probe and the usage simulation (see below). It's never in release builds, since any local process can post one.

Local builds are ad-hoc signed with a designated requirement on the bundle ID only, so the Accessibility permission carries over between rebuilds. Release builds don't do this, because that requirement would let any app with the same bundle ID inherit the permission.

## Code layout

The package has two targets.

- `Sources/LongyanCore` is everything that decides what a card says: the dictionary, the segmenter, glosses, notes and cues, the model prompts and their fallbacks, Anki, and the cards' state (`LookupState`, `PhraseState`, `PhrasePrep`). It's plain Swift and Foundation, so an app on another platform can build the same logic. Its declarations are `package`, visible to the app but not an API.
- `Sources/LongyanReader` is the Mac app: reading the selection through Accessibility, the eye, the cards' SwiftUI views, the menu, windows, updates and the CLI.

The few things the core needs from the system come through `Platform` (`Platform.swift`): a Chinese word splitter, an English part-of-speech tagger, a fallback sense picker and a translator. On the Mac, `AppleServices.swift` fills them with NLTokenizer, NLTagger, Apple's on-device model and the Translation framework, at the start of `Main`. The cards' state classes use Observation (`@Observable`), which SwiftUI reads directly.

`scripts/parity.py` checks that a change to the core, or another platform's build, gives the same results. It runs about 940 sentences through the segmenter, every one-character click, every two to five character selection, every word's senses and every dictionary definition's card wording and part of speech, and writes them to a folder. Run it before and after, then compare the folders, or pass `--against` the earlier folder:

```bash
python3 scripts/parity.py .build/release/LongyanReader /tmp/before
# …change something, swift build -c release…
python3 scripts/parity.py .build/release/LongyanReader /tmp/after --against /tmp/before
```

It takes about four minutes and doesn't use the model. `scripts/evals.sh` covers the model's side.

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

The sense picker and translator is Qwen 3.5 4B (Q4_K_M), run in the app with [llama.cpp](https://github.com/ggml-org/llama.cpp) (release b11588 with one patch, built by `scripts/build-llama.sh` and bundled in `Contents/Frameworks`).

The model file isn't bundled. `ModelDownloader.swift` fetches `Qwen3.5-4B-Q4_K_M.gguf` from `unsloth/Qwen3.5-4B-GGUF` at a pinned revision, trying hf-mirror.com first and then huggingface.co. It resumes partial downloads and keeps the file only if its SHA-256 matches. It goes to `~/Library/Application Support/LongyanReader/models/`. The file is byte-identical to Ollama's `qwen3.5:4b`, so if Ollama has it the app uses that copy instead. `LONGYAN_GGUF` points at any other file.

Without the file the app uses [Ollama](https://ollama.com) if it's running, and Apple's on-device model otherwise (macOS 26 only). `LONGYAN_BACKEND=ollama` forces Ollama for comparison. Choosing Apple's Model Only under Reading Model, or setting `LONGYAN_MODEL=apple`, turns the local model off.

Some details:

- The context is 2,048 tokens. The model is unloaded after five idle minutes.
- The weights are mapped from disk, not copied, so the app's own memory footprint with the model loaded is about 0.6 GB. macOS can drop the mapped pages under memory pressure and read them back later. When macOS warns that memory is low, the saved states below are dropped; when it's critical, the model is unloaded too. `--pressure FILE` checks this: it translates FILE's 【】 lines, runs the handler's work for a warning and then critical, and translates again after each. With `wait` (and `LONGYAN_IDLE_UNLOAD=0`, so the idle unload doesn't look like pressure) it waits for real notices instead, from `sudo memory_pressure -S -l warn` or `-l critical`.
- Only the last token's next-word odds are read, so the context keeps room for one (`n_outputs_max`). The default sized llama.cpp's work buffer for every token of a batch: 507 MB instead of 79.
- Qwen 3.5 is a hybrid model, and its recurrent state can't be cut back to a shared prefix. So the state at the end of each of the last two prompts is saved (58 to 81 MB each), and a repeated prompt, such as a card prepared and then opened, skips re-reading it. The state after each kind of prompt's fixed start (instructions and examples) is saved too, so a new passage reads only its own turn. Saved states live in their own pages: in Swift arrays, the freed ones stayed with the process and the footprint grew past 1 GB. `LONGYAN_LLAMA_LOG=1` shows llama.cpp's own log.
- The model can only write the tokens in `Resources/output-tokens.txt` (67,535 of 248,320: everything in CC-CEDICT's English definitions, single-token English words, ASCII and control tokens; `scripts/make-output-tokens.py` makes it). Our llama.cpp patch adds `llama_model_set_output_tokens`, which copies only those rows of the output table to the GPU. The full table is shared with the input side and loads on the CPU side, so only the rows the prompt looks up are read. On the t3 set, resident memory went from 3,115 to 2,830 MB and each written token from 15.7 to 13.4 ms. The footprint rose from 544 to 684 MB, since the GPU copy of the kept rows counts there and the mapped file doesn't. Timing also moves: the kept logits are read back at once, so the wait for the prompt's last token counts as prompt time (about 11 ms more) instead of answer time. Picks read only digits and replies are English, so nothing else is needed. On the t3 set 12 of 570 translations changed, judged blind: on the test split one got better and one turned wrong (81% right either way), and dev was unchanged. Real reading was the same (P 132/136, T 49/52). `LONGYAN_TRIM=0` keeps the whole table.
- Picks aren't generated as text. The answer up to each number (`{\n  "w01": `, or `等=` on a phrase's line) is added to the prompt and the number is read from the model's probabilities for the next token. That's one pass per word instead of one per token, with identical results in about half the time: a single word takes about 0.13 s, a phrase 0.21 s. `LONGYAN_PICK=generate` generates them instead, for comparison.
- On real reading, even picks with under 50% confidence were mostly right (9 of 11), so no pick is held back for low confidence.
- A selection's translation, read in its sentence, often went on to finish the clause (卷了，我想 "…I want to lie flat"). So the English glosses of the sentence's other words, minus any the selection's own words share, are kept out while decoding (`OutsideWords.swift`). Once the selection's words are all said and the next word would be a kept-out one, the reply stops there. Only the built-in model does this. `LONGYAN_NO_BAN=1` turns it off and `LONGYAN_BAN_LOG=1` prints the kept-out words.

  On 11 held-out sentences (574 fragments from `--parts`, judged blind), it cut leaks from 172 to 144 and made 6 more replies broken (13 to 19). Real-T went from 48 to 49 of 52, at the same ~250 ms. It misses synonyms the dictionary doesn't list (回家 "home" became "go back"). Tried and dropped: translating the whole sentence and copying the selection's words out of it under a grammar. The model split the sentence's English badly and leaked more (9 of 20 fragments against 4 of 20). Prompt changes were tried earlier and didn't help either.

| Sense picker | Note test (52 held out) | Wrong notes | Main test (29) | Per lookup |
|---|---|---|---|---|
| Apple 3B + tie-break rules | 38 | 5 | 22 | ~0.55 s |
| **Qwen 3.5 4B (default)** | **51** | **1** | **25** | **~0.15 s** |
| Qwen 3.5 2B (not used) | 35 | 2 | 22 | ~0.18 s |
| Qwen 3.5 9B (not used) | 51 | 0 | 25 | ~0.62 s |

Rewording the prompt for Apple's model (meanings by name, examples in the prompt) didn't help: 33 to 38 out of 52 in every variant. The tie-break rules (matching against the translation, asking a two-option question both ways round) only run with Apple's model; with Qwen they overrode correct answers. With Apple's model, words whose meaning is settled without it skip the model call: grammar words by position, then a sense the translation agrees with, except for words that have notes.

## Anki

`Anki.swift` adds cards through [AnkiConnect](https://ankiweb.net/shared/info/2055492159), which answers on 127.0.0.1:8765 while Anki is open. The app checks for it at launch, when the eye appears and when the menu opens (at most every 10 s), and a card shows its Anki button only if the last check got an answer. The first card added creates a "Longyan Reader" note type (Chinese, Pinyin, Meaning, Sentence, Dictionary, Note) and the deck chosen under Anki Deck. A word already in that deck opens as added. To test without Anki, run `python3 scripts/fake-ankiconnect.py`. With Anki open, give it a port (`fake-ankiconnect.py 8766`) and start a `--dev` build with `open --env LONGYAN_ANKICONNECT_PORT=8766 "build/Longyan Reader.app"`; the usage simulation then checks Add to Anki too.

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

A scripted simulation drives the real cards through the same code paths as clicks and checks the results: the tint and surface before and after picking another meaning in every style and mode, early picks not being overwritten by the model, hint timers not closing the next card, picking and switching in phrase rows, live style switching, and fast repeated lookups leaving one card. It needs a `--dev` build opened with `open`, not run from a shell: started from a shell, macOS holds the shell's app responsible and the drag checks' mouse events don't arrive. Post the notification `simulate`; the report goes to `~/Library/Logs/LongyanReader/simulation.txt`, and your settings are restored afterwards.

Each lookup appends a few hundred bytes to `~/Library/Application Support/LongyanReader/History/lookups.jsonl` (in `~/Library/Logs/LongyanReader/` before 1.0; the app moves it at launch). Misses record why the selection couldn't be read.

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

1. Bump `version` in `scripts/build-app.sh` (1.0, 1.1, 1.0.1 for a fix) and commit. The build number is the commit count, so the tree has to be clean. Never rewrite main's history: a lower commit count would make the next release look older than the last.
2. Run `scripts/release.sh notes.md`, where `notes.md` is what's new (shown in the update window). It signs the app with the project's Developer ID, notarizes and staples it (`scripts/notarize.sh`, a few minutes), and stops if either step didn't work.
3. Test the update locally (below) before publishing.
4. Run the commands it prints, in order: create the release as a draft with all three files, then publish it as latest (installed copies and the website follow `releases/latest`, which skips drafts and prereleases), then `scripts/check-release.sh`, then deploy the site. A draft first means the feed never points at a release that's missing a file.
5. Check the live feed (`curl -sL https://github.com/mapuchuu/longyan-reader/releases/latest/download/appcast.xml`) shows the new build number.

A bad release can't be pulled back: Sparkle never offers an older build, so the fix is a new release with a higher build number. Deleting the release only stops new downloads.

### Testing an update before publishing

Installed copies prefer a feed URL in their defaults over the one in Info.plist, so an older release can be pointed at a feed served from this Mac:

```bash
defaults export com.mapuchuu.longyanreader /tmp/longyan-defaults.plist   # put back afterwards
cd build/release-<version> && python3 -m http.server 8743 --bind 127.0.0.1 &
# a copy of the appcast with the enclosure URL pointing at http://127.0.0.1:8743/
defaults write com.mapuchuu.longyanreader SUFeedURL http://127.0.0.1:8743/appcast.xml
defaults write com.mapuchuu.longyanreader SULastCheckTime -date "2025-01-01 00:00:00 +0000"
```

Unzip the previous release somewhere, open it, and use Check for Updates (or set `SUAutomaticallyUpdate` and quit it). Afterwards the copy should be the new version, have no quarantine flag (`xattr`), keep its designated requirement (`codesign -dr -`), and still say "Accessibility: on" in the menu. Then `defaults delete com.mapuchuu.longyanreader SUFeedURL` and import the saved defaults.

Tested from 0.1 (build 97) to 1.0 (build 128) on 2026-11-18: the update installed on quit, nothing quarantined, same requirement. A forged EdDSA signature was refused. An ad-hoc signed update with a good EdDSA signature was installed, which is why the release scripts refuse to sign ad-hoc.

Tested again from the real 0.1 to the notarized Developer ID 1.0 (build 174) on 2026-11-21: downloaded in the background, installed on quit, no quarantine, Gatekeeper accepts it as notarized. On this Mac Accessibility stayed on after the change of certificate, so no prompt appeared. That may not hold on every Mac, so the README and release notes say what to do if it asks.

The release is signed, zipped, and written to `build/release-<version>/` with `appcast.xml`. Installed copies read the feed from the latest release, so publishing the release is what ships the update. The zip is uploaded twice: once with the version in its name, which the appcast points to, and once as `LongyanReader.zip`, which the website's download button links to.

Three things are needed to make releases. The keys are kept outside the repo in `~/Library/Application Support/LongyanReader-signing/`, and need a backup:

- The Developer ID Application certificate, `developer-id.p12`, imported into `longyan-signing.keychain-db` in that folder (its password is in the login keychain under `longyan-signing`). The app's designated requirement names the team (`team_id` in `scripts/build-app.sh`), so every version is the same app as far as macOS is concerned and Accessibility stays allowed after an update. A lost certificate can be replaced by another one from the same team without users noticing; a different team can't.
- Sparkle's update key (in the login keychain, exported as `sparkle-private-key.txt`). Without it, installed copies will reject updates.
- The notary login, saved in the login keychain as the profile `longyan-notary` (`xcrun notarytool store-credentials longyan-notary --apple-id <Apple ID> --team-id <team>`, which asks for an app-specific password from account.apple.com). It can be made again at any time.

Releases up to 0.1 were signed with a self-signed certificate (`longyan-codesign.p12`, kept in the same keychain). 1.0 moved to Developer ID, so 0.1 users grant Accessibility once more after that update. Don't go back: every change of certificate costs every user the grant.

Sparkle's tools (2.10.1) are in the same folder. `release.sh` signs the feed with `sparkle-private-key.txt` when it's there, so it doesn't wait on a keychain prompt.

The binary's developer commands (`--notes-submit` and the other notes jobs) call the Anthropic API with a key from the environment or the `longyan-anthropic` keychain item. They only run from a terminal; the app itself never goes online except for the model download and update checks. (It also talks to Ollama and AnkiConnect, but only on this Mac.)

## Website

[longyan.app](https://longyan.app) is the static page in `site/`, deployed to GitHub Pages by `.github/workflows/pages.yml` on every push to `main` that changes it. The domain's DNS is on Cloudflare, set to DNS only (not proxied) so GitHub can renew the HTTPS certificate. `notes/site-design.md` has the design decisions; it lives outside `site/` so it isn't published.

The videos in `site/media/` aren't in git: they're assets of the `site-media` pre-release, and the deploy downloads them. To get them locally, run `gh release download site-media --dir site/media --pattern '*.mp4'`. To replace one, give it a new name, upload it with `gh release upload site-media <file>`, point `index.html` at it and push. Delete the old asset once the new one is live. Keep the release a pre-release, so it never becomes the "latest" release that the update feed and the download link use.

- `hero.js` draws the opening on one canvas: mountains halftoned in Chinese characters, and the Longyan eye built from its geometry (see the comment at the top), set in the `PAGE` sentences of `scripts/site-data.py`. The characters come in many sizes, whole, never cut; on the outline they may stand a hair past the edge, and a few small ones bridge the pupil's point to the wedge. Each has a fixed tint from the paper hues (azure, violet, magenta, coral). Pointing at a character shows the app's reading of it in its sentence. On scroll the eye breaks up and its characters, mostly the big ones, float into the demo sentence, which then hands over to `try.js` in one frame. The scroll is paced in `progressAt`: three quarters of a screen to form the sentence, then 0.8 of a screen held to try it, while `holdAt` plays the cue and brings in the button, in seconds. `?t=9` starts the animation nine seconds in, `?p=0.4` jumps to that point of the story, and `?og` draws the social preview (`images/og-3.jpg`, 1200×630; save a new one under a new name).
- `card.js` is the app's card for the web: the word card, the phrase card and the peek card, ported from `CardChrome.swift`, `Popup.swift` and `PhraseCard.swift` with the same sizes, dark colors, Liquid Glass, springs, row highlights, Listen, Copy, Pin, moving and resizing, and the "Part of" row a lone character's card shows. `openWord(data, anchor, inline)` with an element as `inline` builds the card into the page instead, as the statement's 躺平 card is: it stays put and isn't closed by clicks or scrolling. Keep it in step when the cards change.
- `try.js` makes the demo sentence something to try: select any run of characters, as in any Mac text; the selection stays as made and the card opens for what the app reads there, widened to whole words as the app does (⌃⌥L works too). It also builds the statement's card. The content is the app's own: `scripts/site-data.py` runs `LongyanReader --site-json` on each demo sentence, which runs the cards' state classes on every selection the sentence allows (trimmed and widened to whole words as `App.show` does) and writes what they'd show to `site/data.js`. For the hero's `PAGE` sentences it runs `--site-words`, which does the same for just their words. Rerun it after a release build when the data changes, or after changing `DEMO`.
- `paper.js` draws the backdrops (sheets of colour over a night ground, like a Mac wallpaper) with one WebGL context. `motion.js` does the scroll reveals, pins the statement and shows its three lines one at a time with a progress bar per line, stepping its card along with them (meanings, then the pick, then the note), and loads the video.
- `tiles.js` brings new words into the History tile; the other tiles' loops are CSS, run while `motion.js` marks a tile "live". `install.js` plays the install steps on the Mac screen: each scene is a CSS animation started by a class on the desk (`s0` to `s3`), laid out at 760 px (620 on a phone) and scaled to fit.
- `index.html` loads the stylesheet and scripts with a version stamp (`?v=…`). Change it when they change, so browsers and GitHub Pages' cache don't serve old copies.
- The recording is `site/media/reading-7.mp4` (HEVC, 2560×1440, 60 fps, constant quality 0.55, a keyframe every 10 s, no audio, fast start, about 9 MB) with `reading-7-h264.mp4` (H.264, the same but quality 0.5, about 10 MB) for browsers without HEVC, and `reading-7.jpg` (2239×1260, JPEG quality 0.4, progressive) as its first frame. Both come from the original 3200×1800 recording with AVFoundation; keep the full 2560 width, since the video shows up to 1280 px wide on Retina screens. To replace it, use new file names (browsers cache these) and update `index.html`; if its shape changes, match `aspect-ratio` on `.screen`.
- To preview, serve the folder (`python3 -m http.server --directory site`). `?still` turns off scroll motion for screenshots.

## Licenses

Data derived from CC-CEDICT (`Resources/cedict_ts.u8`, `Resources/sense-order.tsv`, `Resources/sense-everyday.tsv`, `Resources/extra-words.u8`, `Resources/output-tokens.txt`, and the compiled `cedict.bin`, shipped with the dictionary's license header in `Contents/Resources/Licenses/`) is CC BY-SA 4.0, as CC-CEDICT requires. llama.cpp (and our patch to it) and Sparkle are MIT; their licenses are in `Resources/licenses/` and ship with the app.
