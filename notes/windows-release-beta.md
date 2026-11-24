A test version of Longyan Reader for Windows, for the people trying it before the public release. If anything looks wrong, choose **Report a problem** in the menu of the Longyan Reader icon (in the notification area, by the clock).

Highlight Chinese in any app with a drag or a double-click, then click the eye that appears next to it, or press Ctrl+Alt+L. Each word shows the meaning it has in that sentence, with pinyin and the other meanings a click away. A phrase gets a translation first, then each word with its meaning there.

**What's in it**

- The Mac app's cards, dictionary, notes and reading model (Qwen 3.5 4B, a 2.7 GB download), all running on your PC.
- Point at a word with nothing selected and press Ctrl+Alt+L to look it up.
- Lookup history, with search and export.
- Add to Anki, with Anki open and the AnkiConnect add-on installed.
- Choose your own shortcut in Settings.
- Report a problem opens a GitHub issue with your Windows version, processor, memory and the end of the app's log filled in. The log never has the text you looked up, and nothing is sent until you submit the issue.
- The app asks on its second start whether to check for updates. Say yes, so the next beta reaches you.

**Known problems**

- Cards are slower than on a Mac, since the model runs on the processor: [typical word and phrase times on a test PC].
- On x64 processors without AVX2, cards list meanings in dictionary order and phrases aren't translated.
- Not every app shares its selection. Where one doesn't, the app copies the selection and puts your clipboard back.
- [Unsigned beta only:] The installer isn't signed yet, so Windows says it protected your PC. Click **More info**, then **Run anyway**.

**Which file**

- `LongyanReader-Setup-0.9.0-x64.exe` for most PCs.
- `LongyanReader-Setup-0.9.0-arm64.exe` for Snapdragon and other Windows on Arm PCs. Settings > System > About shows which you have under System type.

Needs Windows 10 or 11 (64-bit), 8 GB of memory and about 3 GB of free space.
