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

The segmenter starts from Apple's NLTokenizer and then applies dictionary rules. NLTokenizer is closed and only on Apple's systems. Windows has its own word breaker, but it splits differently, and every difference changes which words a card shows.

So the two apps can only match if both use the same splitter. The way to get there is our own splitter in LongyanCore, used on both platforms, measured against NLTokenizer with `scripts/parity.py` and the evals. The Mac would switch only if the evals don't drop. Until then, Windows can't match the Mac exactly.

A first try (2026-11-23, not on the branch): the dictionary's words, cheaper the higher they rank in `notes/frequency.txt`, cut along the cheapest path. Single characters cost 2.2, dictionary words outside the list 5. Against NLTokenizer:

- the same split on 897 of 938 sentences (95.6%), 98.3% of one-character clicks, 98.5% of selections
- its misses are what context fixes: 开 除了, 全 家人, 石 头上, 说明 天
- evals: words 28/29 (27 now), senses 27/29 (24), phrase 81/95 (83), single 86/90 (85), phrase-notes, notes and real reading the same

So a splitter of our own is about as good, and a better one is within reach. NLTokenizer can be its teacher: any Chinese text split on a Mac is training data, so a small model trained to copy it could agree on nearly everything, and then run the same on both platforms.

### 2. Part of speech

`PartOfSpeech` asks NLTagger about the English definitions. The definitions are a fixed set, so the answers can be worked out once on the Mac and shipped as a table (the `--gloss-table` command already writes it). Both apps would read the table, so they'd always agree, and the Mac would skip a tagger call per definition.

### 3. Apple's model and Translate

Windows has neither. Qwen already picks senses and translates, so on Windows the reading model is required, as on a Mac without Apple Intelligence. Strings that name Apple ("Apple's Model Only", "Apple's model: …") need Windows wording.

### 4. Ollama

Streaming from Ollama uses `URLSession.bytes`, which only Apple's Foundation has. The code is fenced off with `#if canImport(Darwin)`. Windows uses the built-in model only. (Making Ollama dev-only on the Mac is still an open decision.)

## Still to build for Windows

- llama.cpp for Windows (CPU and Vulkan, maybe CUDA) with our output-tokens patch, and `Package.swift` choosing it there instead of the xcframework. Sparkle and the Mac targets need to be Mac-only in the package.
- Memory pressure: Windows has its own low-memory signal to call `EmbeddedModel.relieve`.
- The main actor needs a run loop that drains the main queue alongside the Windows message loop.
- Reading the selection: UI Automation (text pattern and selection bounds) instead of Accessibility. Coverage will vary by app.
- The cards and windows: a Windows UI that observes the same state classes (`withObservationTracking`).
- Updates: WinSparkle reads the same appcast format.
- Signing: a Windows code-signing certificate, or SmartScreen warns on every download.

## Not checked yet

There is no Windows or Linux Swift toolchain on this Mac, so the core hasn't been compiled for Windows. The Apple-only APIs found by reading it are fenced off. A GitHub Actions job on a Windows runner is the next check, once pushing is OK.
