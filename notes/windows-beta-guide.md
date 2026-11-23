# Longyan Reader for Windows: beta guide

Thanks for trying it. This takes about 20 minutes, and every report helps, even "it worked".

## Install

1. Download the installer from the link we sent: `-x64.exe` for most PCs, `-arm64.exe` for Snapdragon and other Windows on Arm PCs. Settings > System > About shows which you have under System type.
2. Open it. It installs for your account only, with no administrator prompt.
   [Unsigned beta only: Windows says it protected your PC. Click **More info**, then **Run anyway**. If your browser says the file isn't commonly downloaded, choose **Keep**.]
3. In the welcome window, download the reading model (2.7 GB). It runs on your PC; nothing you read is sent anywhere.

## What to try

Use it on what you'd normally read in Chinese. Along the way, please try:

1. Select a word in a web page (Edge or Chrome) and click the eye that appears. Then the same with Ctrl+Alt+L.
2. Select a whole sentence. The translation should come first, then each word.
3. Point at a word without selecting anything and press Ctrl+Alt+L.
4. The same in Word, a PDF reader, WeChat or any other app you use. Tell us which apps work and which don't.
5. Click a word on a phrase card to open it, and pick a different meaning.
6. Pin a card, move it, resize it, and zoom the text with Ctrl and the mouse wheel.
7. Open Lookup history from the icon's menu, search it, and export it.
8. If you use Anki with AnkiConnect, add a word from a card.
9. Switch Windows between light and dark with a card open.
10. If you have two monitors, or a keyboard layout with AltGr (Polish, German, French), use it there too.
11. Restart the PC and check the app comes back by itself.
12. On the second start the app asks about updates. Say yes; we'll send at least one update during the beta.

Notice how long cards take. Tell us if they feel too slow, and on which PC.

## Reporting a problem

Right-click the Longyan Reader icon by the clock and choose **Report a problem**. It opens a GitHub issue in your browser with your Windows version, processor, memory, the model's state and the end of the app's log already filled in. Add:

- what happened, and what you expected;
- the app the text was in;
- for a wrong meaning, the sentence and the word. Most wrong meanings can only be fixed with the sentence;
- a screenshot if the card looks wrong (Win+Shift+S).

Nothing is sent until you submit the issue, and you can read and edit all of it first. The log holds timings and errors, never the text you looked up. The full log is in `%LOCALAPPDATA%\LongyanReader\logs` if we ask for it.

If the app closes by itself, it offers to report it the next time it starts. If you don't have a GitHub account, send the same details by [how testers reach you].

## Removing it

Settings > Apps > Installed apps > Longyan Reader > Uninstall. It removes your history, settings and the reading model too. Export your history first if you want to keep it.
