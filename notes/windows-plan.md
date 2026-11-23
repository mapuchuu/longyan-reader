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

At 1.66M, one-character clicks and selections match 99.7%. Evals: words, senses, notes, phrase, real-S and real-T the same; single, phrase-notes and real-P one fewer each. Some of the 12 remaining card differences are better than NLTokenizer (收 回扣, "take kickbacks", where it has 收回 扣), some worse (看病 人, 个儿 子). Every doubling of the text still helps, so 4M or more should close most of the gap. Another option is a small neural tagger, which needs PyTorch.

The trade: both apps would use the tagger, so Windows matches the Mac exactly, and the Mac moves off NLTokenizer on about 1 sentence in 80. Adopt it only once the evals match.

Lesson from the port: CEDICT has CRLF line endings, and Swift treats "\r\n" as one Character, so `split(separator: "\n")` reads nothing. Use `split(whereSeparator: \.isNewline)` for files.

### 2. Part of speech

`PartOfSpeech` asks NLTagger about the English definitions. The definitions are a fixed set, so the answers can be worked out once on the Mac and shipped as a table (the `--gloss-table` command already writes it). Both apps would read the table, so they'd always agree, and the Mac would skip a tagger call per definition.

### 3. Apple's model and Translate

Windows has neither. Qwen already picks senses and translates, so on Windows the reading model is required, as on a Mac without Apple Intelligence. Strings that name Apple ("Apple's Model Only", "Apple's model: …") need Windows wording.

### 4. Ollama

Streaming from Ollama uses `URLSession.bytes`, which only Apple's Foundation has. The code is fenced off with `#if canImport(Darwin)`. Windows uses the built-in model only. (Making Ollama dev-only on the Mac is still an open decision.)

## Still to build for Windows

- llama.cpp for the app: CI builds it CPU-only and static. Vulkan (and maybe CUDA) for speed, and DLL or static.
- Fold the Windows fence (patches/llama.cpp-windows.patch) into the output-tokens patch, which needs a Mac llama rebuild. Until then the output table's pages aren't given back on Windows.
- Run the real model on Windows: load the GGUF, pick a sense, translate, and compare with the Mac.
- Memory pressure: Windows has its own low-memory signal to call `EmbeddedModel.relieve`.
- The main actor needs a run loop that drains the main queue alongside the Windows message loop.
- Reading the selection: UI Automation (text pattern and selection bounds) instead of Accessibility. Coverage will vary by app.
- The cards and windows: a Windows UI that observes the same state classes (`withObservationTracking`).
- Updates: WinSparkle reads the same appcast format.
- Signing: a Windows code-signing certificate, or SmartScreen warns on every download.

## Checked on Windows and Linux

`.github/workflows/core.yml` builds llama.cpp (the same release and patch, CPU only), the core and `longyan-core-check` on Windows and Linux. The check prints the core's answers for a fixed set of words and sentences, plus a hash of every dictionary entry's senses and card wording, with a one-character splitter and no English tagger. Both platforms match the Mac's output (scripts/core-check-expected.txt) exactly.

Fixed on the way:

- `\p{Han}` in `String.range(of:)` means Han's script extensions on the Mac (so 達·芬奇 is one run) and the Han script elsewhere. Now `\p{scx=Han}`, which matches the same characters on the Mac.
- Saved model states use `VirtualAlloc` on Windows, where there's no `mmap`.

Not exercised yet: the model itself, the Anki connection (FoundationNetworking) and parts of speech, which need the table in section 2.
