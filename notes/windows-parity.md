# Windows parity with the Mac

What the Windows app does differently from the Mac app, part by part. Each row names the Mac
code it follows, the Windows code, whether they now match, and how that was checked. "Same"
means checked, not only read; "platform" means a deliberate Windows convention.

## Eye

The small button beside a fresh selection. Mac: Sources/LongyanReader/Chip.swift (CS below).
Windows: windows/LongyanReader/Chip.cs (C), InputWatch.cs (IW), SelectionReader.cs (SR),
Motion.cs (M). CI evidence is the `ui-check` artifact of the `windows` workflow: UiCheck's
eye checks (windows/UiCheck/EyeCheck.cs) log a `[name]` line per placement with the
selection, the text's ink rows, the eye's window and the Mac rule's centre, and save
`eye-sheet-<scaling>.png` (each case cropped, the Mac rule's circle in red, the text's centre
in green).

### Why it sat above the line (fixed)

Notepad on Windows 11 is a RichEditD2DPT box. Its UI Automation box for the first line holds
the page's top margin: at 200% (Parallels with Retina), the first line of the user's file
reads 393 to 464 (71 px) while the second reads 464 to 503 (39 px). The text's ink on the
first line is at rows 432 to 459, centre 445.5; the box's centre is 428.5. The eye was centred
on the box, 17 px (8.5 points) above the text, and its spring and shadow made it look higher
still. Read in the user's VM with a UI Automation probe and PrintWindow, no clicks. Windows
Server's classic Notepad (CI) has no margin in its boxes, and the old check compared the eye
with the box, not the text, so CI never saw it. Now SR.Bounds cuts a top line that is a
quarter taller than the next line (or 1.6 times its font) to a line's height from the bottom,
and UiCheck compares the eye with the text's ink.

### Placement

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Which rect | AXBoundsForRange of the whole selection, untrimmed (CS:59-66) | union of the range's GetBoundingRectangles, top-line margin cut (SR.Bounds) | same | eye-sheet-*: first line in Notepad and rich edit |
| One line or not | bounds height > 0 and < 40 pt (CS:93) | > 0 and < 40 × scale at the pointer (C.Place) | same | `two lines` beside, `three lines` by the pointer |
| Beside: horizontal | button box left = maxX + 4 (CS:95); circle starts 7 after | window left = right + 4s − 7s (C.Place) | same | UiCheck x within 1 + s/2 px |
| Beside: vertical | box centred on bounds midY (CS:95) | window centre on midY of the cut bounds | same | UiCheck y within 1 + s px of the ink centre |
| Otherwise | box bottom-left 6 right of, 6 above the mouse-up point (CS:92) | same in device pixels (C.Place) | same | `three lines` cases |
| Right-to-left drag | rect rule; mouse point only for the fallback | same | same | `rtl` cases |
| Far from the pointer | bounds more than 160 pt from mouse-up are dropped (CS:64) | same, 160 × scale (C.Consider) | same | code |
| Empty or zero rect | dropped (SelectionReader.checked, width and height ≥ 1) | same (C.Consider) | same | code |
| Screen edges | clamped to the visible frame of the screen with the pointer (CS:101-105) | clamped to that screen's working area (C.Place) | same | `edge` case at 100% |
| Box | 44 window, 30 button, 24 circle (CS:79-81, 208) | same (C:184) | same | gallery eye.png |
| Scalings | points | device pixels × monitor DPI (per-monitor v2) | same | eye-sheet-100/125/150 (and 175/200 where the runner offers them) |

### When it appears

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Trigger | left mouse-up after a drag > 4 pt (Euclidean) or a double-click (CS:51-52) | same; was SM_CXDRAG per axis (IW) | same | 3-eye, 3-eye-drag |
| Delay | 0.12 s, then read (CS:54) | 0.12 s, then UI Automation within 0.5 s (C.Consider) | same | code |
| Selection kept | trimmed non-empty, has Chinese, ≤ 400 (CS:62) | has Chinese, ≤ 400 trimmed (C.Consider) | same | 3-eye |
| Unreadable apps | eye with copy on click, unless the focus isn't text (CS:67-71) | double-click only, not terminals, dialogs, Excel, full screen | platform | notes/windows-plan.md |
| Hidden apps, off switch | hiddenApps, showChip (CS:48-49) | Settings.EyeHiddenIn, ShowEye | same | 4-settings |
| Card work early | onShow on appear (CS:90) | 0.3 s after appearing, or on hover; cancelled if unclicked | platform (battery) | windows-plan.md |
| Model warm-up | LocalModel.warmUp (CS:89) | ly_warm_up (C.Show) | same | code |

### Look and motion

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Drawing | surface, 0.5 hairline at 10%, 13 pt mark (CS:233-256) | same (C.Build) | same | gallery eye.png vs mac/eye.png: inside the circle mean 1.8, dark 0.9 of 255 |
| Shadow | black 18%, radius 5, y 2 (CS:213) | DropShadow blur 16, opacity 0.24, depth 2; was 10 and 0.18 | same | rendered both at 2x over white: RMS 0.6 of 255 (was a far shorter tail) |
| Appear | alpha 0 to 1 in 0.12 s linear; scale 0.6 to 1, spring 0.3 / 0.68 (CS:120-123, 228) | same (C.Place, M.EyeAppear) | same | 3-eye-in frames |
| Hover | 1.08, spring 0.25 / 0.7; mark secondary to primary in the same spring (CS:225, 236) | same; the mark's fade was 0.15 s ease-out | same | 3-eye-hover |
| Press | 0.92, spring 0.2 / 0.7 (CS:226) | same (M.EyePress) | same | code |
| Spring maths | SwiftUI: mass 1, stiffness (2π/response)², damping ratio as given | M.Spring, run until under 0.1% of the move | same | M:74-96 |
| Hide | alpha to 0 in 0.1 s on any hide, click included (CS:166-175) | 0.1 s; a click was 0.08 | same | 3-eye-reveal frames |
| Reduce Motion | not checked by the eye | Windows' animation effects off skips the springs | platform | |

### Leaving and clicking

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Hides on | left or right mouse-down elsewhere, key, scroll (CS:34-43) | same; the middle button no longer hides it | same | 3-eye middle click, key, wheel |
| Auto-hide | 6 s after appearing, pointer on it or not; the menu stops it (CS:126-128, 142) | same; was held while hovered | same | 3-eye-again |
| Click | DragGesture(minimumDistance 0): pressed on down, action on up (CS:217-219) | press on down with capture, action on up (C:229-238) | same | 3-eye-card |
| First click | acceptsFirstMouse (CS:181) | the window never activates, so every click reaches it | same | 0-first-eye and 6-first-eye-again |
| Focus | non-activating panel | WS_EX_NOACTIVATE | same | 3-eye: Notepad keeps the focus |
| Menu | right-click or Control-click: NSMenu at the pointer: hide in this app, turn off, a disabled line about the shortcut (CS:141-155) | right-click: the system's popup menu at the pointer, same items; was a WPF ContextMenu under the button | same (Windows menu look) | 3-eye-menu.png |
| Tooltip | "Look up (⌃⌥L). Right-click to hide the eye." (CS:220) | "Look up (Ctrl+Alt+L). Right-click to hide the eye." | same | code |
| Screen readers | a "Look up" button with a press action (CS:221-224) | a "Look up" button with Invoke (C.EyeButton) | same | UiCheck finds it by class |
