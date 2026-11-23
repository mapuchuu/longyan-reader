# Windows card parity

How the Windows card (windows/LongyanReader) matches the Mac card (Sources/LongyanReader).
Mac refs use the short names of notes/card-spec.md: PU = Popup.swift, CC = CardChrome.swift,
PC = PhraseCard.swift, APP = App.swift. Windows refs: CW = CardWindow.cs, CV = CardView.cs,
MO = Motion.cs, UC = windows/UiCheck. Line numbers are as of branch win/card-feel.

Status: **same** (checked in code, and in CI where it says), **fixed** (was different, changed
on win/card-feel), **differs** (left different, with why).

## Motion and behaviour

Evidence from CI: the `windows` workflow's ui-check artifact. Its films (`1-word-reveal`,
`1-pick`, `2-open`, `2-shut`, ...) are screen grabs at about 30 a second on a GPU-less runner,
which draws a layered window about every 40 to 80 ms, so they show curves and end points, not
smoothness. The `6-feel` check (UC CardFeelCheck.cs) asserts placement, focus, Esc, click away
and live dark mode on every push.

### The numbers, side by side

| Step | Mac | Windows |
|---|---|---|
| Hold for the pick | 0.4 s from the lookup (APP:756) | 0.4 s from the lookup (CW Update), Normal-priority timer |
| Reveal: window fade | 0 to 1, 0.14 s, linear (PU:442) | 0 to 1, 0.14 s, linear (CW Reveal) |
| Reveal: card | scale 0.96 to 1, y −4 (below) / +4 (above) to 0, spring 0.32 / 0.82, anchor top or bottom (PU:446, CC:382) | same values, MO Reveal over 0.45 s (left over at the end: 0.07%) |
| Swap in place (pinned, Part of) | fade 0.12 s, no spring (PU:435) | fade 0.12 s, no spring |
| Every change inside (cardMotion) | spring 0.34 / 1.0; Reduce Motion easeInOut 0.15 s (CC:191) | same, MO Card over 0.5 s (left over: 0.1%); Reduce Motion Bézier (0.42, 0, 0.58, 1) 0.15 s |
| Card height | cardMotion, not on the first frame (CC:365) | same |
| Row open: detail | opacity + y from −6 × zoom, cardMotion; leaves the same way (PC:126) | same (CV Keyed, FadeOut) |
| Note box | opacity + y from −4 × zoom (PU:27) | same |
| Parts leaving, text crossfades | opacity on cardMotion | same (was ease-out 0.3 s, **fixed**) |
| Chevrons | Show All 0° to 180°, phrase row 0° to 90°, cardMotion | same |
| Pick: checkmark | opacity 0 to 1, scale 0.6 to 1, cardMotion (CC:720) | same |
| Dismiss | fade to 0, 0.12 s, linear; no motion (PU:727) | same |
| Pin: close badge | opacity 0 to 1, scale 0.7 to 1, spring 0.25 / 0.9 (CC:1006) | same, over 0.35 s |
| Pin and Copy symbols | SF Symbols replace transition | grow 0.5 to 1 on cardMotion, fade in 0.2 s ease-out (**fixed**, was instant) |
| Copy checkmark | 1.5 s (CC:893) | 1.5 s |
| Resize, pinch / Ctrl+wheel | no animation while the hand moves (CC:36, CC:365) | no animation |
| Zoom step | × 1.1 (CC:120) | × 1.1 a wheel notch |
| Row hover | 0.05, ease-out 0.08 s on, 0.2 s off (CC:688) | same values |
| Row pressed | 0.09, ease-out 0.08 s (CC:689) | same |
| Button hover | 0.07, ease-out 0.15 s; symbol to primary (CC:963) | same |
| Symbols when the card is hovered | tertiary to secondary, ease-out 0.2 s (CC:964) | same |
| Button pressed | opacity 0.55, ease-out 0.08 s (CC:974) | same |
| Grip, edge grabber | ease-out 0.15 s (CC:503) | same |
| Scroll-edge fades | ease-out 0.2 s, 36 × zoom bottom, 14 × zoom under the buttons (CC:439-454) | same |
| The ease-out curve itself | Core Animation easeOut, Bézier (0, 0, 0.58, 1): 38%, 69%, 91% at a quarter, half, three quarters | **fixed**: was WPF CubicEase (58%, 88%, 98%); now the same Bézier |
| Drag threshold | 4 pt (PU:232) | 4 × scale px |
| Gap to the selection | 8 pt (PU:620) | 8 × scale px (6-feel: 8 px at 100%) |
| Focus | never taken (PU:208) | never taken (6-feel) |

