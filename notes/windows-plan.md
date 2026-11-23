# Windows plan

Goal: a Windows app that is a faithful copy of the Mac one. Same model, same logic, same cards.

## Step 1: shared logic (branch shared-core)

Done. Everything that decides what a card says is in `Sources/LongyanCore`, plain Swift and Foundation. The Mac app gives it four system services through `Platform`: a Chinese word splitter, an English tagger, a fallback sense picker and a translator.

How it was checked, against the 1.1 release build:

- `scripts/parity.py`: 216,000 lines of output (segmentation, every one-character click, every 2 to 5 character selection, every word's senses, every dictionary definition's card wording and part of speech). Identical.
- `scripts/evals.sh`: every eval's full output identical, timings within noise.
- 74 renders of word, phrase, onboarding, tone and chip views, light and dark, with and without Anki: pixel identical.
- The usage simulation: the same 123 checks pass as on main. The same 11 drag checks fail on both, from this Mac's state.

## What decides faithfulness

### 1. The word splitter (the big one)

The segmenter starts from Apple's NLTokenizer and then applies dictionary rules. NLTokenizer is closed and only on Apple's systems, so the two apps can only match if both use a splitter of our own.

What was ruled out (2026-11-23):

- ICU, which Windows ships: the same split as NLTokenizer on 16% of 3,504 sentences, 77% of words. CFStringTokenizer matches NLTokenizer 100%, so it's Apple's engine, not ICU.
- A table of word costs: NLTokenizer uses the sentence around a phrase. 155 of 3,524 phrases split differently when cut out of their sentence (我等 一下 in a sentence, 我 等 一下 alone).
- Shipping Apple's tokenizer or its data: not ours to ship.
- Qwen splitting the text: far too slow for a click, and the model is optional.

What works: a character tagger trained on NLTokenizer's splits of text the app's Qwen wrote (`~/workspace/longyan-ft/splitter`). It's an averaged perceptron: each character gets begin, middle, end or single, from the characters around it and the CEDICT words that start or end there. No neural network.

- Size: 1.4 to 2 MB of integer weights, gzipped. Speed: 54 µs a sentence in Swift. Loading: 0.37 s, once.
- Integer sums, so it gives the same answer on every platform. The Swift decoder matches the Python one on all 216,000 parity lines.
- Against NLTokenizer on held-out sentences, by amount of training text:

| training text | sentences split exactly alike | words alike | cards alike (parity `segment`) |
|---|---|---|---|
| 0.26M characters | 79.3% | 95.2% | 96.7% |
| 0.57M | 81.9% | 95.9% | 98.1% |
| 0.98M | 84.3% | 96.4% | |
| 1.66M | 87.2% | 97.1% | 98.7% |
| 4.69M | 90.2% | 97.9% | 99.3% |

At 1.66M, one-character clicks and selections match 99.7%. Evals: words, senses, notes, phrase, real-S and real-T the same; single, phrase-notes and real-P one fewer each. Some of the 12 remaining card differences are better than NLTokenizer (收 回扣, "take kickbacks", where it has 收回 扣), some worse (看病 人, 个儿 子). Every doubling of the text still helps, so 4M or more should close most of the gap. Another option is a small neural tagger, which needs PyTorch.

At 4.69M (all of gen-corpus and gen-words), cards match on 99.3% of parity sentences. Dropping weights under 3.0 keeps 99.0% at 3.0 MB, and with that file every eval set scores the same as NLTokenizer, real-P included. That is the file in `Resources/splitter.tsv` now (it was the 6.8 MB, 1.66M one). It fixes 看 病人 and 一共 有 in the bridge check.

The trade: both apps would use the tagger, so Windows matches the Mac exactly, and the Mac moves off NLTokenizer on about 1 sentence in 80. Adopt it only once the evals match.

Lesson from the port: CEDICT has CRLF line endings, and Swift treats "\r\n" as one Character, so `split(separator: "\n")` reads nothing. Use `split(whereSeparator: \.isNewline)` for files.

### 2. Part of speech

`PartOfSpeech` asks NLTagger about the English definitions. The definitions are a fixed set, so the answers can be worked out once on the Mac and shipped as a table (the `--gloss-table` command already writes it). Both apps would read the table, so they'd always agree, and the Mac would skip a tagger call per definition.

