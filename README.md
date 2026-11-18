# Longyan Reader

A Chinese reading helper for the Mac. Highlight Chinese text in any app and Longyan Reader shows what each word means in that sentence, instead of every meaning the dictionary has.

It lives in the menu bar and runs entirely on your Mac. No account, no API key, no subscription.

Download it from **[longyan.app](https://longyan.app)** or the [latest release](https://github.com/mapuchuu/longyan-reader/releases/latest).

<p align="center">
  <img src="site/images/phrase-light.png" width="325" alt="Phrase card for 最近工作太卷了，我想躺平, with a translation and each word's meaning">
</p>

## Features

- Works in most apps: Safari, Chrome, Preview, Notes, Pages, Electron apps and others.
- Picks the dictionary meaning that fits the sentence. 躺平 in 最近工作太卷了，我想躺平 is "to opt out of the rat race", not "to lie stretched out".
- Translates phrases and sentences, slang included (内卷, 躺平, 摸鱼).
- Short notes on words where the English gloss misses something, like 关系 or 面子.
- Pinyin with tone colors, and a button to hear the word.
- Keeps a history of what you looked up, with the meaning each word had. Export it to Anki or a spreadsheet.

## Requirements

- macOS 15 Sequoia or later
- A Mac with Apple silicon (M1 or later)
- 3 GB of free disk space for the reading model (optional, but recommended)

## Install

1. Download the zip, unzip it, and drag **Longyan Reader** to your Applications folder.
2. Open it. macOS will say it can't verify the app. Click **Done**.
3. Open System Settings > Privacy & Security, scroll down, and click **Open Anyway** next to Longyan Reader.
4. When the app asks, turn on Longyan Reader under Privacy & Security > Accessibility. It needs this to read the text you highlight.

The warning in step 2 is because the app isn't signed with a paid Apple Developer ID. You only have to do this once; updates install without it.

## Usage

Highlight some Chinese text. A small eye appears next to it: click it, or press **⌃⌥L**. With nothing highlighted, ⌃⌥L looks up the word under the pointer.

A single word opens a word card with its meaning in context, pinyin and any notes. Anything longer opens a phrase card: a translation, then every word with its meaning. Click a word to see its other meanings or pick a different one.

Press Escape to close a card. Drag its bottom-right corner to make the text bigger or smaller. Your history is under the menu bar icon (⌘Y).

## The reading model

Picking meanings and translating is done by a small language model (Qwen 3.5 4B, Apache 2.0) that runs on your Mac. It's a 2.7 GB download, offered when you first open the app and afterwards under **Download Reading Model** in the menu. It's unloaded after five minutes without a lookup.

Without it you still get the dictionary, pinyin and notes, but meanings are listed in dictionary order and there are no translations. On macOS 26, Apple's built-in model fills in, less accurately.

If you already have `qwen3.5:4b` in [Ollama](https://ollama.com), the app uses that and you don't need to download anything.

## Privacy

Everything runs on your Mac. What you look up is never sent anywhere.

The app only goes online to download the reading model when you ask for it, and to check for updates. Your history is kept in `~/Library/Logs/LongyanReader/` and stays there unless you export it. You can turn it off or clear it from the menu.

## Updates

The app checks GitHub for new versions (it asks before doing this automatically), or choose **Check for Updates…** in the menu.

## Uninstall

Quit the app, then move these to the Trash:

- **Longyan Reader** in Applications
- `~/Library/Application Support/LongyanReader` (the reading model)
- `~/Library/Logs/LongyanReader` (your history)

Then remove it from System Settings > Privacy & Security > Accessibility, and from Login Items.

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

The code is MIT licensed. The dictionary is [CC-CEDICT](https://cc-cedict.org/), © MDBG and contributors, under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/); the app's dictionary files are derived from it and use the same license. The app also includes [llama.cpp](https://github.com/ggml-org/llama.cpp) and [Sparkle](https://sparkle-project.org), both MIT. The Qwen model is downloaded separately and is Apache 2.0.

Meanings and translations come from a language model and can be wrong. The notes were written by Claude and checked against the dictionary.