### Placement

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Anchor: the selection's rect; with none, a 40 × 20 box on the pointer | APP:656-659 | CW ctor (`anchor = selection ?? ...`) | same | |
| Left edge on the selection's left edge | PU:625 | CW ChoosePlacement, Place | same | 6-feel asserts within 2 px |
| 8 pt gap, card top fixed below (bottom fixed above) | PU:620-628 | CW ChoosePlacement (`Gap * s`), Place | same | 6-feel asserts 8 × scale within 3 px; 1-word.png and 2-open/00.png |
| Below if `below ≥ max(content, 320)` or `below ≥ above`, else above; decided at first measure | PU:508-514, PU:398-401 | CW ChoosePlacement | same | |
| Pinned card, or one opened in place: always hangs from its top-left | PU:510 | CW HangFrom | same | |
| Max height `max(120, min(room, 0.8 × screen))`, room to the screen edge minus 16 | PU:516-522 | CW MaxHeight | same | |
| Kept 8 inside the work area on all sides | PU:629-630 | CW Place | same | |
| Screen: most of the anchor, else the pointer's | PU:576-585 | CW Screen (Screen.FromRectangle: most overlap, else nearest) | same | |
| Per-monitor DPI: placed in device pixels with that monitor's scale; moving to another scale keeps the card by its edge | (points) | CW DpiFor, OnDpiChanged | same | |
| Content grows down when below, up when above; window grows at once, shrinks after the motion | PU:591-612 | CW Resize, SetFrame (window holds up to 160 spare, gives it back 0.6 s after shrinking) | same | 2-open: top fixed at 123 while the bottom moves 455 to 531 |
| A card placed above hangs from its top from the first press on it | PU:493-504 | CW PressStart | same | |

