Longyan Reader is now on Windows. Highlight Chinese in any app with a drag or a double-click, then click the eye that appears next to it, or press Ctrl+Alt+L. Each word shows the meaning it has in that sentence, with pinyin and the other meanings a click away. A phrase gets a translation first, then each word with its meaning there.

It works like the Mac app, with the same CC-CEDICT dictionary, usage notes and Qwen 3.5 4B reading model, running on your PC. Nothing you look up leaves it. There's no account and nothing to pay for.

**What it does**

- Meanings picked for the sentence, with pinyin colored by tone and the dictionary's other meanings underneath.
- Phrases translated, then every word in them with its meaning there.
- Point at a word with nothing selected and press Ctrl+Alt+L.
- Lookup history, with search and export to Anki or a spreadsheet.
- Add to Anki straight from the card, with Anki open and the AnkiConnect add-on installed.
- Listen, with a Chinese voice installed in Windows.
- Light and dark, following Windows. Cards can be moved, pinned and resized; Ctrl and the mouse wheel change the text size.
- Choose your own shortcut in Settings.
- Updates: the app asks whether to check for them, then checks once a day. The Microsoft Store version is updated by the Store.
- Report a problem in the icon's menu opens a GitHub issue with your PC's details filled in. Nothing is sent until you submit it.

**Good to know**

- Cards take longer than on a Mac. The model uses the graphics chip when it passes a quick test, and the processor otherwise.
- On x64 it needs a processor with AVX2 and FMA. Without it, cards list meanings in dictionary order and phrases aren't translated.
- Tone colors are fixed for now.
- The installer isn't signed, so Windows shows "Windows protected your PC". Click **More info**, then **Run anyway**. If Smart App Control blocks it, use the [Microsoft Store version](https://apps.microsoft.com/detail/9MSR9JKZKR50).

**Which file**

- `LongyanReader-Setup-1.0.0-x64.exe` for most PCs.
- `LongyanReader-Setup-1.0.0-arm64.exe` for Snapdragon and other Windows on Arm PCs. Settings > System > About shows which you have under System type.

Needs Windows 10 or 11 (64-bit), 8 GB of memory and about 4 GB of free space, mostly for the reading model. Looking for the Mac app? It's on the [latest release](https://github.com/mapuchuu/longyan-reader/releases/latest).
