# Windows app in other apps

What the Windows app does in the apps people read Chinese in. From `windows/CompatCheck`, run by
`.github/workflows/windows-compat.yml` (on `win/compat`, or by hand). Each app shows one line,
他得了感冒吃不了饭, and the check drags over 感冒, presses Ctrl+Alt+L on that selection,
double-clicks 感, and points at 感 with nothing selected and presses Ctrl+Alt+L. Screenshots and
the app's event log are in the run's `compat` artifact.

Runner: Windows Server 2025, 1024x768 at 100%, no reading model (cards in dictionary order).
Windows 11's Notepad: the `windows-11-arm` runner, the x64 app under emulation.

## Table

Eye: whether it came, and whether the app said what was selected ("read") or the eye copies on
a click. Beside: the eye's one-line rule, just after the selection. Card: every card that opened
went below the text, 8 px under it, as on the Mac.

| App | Drag | Shortcut on a selection | Double-click | Point + shortcut |
|---|---|---|---|---|
| Chrome | eye, read, beside | read | eye, read, beside | read |
| Edge | eye, read, beside | read at the pointer, not as a selection | no eye (see below) | read |
| Firefox | no eye the first time; then eye, read | read | eye, read, beside | read |
| VS Code | no eye | read by copying | no eye | not read: hint |
| Windows Terminal | no eye (on purpose) | read | no eye (on purpose) | not read: hint |
| LibreOffice Writer | no eye | read by copying | eye, copies on click, above the pointer | not read: hint |
| PDF in Edge | no eye | read at the pointer | eye, copies on click, above the pointer | read, but 吃, two characters off |
| SumatraPDF | no eye | read by copying | no eye | not read: hint |
| Notepad (Windows 11) | eye, read | read | eye, read | read |
| WordPad | not on the runner (Windows Server 2025 and Windows 11 24H2 dropped it) | | | |
| Word | not tested: needs an account and a licence | | | |
| WeChat, QQ | not tested: need a phone to log in before any text shows | | | |

The app's own thread never waited more than 400 ms (four runs) in any of these (the check sends it a
message every 100 ms and times the answer).

## What each needs

- Chrome: works from the first selection, with or without `--force-renderer-accessibility`
  and with or without the wake below. On the runner, nothing else had asked Chrome for its
  tree first, so this is first use.
- Edge: its own menu for a selection (copy, Copilot, search) comes up right where the eye goes,
  and on a double-click it took the focus, so the app read nothing. Placement is the eye's
  (win/eye-parity); this needs a decision there.
- Firefox: says what a drag selected only a few seconds after its first use (a drag read 2 to
  6 s later). Double-clicks read at once. Tried and dropped: asking again 250 ms after an empty
  answer (no change), and waking it like Chromium (the ask took over 1 s and changed nothing).
- VS Code: the editor's text isn't in its accessibility tree unless VS Code is in screen reader
  mode, so only copying works, and pointing can't. The Mac is the same.
- Windows Terminal: no eye, on purpose. The shortcut reads the selection through UI Automation
  (no Ctrl+C, which would stop the program). Pointing finds no text there.
- LibreOffice: no UI Automation text, so copying. The eye comes for a double-click only, as for
  any app that won't say what's selected.
- PDF in Edge: the selection isn't readable, the word under the pointer is, but its character
  positions are off (pointing at 感 read 吃).
- SumatraPDF: no UI Automation text, so copying. No eye even for a double-click: the focused
  element isn't under the pointer.
- Notepad (Windows 11): no stall in three runs (a fourth was covered by a WSL install prompt
  the ARM runner opened). A double-click there selects one character (感), so the
  card is for 感, and the eye sits beside 感.

## Fixes

- Wake (`AccessibilityWake.cs`): when a Chromium or Electron window comes to the front, the app
  asks for its document, and again 2 s later, as the Mac's `SelectionReader.prepare` does.
  `LONGYAN_WAKE=0` turns it off. On the runner it made no difference (Chrome answered at once
  either way); it's there for slower PCs and big pages.
- No eye in terminals: when the process holding the selection is Windows Terminal or a console
  host. The shortcut still works there.
- Copy fallback on its own thread, given up after 3 s. It ran on the app's thread and saved the
  clipboard as a live object; putting it back made the app that copied render each format, up
  to 30 s each if it didn't answer. That fits the 86 s stall seen in Windows 11's Notepad on
  ARM. The runner didn't stall before or after the change, so it isn't confirmed.

The Mac's fallbacks are matched: selection, then the word under the pointer, then Ctrl+C, for
the shortcut and for an eye that couldn't read.

## Needs a real PC

- The 86 s Notepad stall: the ARM PC where it was seen, to confirm it's gone.
- Chrome and Electron on a slow PC with a long page: whether the first selection reads, and
  whether the wake helps.
- VS Code: whether waking Electron's accessibility makes VS Code offer screen reader mode (the
  runner showed no prompt).
- Edge's selection menu and the eye together, by hand.
- WeChat, QQ (Electron, so likely like VS Code), Word, WPS.
- High DPI and mixed-DPI screens in these apps (all of this ran at 100%).