### Opening

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Word card with the model ready holds up to 0.4 s for the pick | APP:756, PU:371-375 | CW Update | **fixed**: held 0.4 s from the first content on a Background-priority timer, which ran late (CI: the eye's card waited 1413 ms, events.jsonl). Now 0.4 s from the lookup, on a Normal timer | 6-feel logs `opened` and fails over 1 s |
| Pick in time: applied with no motion, card shows at once | APP:787-794, PU:413-422 | CW Update (`animate: false`, Arrive) | same | |
| Late pick animates in | APP:787 | CW Update (`animate: true`) | same | 1-pick film |
| Window fade 0 to 1 over 0.14 s, linear | PU:442-445 | CW Reveal | same | 1-word-reveal: dark band 0.11, 0.45, 1.0 over three drawn frames |
| Card scale 0.96 to 1 and y ∓4 to 0, spring response 0.32, damping 0.82, anchored top (below) or bottom (above) | PU:446, CC:382-383 | CW Reveal, MO Reveal (same spring formula, run 0.45 s) | same | |
| Height doesn't animate on the first frame | CC:364-365 | CW Arrive (`Resize(animated: false)`) | same | |
| Replacing a card in place (pinned, Part of): fade 0.12 s over the old one, no spring, old one goes after | PU:429-441 | CW Reveal, TakeOver, DropSwap | **fixed**: a pinned card opening at its corner with no card there also skipped the spring; now only a real swap does | |
| Reduce Motion: fade only | CC:381-383 | CW Reveal (`Motion.Reduced`: Windows "Animation effects" off) | same | |
| VoiceOver: announce "word, pinyin, meaning" | PU:450-457 | CW Announce (UIA notification for Narrator) | **fixed** (was missing) | |
| First card after launch costs no first-window setup | (n/a) | CW Warm, at ApplicationIdle after Ready | same | |

### Inside the card

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| cardMotion: spring response 0.34, damping 1 (Reduce Motion: easeInOut 0.15) | CC:191-197 | MO Card, ContentEase | same | 2-open bottom: 12%, 32%, 59%, 79%, 89%, 95%, 97% at 16, 65, 114, 161, 209, 257, 306 ms after a start at 130 ms: the critically damped spring with ω = 18.5 to a frame |
| Spring maths: SwiftUI mass 1, stiffness (2π/response)², damping 4πζ/response, from rest | | MO Spring | same | |
| Spring interrupted mid-way keeps its velocity | SwiftUI retargets | WPF restarts from the current value at rest | differs: only seen when a row is toggled twice within 0.3 s; a velocity-keeping spring needs a custom animation clock | |
| Card height animates with cardMotion; window resized instantly around it | CC:365, PU:591-612 | CW Resize | same | 2-open |
| Rows around inserted or removed parts slide; new parts fade (note box from y −4, phrase detail from y −6); text changes crossfade | PU:27, PC:126, PU:56, PU:82, PC:112 | CV Slide, Keyed, FadeOut | **fixed**: leaving parts faded on ease-out 0.3 s and didn't slide back up; now cardMotion and the slide | 2-open, 2-shut films |
| Show All chevron 0° to 180°, phrase row chevron 0° to 90°, cardMotion | PU:184, PC:118 | CV Rotate | same | |
| Choice mark: opacity 0 to 1, scale 0.6 to 1, cardMotion | CC:720-721 | CV Choice | same | 1-pick |
| "Reading the sentence…" spinner | PU:127 (ProgressView mini) | CV Spinner: 8 spokes stepping every 0.1 s | same in kind | |
| Scroll-edge fades: bottom 36 × s, top under the buttons + 14 × s; ease-out 0.2 s | CC:439-455 | CW Fades | same | 2-zoomed.png |
| No scroll bar | CC:423-427 | CW scroller (Hidden) | same | |
| Wheel scrolling | NSScrollView | CW Wheel, Glide: 40 × zoom a notch, eased (about 0.2 s), touchpad deltas in proportion | differs by platform: Windows apps glide a notch; there's no rubber-band overscroll on Windows | 2-scroll film |
| Ctrl+wheel changes text size by 1.1 a notch (pinch on the Mac) | CC:104-122 | CW Wheel, SetZoom | same in effect | 2-zoomed.png |

### Pointer feedback

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Row highlight: hover 0.05 on in 0.08 s, off in 0.2 s; pressed 0.09 in 0.08 s; radius 6 | CC:682-689 | CV RowButton | same (curve **fixed**, see the ease-out row above) | 1-hover.png |
| A row rebuilt under the pointer is hovered at once | (SwiftUI keeps hover) | CV JustBuilt | same | 1-picked.png |
| Action buttons: highlight 0.07 in 0.15 s; symbols tertiary, secondary while on the card (0.2 s), primary on the button; pressed 0.55 in 0.08 s | CC:953-976 | CV ActionButton, Recolor | same | |
| Copy: checkmark in the accent for 1.5 s, symbol replace transition | CC:886-895, CC:854 | CV CopyButton, Symbol.Pop | **fixed**: the symbol swapped in one frame; now grows and fades in with cardMotion | |
| Pin: pin.fill in the accent, replace transition | CC:868-875 | CV AddButtons, Symbol.Pop | **fixed** as Copy | |
| Listen: accent while speaking, a click stops | CC:847-853 | CV ListenButton | same, except the Mac's waves light in turn while speaking (variableColor); the Windows speaker is one path | differs (small): needs the symbol split into parts, look agent's icon |
| Grip and edge grabber fade in 0.15 s while on the card; darker while resizing | CC:499-520 | CW Hover, Bands | same | 1-hover.png |
| Close badge: spring 0.25 / 0.9, opacity and scale 0.7 to 1, pressed 0.55 | CC:980-1009 | CW Badge, Hover | same | |
| Cursors: arrow everywhere, resize cursors on bands, held through the drag | CC:637-656 | CW Bands (Cursor per band, mouse captured) | same | |

### Moving and resizing

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Drag anywhere but the bands; becomes a move after 4 pt; the pressed control doesn't click | PU:221-255 | CW PressStart/PressMove/PressEnd, `WasDrag` | same | 1-moved.png |
| Hints don't move | PU:637 | CW PressStart | **fixed** (hints moved) | |
| Moving shifts the anchor; scroll-away no longer closes | PU:657-680 | CW PressEnd (`moved`, `dragged`) | same | |
| Edges set width (240 to 1000, inside the screen), corners scale zoom and width; double-click resets | PU:530-570, CC:144-149 | CW Band | same | |
| Text size, widths, pin and the pinned corner kept across launches | CC:13-15, CC:48, CC:173-189 (UserDefaults) | CW SaveCard, Settings.CardNumber | **fixed**: were lost on restart; now in settings.json | |

### Closing and focus

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Click (left or right) in another app closes, unless pinned | PU:377-384 | CW Hooks (WH_MOUSE_LL), Outside | same | 6-feel asserts |
| Scroll in another app closes, unless pinned or the card was moved or resized | PU:383, PU:657-659 | CW Outside (`dragged`) | same | |
| Esc in another app closes, unless pinned | PU:385-388 | CW Hooks (WH_KEYBOARD_LL), Outside | same | 1-close, 6-feel assert |
| Clicks and Esc in the app's own windows (the eye, History, Settings, tray menu) leave the card | global monitors see other apps only; PU:389-393 | CW Hooks.Tell (window under the click, or in front, by process) | **fixed**: these closed the card | |
| Typing, switching apps, the shortcut again: typing and switching leave it; the shortcut opens a new card in its place | PU:311-319 | CW Present | same | |
| Close: window fade to 0 over 0.12 s, no motion; speech stops | PU:717-734 | CW Dismiss, FadeOut, Retire | same | 1-close film |
| Hints close themselves after 1.8 s | APP:888-897 | CW ShowHint | same | |
| Never takes the focus; first click lands on the control | PU:208-210, PU:258-261 | CW WS_EX_NOACTIVATE, ShowActivated false | same | 6-feel asserts Notepad keeps the focus on open and after a click on a row |
| One card at a time; a hint beside a pinned card opens in its own window | PU:311-319, APP:890 | CW Present, Hint | same | |

### Appearance

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| An open card switches light/dark at once, without closing | CC:262-270, PU:709-712 | CW WatchTheme, ThemeChanged, Retheme (SystemEvents.UserPreferenceChanged) | **fixed**: the open card stayed light (real Windows 11 VM, vm-dark.png) | 6-feel flips dark and back with a card open and checks the surface |
| The eye in the new theme | Chip.swift | Theme.Dark is now live, so the next eye has it; an eye already up (6 s at most) keeps its colours | same for new eyes | eye: Chip.cs, another agent's |
| Reduce Motion | system setting | Windows "Animation effects" | same | |

### First eye click after launch (Windows 11 VM)

The card side: a card shows only after its first content and, for a word card, its hold. The
hold was a `DispatcherTimer` at its default Background priority, which runs only when nothing
of higher priority is queued: each frame's rendering and all input are higher. In CI the eye's
card waited 1413 ms instead of 400 (events.jsonl: content at 64442, revealed at 65957), while
the eye's own leave animation was drawing. On a VM drawing slowly, the first card's first frames
(fonts, first layout) can keep it starved until the next input, which also replaces the card:
"the first click did nothing". The hold now runs on a Normal-priority timer and counts from the
lookup, so the card opens 0.4 s after the click at most, plus drawing. If the first click still
does nothing on the VM, the next place to look is the eye (Chip.cs): whether its first
`MouseLeftButtonUp` reaches `Chip.Click` (the `eye-click` event in the log says).

## Eye

The small button beside a fresh selection (branch win/eye-parity). Mac: Sources/LongyanReader/Chip.swift (CS below).
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

Checked in the user's VM afterwards, read-only (the app's own Bounds code run on Notepad's
ranges at 200%, against the ink in a PrintWindow capture): 感冒, 他得了感冒 and 吃不了饭 on the
first line were 16 to 17.5 px above the text's centre and are now 0 to 1.5 px from it; 明朝 and
闭关锁国 on the second line stay 1.5 to 2 px (their boxes had no margin).

The Mac centres on the line's box too, but its boxes hold no margin: in TextKit the box's
centre is within 0.4 pt of a CJK line's ink centre (Helvetica 12, system 13, PingFang 14).
On Windows the box's centre is up to 2 px above the ink (classic Notepad draws CJK low in a
Consolas line), so UiCheck allows 2 px.

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