### 3. Apple's model and Translate

Windows has neither. Qwen already picks senses and translates, so on Windows the reading model is required, as on a Mac without Apple Intelligence. Strings that name Apple ("Apple's Model Only", "Apple's model: …") need Windows wording.

### 4. Ollama

Streaming from Ollama uses `URLSession.bytes`, which only Apple's Foundation has. The code is fenced off with `#if canImport(Darwin)`. Windows uses the built-in model only. (Making Ollama dev-only on the Mac is still an open decision.)

## Decisions (2026-11-23)

- The Mac keeps Apple's splitter. Windows uses the trained one. The two apps stay close but don't have to split every sentence alike.
- One repo. Windows has its own releases (own tags, not marked latest, so the Mac's `releases/latest/download` link keeps working). The download count adds both.
- The Windows app is C# with WPF, calling the core through a C interface.

## Step 2: the bridge and a first Windows app

- `Sources/LongyanBridge`: the core as a DLL with a C interface. The app starts it, asks for a card for a selection, and gets the card back as JSON each time it changes (the model's pick arriving, the translation streaming, a meaning picked). Entry points hop to the main actor; the app runs Swift's main queue from its own message loop (`_dispatch_main_queue_callback_4CF`), so the core runs on the app's main thread.
- Windows reads `Resources/splitter.tsv` (the trained splitter) and `Resources/parts-of-speech.tsv` (the Mac tagger's answers where the core without a tagger would differ, from `scripts/parts-of-speech.sh`).
- `scripts/bridge-check.sh` runs 27 lookups through the C interface on the Mac with no model. `.github/workflows/windows.yml` runs the same from C# on Windows and compares the cards.
- `windows/LongyanReader`: a notification-area icon, Ctrl+Alt+L, the selection from UI Automation (else Ctrl+C and the clipboard put back), the card in a window that never takes the focus, the model download (same file and checksum as the Mac's). The workflow uploads the app folder as an artifact, to try in a VM.

## Step 3: the card, matched to the Mac's

- `notes/card-spec.md` is the Mac card written down: sizes, colours, spacing, motion and behaviour, with the SwiftUI lines each comes from.
- `windows/LongyanReader/CardView.cs` lays the card out from the core's JSON. `CardWindow.cs` holds it: shadow margin, placement by the selection, the open and close fades, height changes, moving, resizing, zoom (Ctrl and the wheel), pinning, and closing on a click, scroll or Esc elsewhere (low-level hooks, since the card never has the focus).
- Fonts differ (Segoe UI Variable, Microsoft YaHei UI). To match the Mac's look anyway: lines are 1.2 of the size as in San Francisco, YaHei is set at 0.92 of the size so its characters are as tall as PingFang's, and YaHei Bold stands in for PingFang Medium. SF Symbols are drawn as paths.
- Motion follows the Mac's springs: changes on cardMotion (response 0.34, no bounce), the reveal on a 0.32/0.82 spring. Parts that stay slide to their new place when others come or go.
- `gallery.yml` draws the cards in `windows/gallery` (light and dark) to put beside the Mac's drawings of the same cards (`windows/gallery/mac`, from `scripts/card-gallery.sh`). Card heights are within 1 to 3 pt of the Mac's.
- The UI check in `windows.yml` also films the reveal, a pick, a row opening and Esc, and tries hover and drag.
- Parts that leave fade out where they were, and changed text crossfades (the old element itself fades, since snapshots cost 30 ms a click). Rows rebuilt under the pointer keep their highlight.
- The window keeps 160 spare height past the card. Resizing a transparent WPF window redraws its whole surface (40 to 57 ms on CI), so the card grows inside the spare room and the window gives it back after the motion. Click to drawn is now 13 to 19 ms on CI; the app logs the breakdown and WPF's frame times for the UI check.

## Decisions for launch (2026-11-23)

- Signed: a Windows code-signing certificate before the public release.
- A private beta first. A Windows VM we can reach, for testing beyond CI.
- Shortcut: Ctrl+Alt+L, unless it types a character on the keyboard layout (AltGr layouts such as Polish), then another default; anyone can pick their own.
- The card stays like the Mac; the tray, menus, installer and welcome window follow Windows conventions.
- A normal release that isn't marked latest (it counts in the download total).
- 1.0 includes History, Anki and pointing at a word without selecting.

## Still to build for Windows

- llama.cpp for the app: CI builds it CPU-only as DLLs, with the CPU kernels once per kind of x64 CPU (ggml-cpu-*.dll, SSE 4.2 up to AVX-512); ggml loads the best one at run time, and the UI check also runs on the SSE 4.2 ones. Vulkan (and maybe CUDA) for speed.
- Fold the Windows fence (patches/llama.cpp-windows.patch) into the output-tokens patch, which needs a Mac llama rebuild. Until then the output table's pages aren't given back on Windows.
- Run the real model on Windows: load the GGUF, pick a sense, translate, and compare with the Mac.
- Memory pressure: Windows has its own low-memory signal to call `EmbeddedModel.relieve`.
- Reading the selection: UI Automation (text pattern and selection bounds) instead of Accessibility. Coverage will vary by app.
- The card: still missing Add to Anki, History, pointing at a word without selecting. Listen uses a Windows Chinese voice when one is installed.
- The eye (Chip.cs) is in: Raw Input watches the mouse (no hook), UI Automation reads the selection off the app's thread with a 0.5 s limit, and ly_prepare starts the card's work 0.3 s after the eye appears (cancelled if it goes unclicked). Apps that don't say what's selected get it on a double-click only, in elements that may hold text, never in terminals, dialogs, Excel or full screen. It matches the Mac's drawing (gallery eye.png). CI checks it in Notepad. Needs a real PC: mixed-DPI screens, Chrome and Electron on first use, WeChat, touch and pen.
- Updates: WinSparkle reads the same appcast format.
- Signing: a Windows code-signing certificate, or SmartScreen warns on every download.

## Windows on Arm (branch win/arm64)

An x64 build runs on a Snapdragon PC under emulation, where ggml only gets the SSE 4.2 kernels: on a Parallels ARM VM a word card never settled in 2.5 minutes. So there is a native ARM64 build: `windows.yml`'s `app-arm64` and `ui-arm64` jobs on GitHub's windows-11-arm runner, and `core.yml`'s `windows-arm64`. llama.cpp is built with clang (MSVC can't build kernels for other CPUs than its own), as DLLs with four CPU kernels, ggml-cpu-armv8.0_1 up to armv8.6_1 with dotprod, fp16 and i8mm; ggml has no such list for Windows, so `patches/llama.cpp-windows-arm64.patch` adds it. The Swift toolchain has an ARM64 Windows build, and WPF publishes for win-arm64. The core check and the bridge check match the Mac's. On the runner (Cobalt 100, 4 cores, armv8.6_1 kernels) a word card settles in about 20 s and a phrase in 40 s, about twice the x64 runner's time; llama-simple writes 11.7 tokens a second there, 7.8 on the plain armv8.0 kernels. A Snapdragon X has 8 to 12 faster cores. Of 45 word picks over the gallery's passages, ARM64 and x64 agree on 43 (研 and 這個 differ). For a release: two downloads (x64 and ARM64) or one installer that picks, and the x64 build should tell someone running it under emulation to get the ARM64 one (the "needs-arm64" status).

## Checked on Windows and Linux

`.github/workflows/core.yml` builds llama.cpp (the same release and patch, CPU only), the core and `longyan-core-check` on Windows and Linux. The check prints the core's answers for a fixed set of words and sentences, plus a hash of every dictionary entry's senses and card wording, with a one-character splitter and no English tagger. Both platforms match the Mac's output (scripts/core-check-expected.txt) exactly.

Fixed on the way:

- `\p{Han}` in `String.range(of:)` means Han's script extensions on the Mac (so 達·芬奇 is one run) and the Han script elsewhere. Now `\p{scx=Han}`, which matches the same characters on the Mac.
- Saved model states use `VirtualAlloc` on Windows, where there's no `mmap`.

Not exercised yet: the model itself, the Anki connection (FoundationNetworking) and parts of speech, which need the table in section 2.
