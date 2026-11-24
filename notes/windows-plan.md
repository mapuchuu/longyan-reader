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

## Decisions for launch (2026-11-24)

- Updates install silently. WinSparkle runs the installer with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /OPEN=1`, and the app opens again after.
- Uninstalling always deletes the app's data, with no question: `%LOCALAPPDATA%\LongyanReader` (settings, history, the model, logs) and `HKCU\Software\LongyanReader` (the updater's settings). Nothing else.
- The wording is "Open at login" everywhere.
- No letter-by-letter San Francisco widths (notes/windows-parity.md, Fonts).
- Speed: priming stays on by default; `LONGYAN_PRIME=0` turns it off. The prompts and the too-slow rule stay as they are.
- Vulkan: `ggml-vulkan.dll` isn't in the app or the installer until it's been tested on a real GPU. CI keeps building it (the `vulkan` job), and the `speed` job keeps checking the CPU fallback with it.
- The x64 app on an ARM PC moves to the ARM64 build at its next update: it reads `appcast-windows-x64-on-arm64.xml`, the feed's items with the ARM64 installers (DEVELOPMENT.md, Windows updates).

## Still to build for Windows

- llama.cpp for the app: CI builds it as DLLs, with the CPU kernels once per kind of x64 CPU (ggml-cpu-*.dll, SSE 4.2 up to AVX-512); ggml loads the best one at run time, and the UI check also runs on the SSE 4.2 ones. The GPU through Vulkan (x64) and OpenCL (ARM64), behind a self-test: see GPU below. Not measured on a Windows GPU yet.
- Fold the Windows fence (patches/llama.cpp-windows.patch) into the output-tokens patch, which needs a Mac llama rebuild. Until then the output table's pages aren't given back on Windows.
- Run the real model on Windows: load the GGUF, pick a sense, translate, and compare with the Mac.
- Memory pressure: Windows has its own low-memory signal to call `EmbeddedModel.relieve`.
- Reading the selection: UI Automation (text pattern and selection bounds) instead of Accessibility. Coverage will vary by app.
- The card: still missing Add to Anki, History, pointing at a word without selecting. Listen uses a Windows Chinese voice when one is installed.
- The eye (Chip.cs) is in: Raw Input watches the mouse (no hook), UI Automation reads the selection off the app's thread with a 0.5 s limit, and ly_prepare starts the card's work 0.3 s after the eye appears (cancelled if it goes unclicked). Apps that don't say what's selected get it on a double-click only, in elements that may hold text, never in terminals, dialogs, Excel or full screen. It matches the Mac's drawing (gallery eye.png). CI checks it in Notepad. Needs a real PC: mixed-DPI screens, Chrome and Electron on first use, WeChat, touch and pen.
- Updates: WinSparkle 0.9.4, with its own feed (appcast-windows.xml on the windows-feed pre-release, and appcast-windows-x64-on-arm64.xml for the x64 app on ARM) and ed25519 signatures. The installer runs silently. Built and checked in CI (windows.yml's updates jobs, x64 and x64 on ARM64); still needs the real key (scripts/windows-update-key.sh). DEVELOPMENT.md has the details.
- Signing: a Windows code-signing certificate, or SmartScreen warns on every download.

## GPU (branch win/gpu)

On the CPU a card reads its prompt at 20 to 40 tokens a second, so a word card takes about 15 s. The Mac's GPU reads about 1500 a second.

- What ships: `gpu\ggml-vulkan.dll` in the x64 app, `gpu\ggml-opencl.dll` in the ARM64 app, in the installers too. The gpu folder is out of the folders `ggml_backend_load_all` reads, so the app never loads a GPU backend until the self-test has passed on this PC. No driver, or a broken one, can't take the app down at start.
- The self-test (windows/LongyanReader/Gpu.cs, `EmbeddedModel.gpuSelfTest`): a minute after the model is ready, the app runs `LongyanReader.exe --gpu-test <backend> <file>`, a process of its own. It loads the backend and looks for a GPU (none: done in about a second). Then one fixed word card pick (他得了感冒, three words, a 277-token prompt like a card's) on the CPU, then twice on the GPU (the first run builds the shaders). The GPU is kept only if its three numbers equal the CPU's and its second run is at least 10% faster. A crash, a hang over 6 minutes, a load that fails or a different answer all mean the CPU.
- Memory: the device's free memory (for an integrated GPU, its share of the PC's memory) is read first. With less than the model's 2.7 GB plus 768 MB, only as many layers as fit go on the GPU; under a quarter of them, no GPU. If the load still fails, half as many.
- It runs once, and again when the app or a display driver changes (the "fingerprint": the app's version, its DLLs' sizes and each display adapter's driver version from the registry). Until a new test passes, the CPU.
- The choice is "gpu" in settings.json. In the app: if the GPU fails to load, or a decode fails on it, that run goes on with the CPU and the setting is turned off. While the model is on the GPU the core keeps `%LOCALAPPDATA%\LongyanReader\gpu-in-use`; a run that ended badly with it there turns the GPU off at the next start.
- Overrides: `LONGYAN_GPU=0` keeps the CPU, `LONGYAN_GPU=1` uses the GPU without the test (`LONGYAN_GPU_BACKEND`, `LONGYAN_GPU_LAYERS`). `LongyanReader.exe --gpu-check` runs the test now and saves its choice.
- Fix on the way: llama.cpp-output-tokens.patch put the kept output rows on whatever GPU ggml had registered. With a GPU backend registered and the model on the CPU only, that aborted (seen on the Mac with Metal). llama.cpp-windows.patch now puts them on the device of the model's last layer.
- CI has no GPU. The gpu job checks the fallback with the app itself: no device (the runner has vulkan-1.dll but no Vulkan GPU, so ggml-vulkan's init returns nothing: the CPU, in under a second), a fake vulkan-1.dll that crashes in every call (the test process ends with 0xC0000005 within a second, the app keeps the CPU, keeps running and never loads ggml-vulkan.dll itself), and the crash marker. The speed job checks that `LONGYAN_GPU=1` with no device gives the CPU's cards (the same bridge cards). ui-arm64 runs `--gpu-check`: the ARM runner has OpenCL.dll but no OpenCL platform, so the CPU.
- A real GPU number, from the Mac (M5 Pro, Metal, the same test code and the same patched llama.cpp, not Windows or Vulkan): CPU 1.9 to 3.1 s, GPU 0.29 to 0.36 s, the same picks, 6.6x to 8.9x. With 16 of 33 layers on the GPU, 1.7x. Free runners have no GPU, and nothing paid was used, so there's no Windows number yet.

### ARM64 (Snapdragon)

- OpenCL is llama.cpp's backend for Adreno: its docs list the Adreno X1-85 (Snapdragon X Elite) on Windows 11 ARM64 as verified, with Q4_K and Q6_K (this model's types) supported, and it has every op Qwen 3.5 uses (gated delta net, ssm_conv, solve_tri, cumsum). So app-arm64 builds ggml-opencl.dll with clang against Khronos's headers and loader; OpenCL.dll comes with the Adreno driver and isn't shipped.
- Vulkan isn't shipped for ARM64: in llama.cpp's Snapdragon X discussion (ggml-org/llama.cpp #8336) Qualcomm's Windows Vulkan driver crashed in a Vulkan call, and another build gave unusable output. ggml-vulkan's own code turns on fast matrix paths for Adreno only with Qualcomm's newest extensions. Worth trying behind the same test later.
- Unknown until a Snapdragon PC runs it: whether OpenCL beats 8 to 12 fast CPU cores for Q4_K (on phones it was sometimes slower than the CPU). The self-test decides either way.

### What a beta tester checks

1. Use the app until a card has picked a meaning, then wait a minute (or run `LongyanReader.exe --gpu-check` from the app's folder, `%LOCALAPPDATA%\Programs\Longyan Reader`).
2. Open `%LOCALAPPDATA%\LongyanReader\logs\longyan.log` and find the lines that start with `gpu`:
   - `gpu test: {...}` has the device, `freeMB`, `layers` of `layerCount`, `cpuMs`, `gpuFirstMs`, `gpuMs`, `cpuPicks` and `gpuPicks`, and `why`.
   - `gpu: GPU (vulkan, <device>, 33 of 33 layers, 400 ms against 3000 ms on the CPU)` means it's on. `gpu: CPU (...)` says why not.
   - After the next start, `gpu at start: GPU (...)`, then `gpu: loaded on the GPU: <device>, 33 of 33 layers` at the first card.
3. Expected, as a guess from the Mac's 6.6x to 8.9x (not measured on Windows): on a discrete GPU the test pick 5x to 10x faster than the CPU, and a word card in 2 to 3 s instead of about 15. On an integrated Intel or AMD GPU, less, perhaps 2x to 4x. If `gpuPicks` differs from `cpuPicks`, or it says the GPU is no faster, the CPU is right for that PC; send the line anyway.
4. Report a problem includes "runs on the GPU (...)" or "runs on the CPU (...)". `logs\gpu-test-vulkan.txt` (or `-opencl`) has llama.cpp's timing lines from the test; attach it.

## Installer (branch win/installer)

- Inno Setup, `windows/installer/LongyanReader.iss`. Chosen over WiX: one script, per-user installs without admin are its normal case, it closes and reopens the running app, and it builds on the CI runners as they are. An MSI adds nothing for a free app installed by people, not IT.
- Per user, no admin prompt: `%LOCALAPPDATA%\Programs\Longyan Reader`, a Start menu shortcut, an entry in Settings > Apps. Pages: Ready, the progress bar, then Finish with "Open Longyan Reader" ticked.
- Open at login stays the app's own setting: the welcome window's switch, on by default, writes the same Run value Task Manager lists. The installer doesn't ask too. The uninstaller removes the value when it points at the app it removes.
- Upgrades: the installer sets the event `LongyanReader.Windows.Quit` and the app exits as from its menu (App.cs). After 10 s, Restart Manager closes it. A silent upgrade opens it again if it was open, or always with `/OPEN=1`, which updates pass. The whole app folder is replaced, so files an older version had don't stay.
- Uninstall deletes the app's data without asking: `%LOCALAPPDATA%\LongyanReader` (history, settings, the model, logs) and `HKCU\Software\LongyanReader`. Only those two. The installer check seeds both, with a folder and a key of a longer name beside them, and checks that the two go and the others stay.
- The model isn't in the installer. The app downloads it on first run from the welcome window (the same file, hosts and checksum as the Mac, resumed from the `.part` file and its `.pieces` list).
- The version is `<Version>` in `LongyanReader.csproj`; the installer reads it from the exe.
- `windows-installer.yml` (called from windows.yml) builds `LongyanReader-Setup-<version>-x64.exe`, `-arm64` or one for both, `-x64-arm64`, then installs, upgrades over the running app, updates the way WinSparkle does (the app closed, then `/OPEN=1`) and uninstalls on a clean runner (`windows/installer/test.ps1`).
- Signing: `windows/installer/sign.ps1` signs the app's files, the setup and the uninstaller when the `WINDOWS_CERT_PFX` secret exists, and does nothing until then.
- A tag `windows-v<version>` makes a draft release, never marked latest.

## Windows on Arm (branch win/arm64)

An x64 build runs on a Snapdragon PC under emulation, where ggml only gets the SSE 4.2 kernels: on a Parallels ARM VM a word card never settled in 2.5 minutes. So there is a native ARM64 build: `windows.yml`'s `app-arm64` and `ui-arm64` jobs on GitHub's windows-11-arm runner, and `core.yml`'s `windows-arm64`. llama.cpp is built with clang (MSVC can't build kernels for other CPUs than its own), as DLLs with four CPU kernels, ggml-cpu-armv8.0_1 up to armv8.6_1 with dotprod, fp16 and i8mm; ggml has no such list for Windows, so `patches/llama.cpp-windows-arm64.patch` adds it. The Swift toolchain has an ARM64 Windows build, and WPF publishes for win-arm64. The core check and the bridge check match the Mac's. On the runner (Cobalt 100, 4 cores, armv8.6_1 kernels) a word card settles in about 20 s and a phrase in 40 s, about twice the x64 runner's time. The x64 build on the same runner, under emulation (which gave it AVX2 there, so haswell kernels), took 68 s and 136 s; llama-simple writes 11.7 tokens a second there, 7.8 on the plain armv8.0 kernels. A Snapdragon X has 8 to 12 faster cores. The UI check on that runner (Windows 11, not Server) failed the same checks for the x64 build; that was the runner's desktop: classic Notepad's "new version available" bar left room for two lines and a half, so Ctrl+End scrolled and clicks hit the line below, and a "wsl.exe --update" prompt opened every 30 s and took the focus (now blocked in the workflow). Both ARM jobs now fail the workflow like the x64 one. Of 45 word picks over the gallery's passages, ARM64 and x64 agree on 43 (研 and 這個 differ). For a release: two downloads (x64 and ARM64) or one installer that picks, and the x64 build should tell someone running it under emulation to get the ARM64 one (the "needs-arm64" status).

## First run (branch win/firstrun)

- The welcome window opens as soon as the app starts, before the dictionary loads (that took up to 12 s with nothing on screen). Its model button waits for the core's answer, so a PC too slow for the model isn't sent 2.7 GB.
- It says the Mac's onboarding where it applies, with no Accessibility step: the eye, the shortcut as it is on this PC (with why, when an AltGr layout moved it to Win+Ctrl+Y, and a Choose a shortcut button when another app has it), pointing, and where the tray icon is. Mica on Windows 11 22H2 and later; it redraws when light or dark changes.
- Closing it shows a notification: the app is in the notification area, and the shortcut.
- The download is the Mac's: 32 MB pieces over 8 connections, a piece under 50 KB/s for 20 s asked for again, three failures and the next host, the .pieces ledger, only replies with the right byte range written, disk space checked first, waiting while Windows says it's offline. The system proxy is used. The card's wording follows the Mac's: Stop, Resume, "Download failed: …" with Try again, "Not enough disk space. The download needs …".
- Before the model, cards come at once in dictionary order; after the download the next card opens at once and the pick fills in. Both from the core, as on the Mac.
- `windows.yml`'s first-run job runs `UiCheck --first-run` on a clean profile with no model cache and films it (film.mp4 in the first-run artifact). `--render-windows` draws every welcome state.

## Checked on Windows and Linux

`.github/workflows/core.yml` builds llama.cpp (the same release and patch, CPU only), the core and `longyan-core-check` on Windows and Linux. The check prints the core's answers for a fixed set of words and sentences, plus a hash of every dictionary entry's senses and card wording, with a one-character splitter and no English tagger. Both platforms match the Mac's output (scripts/core-check-expected.txt) exactly.

Fixed on the way:

- `\p{Han}` in `String.range(of:)` means Han's script extensions on the Mac (so 達·芬奇 is one run) and the Han script elsewhere. Now `\p{scx=Han}`, which matches the same characters on the Mac.
- Saved model states use `VirtualAlloc` on Windows, where there's no `mmap`.

Not exercised yet: the model itself, the Anki connection (FoundationNetworking) and parts of speech, which need the table in section 2.

## Windows 10 (branch win/win10)

Supported from Windows 10 1809 (build 17763); the installer refuses older builds. .NET 8 itself needs 1607. No Windows 10 runner or VM exists, so this comes from reading the code and the shipped DLLs' imports, plus CI checks on Windows 11.

What differs, all decided by the build number in `WindowsBuild.cs`:

- Welcome window: a solid background, no Mica (Mica needs 22H2). It already fell back this way.
- Title bars: Windows 10's own, white or dark. No caption colour (Windows 11 only). Dark title bars use attribute 19 on 1809 to 1909 and 20 from 2004; before, 1809 to 1909 kept a white title bar in dark mode.
- Corners: square, as Windows 10 draws every window. The app never asked for rounded ones.
- Fonts: Segoe UI instead of Segoe UI Variable, Segoe MDL2 Assets instead of Segoe Fluent Icons. Every icon the app uses has the same code point in MDL2. The card is drawn by the app and keeps its size: gallery.yml draws it both ways and compares.
- Nothing else changes. The imports of every shipped DLL (llama.cpp, ggml's CPU kernels, the Swift runtime, WinSparkle) were checked: all exist on 1809. IsWow64Process2 is 1511 and later, the high-resolution timer 1803 and later (it falls back to Task.Delay), per-monitor DPI v2 1703 and later.
- Windows 10 on ARM: it can't run x64 apps, only ARM64 ones. The x64 installer refuses there (Inno Setup's x64compatible), the ARM64 and combined installers install the ARM64 build.

Checks: `windows/Win10Check` (windows.yml's app job) tests the build gates for each Windows 10 and 11 release, that each icon glyph is in Segoe MDL2 Assets, and the installer's MinVersion. `LONGYAN_WINDOWS_BUILD=19045` makes the app act as on that build (dev and CI only); gallery.yml draws the gallery that way into `windows10/` and compares sizes with the normal drawing.

A Windows 10 beta tester should check:

- The installer runs, and the app opens from the Start menu and at login.
- The welcome and settings windows: every icon shows (no empty boxes), text isn't cut off, light and dark both look right, and the title bar turns dark with dark mode, also when the mode changes while the window is open.
- History: the search, menu and check icons show.
- A card from Notepad, Edge and Chrome, with the shortcut and the eye: same as on Windows 11, including the fade and spring.
- The notification after closing the welcome window, and the tray icon (it starts in the overflow, behind the arrow).
- The model download and a card with the model.
- On 1809 to 1909: dark mode title bars. On a Snapdragon PC with Windows 10: the ARM64 installer.
