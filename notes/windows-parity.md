# Windows card parity

How the Windows card (windows/LongyanReader) matches the Mac card (Sources/LongyanReader).
Mac refs use the short names of notes/card-spec.md: PU = Popup.swift, CC = CardChrome.swift,
PC = PhraseCard.swift, APP = App.swift. Windows refs: CW = CardWindow.cs, CV = CardView.cs,
MO = Motion.cs, UC = windows/UiCheck. Line numbers are as of branch win/card-feel.

Status: **same** (checked in code, and in CI where it says), **fixed** (was different, changed
on win/card-feel or win/springs), **differs** (left different, with why). Mac films below were made
on macOS 26.6 with small SwiftUI and AppKit test apps (screencapture, frames read with AVFoundation).

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
| Reveal: window fade | 0 to 1, 0.14 s, AppKit's default curve, Bézier (0.25, 0.1, 0.25, 1) (PU:442; traced, not linear) | same curve (CW Reveal, MO Fade); **fixed**: it was linear, and a trace showed the Mac's half way at 33 ms against Windows' 72. Before that: the fade and the spring now start on the window's first drawn frame (ContentRendered). They started at Show(), and a new layered window takes tens of ms to reach the screen, so a VM film saw the spring 97% done at 131 ms (the spring itself is 82% at 131 ms, 98% at 200 ms) |
| Reveal: card | scale 0.96 to 1, y −4 (below) / +4 (above) to 0, spring 0.32 / 0.82, anchor top or bottom (PU:446, CC:382) | same values, on the spring driver (MO Spring), run until it settles |
| Swap in place (pinned, Part of) | fade 0.12 s, no spring (PU:435) | fade 0.12 s, no spring |
| Every change inside (cardMotion) | spring 0.34 / 1.0; Reduce Motion easeInOut 0.15 s (CC:191) | same, MO Spring with MO Card until it settles; Reduce Motion Bézier (0.42, 0, 0.58, 1) 0.15 s |
| A spring given a new target mid-way | carries on from where it is at the speed it is going (filmed: a bar sent to 180 then to 178 after 60 ms runs on smoothly; a restart would stall) | same (**fixed**: WPF animations restarted from rest) |
| Card height | cardMotion, not on the first frame (CC:365) | same |
| Row open: detail | opacity + y from −6 × zoom, cardMotion; leaves the same way (PC:126) | same (CV Keyed, FadeOut) |
| Note box | opacity + y from −4 × zoom (PU:27) | same |
| Parts leaving, text crossfades | opacity on cardMotion | same (was ease-out 0.3 s, **fixed**) |
| Chevrons | Show All 0° to 180°, phrase row 0° to 90°, cardMotion | same |
| Pick: checkmark | opacity 0 to 1, scale 0.6 to 1, cardMotion (CC:720) | same |
| Dismiss | fade to 0, 0.12 s, AppKit's default curve; no motion (PU:727) | same, on MO Fade from the next frame; **fixed**: it was linear. Before that: a VM film saw it reach about 60% and then vanish at 96 ms. Now the fade runs on the frame clock (MO Linear) over the full 0.12 s, and the window closes on the frame after the one that drew 0. UC 3-fade checks every frame against the curve |
| Pin: close badge | opacity 0 to 1, scale 0.7 to 1, spring 0.25 / 0.9 (CC:1006) | same, on the spring driver |
| Copy, Anki symbols | replace.downUp, filmed: the old symbol shrinks to 0.5 in 0.23 s (speeding up), the new one starts at 0.52 and is full size at 0.46 s (slowing down); no fade | the same curve, from the film (**fixed**: was a grow from 0.5 on cardMotion with a fade) |
| Pin symbol | replace.downUp with bounce.down, filmed: old one to 0.51 in 0.22 s, new one in at 0.76, up to 1.10 at 0.4 s, back to 1 at 0.62 s | the same curve (**fixed**: had no bounce) |
| Listen while speaking | variableColor.iterative, filmed: steps of 1/3 s; both waves dim to 0.29, inner lights, outer lights as inner dims, outer dims, a step dim; round 4/3 s; each change 0.31 s on a gentle S curve (Bézier 0.3, 0, 0.7, 1 fits to 1%); on stop the round finishes, then both waves are back at once | the same (**fixed**: the waves didn't move) |
| Copy checkmark | 1.5 s (CC:893) | 1.5 s (**fixed**: the timer was Background priority and ran late on a busy machine, so the checkmark stayed and then vanished with no animation; now Normal) |
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
| Window fade 0 to 1 over 0.14 s, Bézier (0.25, 0.1, 0.25, 1) | PU:442-445 | CW Reveal | same | 1-word-reveal: dark band 0.11, 0.45, 1.0 over three drawn frames |
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
| Spring interrupted mid-way keeps its velocity | SwiftUI retargets (filmed, MotionCheck/mac-retarget.tsv) | MO Spring: a driver of our own on CompositionTarget.Rendering, Spring.cs for the maths; a part rebuilt in a new element carries on by key (slides, chevrons, check marks) | **fixed** | windows/MotionCheck (CI): Spring.cs within 1e-6 of SwiftUI's ODE for a row toggled 50, 100, 150 ms apart, and within 1.5 pt of the Mac film; UC 2-twice: the app's drawn heights against the closed form |
| Card height animates with cardMotion; window resized instantly around it | CC:365, PU:591-612 | CW Resize | same | 2-open |
| Rows around inserted or removed parts slide; new parts fade (note box from y −4, phrase detail from y −6); text changes crossfade | PU:27, PC:126, PU:56, PU:82, PC:112 | CV Slide, Keyed, FadeOut | **fixed**: leaving parts faded on ease-out 0.3 s and didn't slide back up; now cardMotion and the slide | 2-open, 2-shut films |
| Show All chevron 0° to 180°, phrase row chevron 0° to 90°, cardMotion | PU:184, PC:118 | CV Rotate | same | |
| Choice mark: opacity 0 to 1, scale 0.6 to 1, cardMotion | CC:720-721 | CV Choice | same | 1-pick |
| "Reading the sentence…" spinner | PU:127 (ProgressView mini) | CV Spinner: 8 spokes stepping every 0.1 s | same in kind | |
| Scroll-edge fades: bottom 36 × s, top under the buttons + 14 × s; ease-out 0.2 s | CC:439-455 | CW Fades | same | 2-zoomed.png |
| No scroll bar | CC:423-427 | CW scroller (Hidden) | same | |
| Touchpad scrolling | 1:1 with momentum; at an end it stretches (measured in a test app: a 20th of the push, pushing back takes it in 1:1) and springs back e^(−12.5 t) (235 to 57 in 0.11 s); only when the content scrolls (.basedOnSize) | CW Pan: deltas that aren't whole notches move 1:1 (Windows sends the momentum), the same stretch and spring back, after 0.1 s with no deltas | **fixed** (no stretch before); Windows has no "fingers up", so the stretch lets go 0.1 s after the last delta | UC 2-band |
| Mouse wheel | a notch jumps a line with no glide and never bounces (test app) | CW Glide: 40 × zoom a notch, eased about 0.2 s, no bounce | differs on purpose: Windows apps glide a notch | 2-scroll film |
| Ctrl+wheel changes text size by 1.1 a notch (pinch on the Mac) | CC:104-122 | CW Wheel, SetZoom | same in effect | 2-zoomed.png |

### Pointer feedback

| Behaviour | Mac | Windows | Status | Evidence |
|---|---|---|---|---|
| Row highlight: hover 0.05 on in 0.08 s, off in 0.2 s; pressed 0.09 in 0.08 s; radius 6 | CC:682-689 | CV RowButton | same (curve **fixed**, see the ease-out row above) | 1-hover.png |
| A row rebuilt under the pointer is hovered at once | (SwiftUI keeps hover) | CV JustBuilt | same | 1-picked.png |
| Action buttons: highlight 0.07 in 0.15 s; symbols tertiary, secondary while on the card (0.2 s), primary on the button; pressed 0.55 in 0.08 s | CC:953-976 | CV ActionButton, Recolor | same | |
| Copy: checkmark in the accent for 1.5 s, symbol replace transition | CC:886-895, CC:854 | CV CopyButton, Symbol.Swap | **fixed**: the replace.downUp curve as filmed (see the numbers) | UC 1-copy, 1-copy-back |
| Pin: pin.fill in the accent, replace transition and bounce | CC:868-875 | CV AddButtons, Symbol.Replaced | **fixed**: with the bounce as filmed | UC 1-pin, 1-unpin |
| Listen: accent while speaking, a click stops | CC:847-853 | CV ListenButton, WaveClock | **fixed**: the waves light in turn as filmed (Icons.cs speaker in three parts); the tint changes at once, as the Mac's (it eased 0.15 s) | UC 1-listen (a silent stand-in voice) |
| A card opening under a pointer at rest | not hovered until the pointer moves (no mouseEntered till then) | CW PointerHook: the card takes no hover until a real move or press | **fixed**: WPF hovered it at once, showing the edge grabber (taken for a scroll bar) and a row highlight | |
| Tooltips (.help) | not shown: AppKit shows tooltips only in the active app, and the card never activates its app | CW ToolTipOpening handled for card windows; the help stays as each button's UI Automation name | **fixed**: Windows showed them (e.g. "(concept of) time" on a meaning) | |
| Grip and edge grabber fade in 0.15 s while on the card; darker while resizing | CC:499-520 | CW Hover, Bands | same | 1-hover.png |
| Close badge: spring 0.25 / 0.9, opacity and scale 0.7 to 1, pressed 0.55 | CC:980-1009 | CW Badge, SpringBadge | same; a quick in and out now keeps its speed | |
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
| Close: window fade to 0 over 0.12 s, no motion; speech stops | PU:717-734 | CW Dismiss, FadeOut, Retire, MO Linear | **fixed**: closed before the fade ended; now 0 is drawn first | 1-close film, UC 3-fade |
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

## Look

Every visual element and state of the Mac card, what the Windows card draws, and whether they
match. The Mac's numbers are in notes/card-spec.md; this table points at the code on each side
and at the picture that shows the result.

How to check:
- `scripts/card-gallery.sh` draws the cases in windows/gallery/cases.tsv on the Mac (in sRGB,
  as the screen shows them) and writes each card's JSON. The gallery workflow draws the same
  JSON on Windows. Both are at 2x.
- Compare: side by side and an overlay (Mac red, Windows cyan; where they agree it's black).
- Allowed difference: the font (San Francisco and PingFang on the Mac, Segoe UI Variable and
  Microsoft YaHei UI on Windows). Its size, weight, line height and width are matched.

Status: **same** (no difference past 1 px at 2x, other than the font), **font only** (the
difference is the font's own shapes), **open** (not done, see the note).

Mac files: PU = Popup.swift, CC = CardChrome.swift, PC = PhraseCard.swift, NV = NoteViews.swift,
TC = ToneColors.swift. Windows files: CV = CardView.cs, CW = CardWindow.cs, TH = Theme.cs,
IC = Icons.cs; line numbers as of win/card-look. Evidence paths are under the gallery workflow's artifact (win) and
windows/gallery/mac (mac); composites are made with the scratch tools described at the end.

### Card

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
| Width | PU:614, CardLayout | word 360, phrase 390 | CW `WidthFor` | same | every case: same pixel width |
| Padding | CC:341 | 16 sides and top, 12 bottom | CV:55 `Pad`, `PadBottom` | same | word-ganmao: dh 0 |
| Corner | CC:341 | radius 16, continuous | CW:193 | same | corners within 1 px (cmp word-ganmao) |
| Hairline | CC:489 | primary 0.10, 0.5 pt inside | CW:192, TH `Hairline` | same | edge pixel 233 Mac, 233 Windows (light); 50 and 50 (dark) |
| Surface | CC:273 | white; #1F1F21 dark | TH `Surface` | same | 255 and 31,31,33 on both (word-mianzi) |
| Shadow | CC:525-545 | 0.16 r16 y8, 0.08 r1.5 y0.5 | CW:212 `Shadow` | same | shadow.png: darkening within 0.013 from 0.5 to 27 pt out (table in report) |
| Content clip | CC:493 | clipped to the shape | CW `overlay.Clip` | same | code |
| Resize grip | CC:556-575 | 3 strokes, primary 0.22, 0.45 hovered | CW:184 | same | code (shown on hover only) |
| Edge grabber | CC:509-519 | 3 wide, ≤ 22, primary 0.2/0.4 | CW:43, 195 | same | code (shown on hover only) |
| Close badge (pinned) | CC:980-1000 | 20 circle, xmark, primary 0.12 ring, shadow 0.12 r2 y1 | CW:842 `Badge` | same | code; Xmark in symbols sheet |
| Scroll fades | CW `Fades` | fade under the buttons and at the bottom | CW `Fades` | open | needs a tall scrolled card on both sides; not in the gallery |

### Word card

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
| Headword | PU:44-49 | 34 medium, tone colours | CV:160 `Header` | font only | word-*: band dy 0 to -1 |
| Pinyin beside it | PU:50-53 | 15, tone colours, 8 after the word | CV:166-168 | font only | word-ganmao, word-mianzi |
| Pinyin under a long word | PU:61-73 | 2 below, buttons stay on the first line | CV:179-193 | same | word-bgsg (3 buttons), word-long: dh 0 |
| Fit rule | PU:54-60 | one line if word + pinyin + 8 + 8 + slot fits | CV:173 | same | word-bgsg wraps like the Mac with 3 and 4 buttons |
| Meaning | PU:76-90 | 19 semibold, 2 to "Meaning in this sentence" | CV:115-131 | font only | word-*: band dy 0 |
| Meaning in this sentence | PU:84 | 11 secondary | CV:126 | font only | word-reading |
| Part of row | PU:92-110 | 12; Part of, word 13 medium, pinyin, meaning, chevron | CV:198 `PartOf` | font only | word-partof: dy 0, chevron gap 15 px on both |
| Back to | PU:113-123 | uturn symbol, 12 accent | CV:432 `Back` | same | word-picked: icon gap fixed (was 4.5 pt short) |
| Reading the sentence | PU:125-128 | spinner, 8, 12 secondary | CV:483 `Busy` | same | word-bgsg reading state (VM), word-reading |
| Dictionary order lines | PU:129-136 | 11 secondary | CV:134 | font only | word-readings |
| Note box | NV:7-32 | 12/10 padding, radius 10, primary 0.045 | CV:463 `Note` | same | word-mianzi, word-lost: every band within 1 px; fill 245/40 on both |
| Note symbol | NV:15 | globe.asia.australia.fill / translate, 11 semibold, teal / rose | IC `Globe`, `Translate` | same | symbols.png (own drawings) |
| Note title | NV:18-21 | 11 semibold secondary, 4 after the symbol | CV:473 | font only | word-mianzi: title starts at the same x |
| Note text | NV:23-26 | 13 primary, line spacing 2 | CV:475 | font only | word-mianzi: lines wrap the same |
| Divider | CC:705 | 1 tall, primary 0.08 | CV:524 | same | 238/46 on both |
| Meanings label | CC:695 | 11 semibold secondary | CV:525 | font only | all word cases: dy 0 to +1 |
| Sense rows | CC:732-765, PU:153-175 | 13; number size−1 medium tertiary; pos italic secondary; 5 above and below | CV:374 `SenseRow` | font only | word-all: dh 0; rows dy 0 to ±1 |
| Number column | CC:743 | 9, or 8 × digits + 1 | CV:383 | same | word-all (15 meanings) |
| Reading header | CC:783-796 | 11 medium secondary, 8 above | CV `SenseRow` | font only | word-readings |
| Chosen row | CC:756 | semibold primary, others secondary | CV:397 | font only | word-mianzi |
| Choice mark | CC:713-726 | checkmark 12 semibold accent, 14 box | CV:411, IC `Checkmark` | same | symbols.png, word-mianzi |
| Note mark | PU:200-206 | text.bubble 11 tertiary | CV:527, IC `Bubble` | same | word-mianzi row 2 |
| Show All / Show Fewer | PU:176-189 | 12 medium accent, chevron.down 10 semibold, 4 | CV:420 `More` | font only | word-all |
| Other words here | PU:191-194 | 11 tertiary | CV:155 | font only | word-ganmao, word-mianzi (live: see report, the Mac's live card has none either) |

### Phrase card

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
| Source text | PC:26-34 | 14 secondary, up to 4 lines | CV:222 | font only | phrase-*: dy 0 |
| Translation | PC:61-66 | 16, line spacing 2 | CV:229 | font only | phrase-ming: dy 0; same breaks |
| Translating | PC:69-72 | spinner, 12 secondary | CV:237 | same | phrase-translating: dh 0 |
| No translation | PC:67 | 11 secondary | CV:235 | font only | code |
| Words label, divider | PC:39-41 | as on the word card | CV:249-251 | same | phrase-*: dy 0 to +1 |
| Phrase rows | PC:75-129 | word 17 medium, pinyin 10.5, gloss 13, gutter 12, 5 above and below | CV:289 `PhraseRow` | font only | phrase-trad, phrase-ming-open: dy 0 to +1. "prohibition on entering or leaving by sea" breaks before "by sea" on Windows: Segoe sets that line 3% wider |
| Word column | PC:4-8 | widest word block | CV:254 | same | gloss x within 1 px |
| Row chevron | PC:114-120 | chevron.forward 10 semibold tertiary, turns 90 open | CV:322 | same | phrase-ming-open |
| Row detail | PC:131-213 | 2 above, 8 below, rows 3 above and below | CV:334 `Detail` | font only | phrase-ming-open, phrase-guanxi-open: dh 0 |
| Pending rows | PC:89, 99, 110 | redacted bars | CV:889, 916 | same | phrase-pending |
| More words not shown | PC:46-49 | 11 tertiary, 4 above and below | CV:261 | font only | phrase-long (+9 px: one gloss breaks a line earlier, font width) |
| Hint | PU:839-844 | 12 secondary | CV:100 `Hint` | open | no gallery case |

### Buttons and symbols

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
| Listen | CC:849-858 | speaker.wave.2, always shown | CV:641, IC `Speaker` | same | symbols.png; without a voice Windows shows how to add one (the Mac always has one) |
| Copy | CC:859-865 | doc.on.doc | CV:674, IC `Copy` | same | symbols.png |
| Anki | CC:905-937 | add, added, failed symbols | CV:780, IC `AnkiAdd`, `AnkiAdded`, `Warning` | same | word-anki, phrase-anki: dh 0; symbols.png |
| Pin | CC:869-878 | pin / pin.fill accent, 1 lower | CV:616, IC `Pin`, `PinFill` | same | word-pinned |
| Button box | CC:941-976 | 26 × 22, gap 2, 12 medium symbol | CV:711 | same | buttons line up within 1 px (word-anki) |
| Slot | CC:802-821 | n × 26 + (n−1) × 2 − 6 | CV:623 | same | word-bgsg breaks with 3 and with 4 buttons |
| Symbol colours | CC:954-955 | tertiary, secondary on the card, primary hovered | CV:627 `Rest`, 824 `Recolor` | same | code |
| Symbols drawn | SF Symbols | own vector drawings, the Mac's sizes | IC | same | symbols.png at 2x and 1x |

### States

| State | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
| Light, dark | all | | TH | same | every case in both modes |
| Picked meaning | PU:113 | Back to, picked row | CV | same | word-picked: dh 0 |
| Pinned | CC:980 | pin.fill accent | CV:616 | same | word-pinned: dh 0 |
| Pending, translating | PC | | CV | same | phrase-pending, phrase-translating |
| Row hover, pressed | CC:683 | primary 0.05, 0.09, radius 6, bleed 8 | CV:545 `RowButton`, TH | open | no render hook on either side; values the same in code |
| Button hover, pressed | CC:957-976 | primary 0.07; opacity 0.55 | CV:711 | open | same as above |
| Copied | CC:882-900 | checkmark in accent for 1.5 s | CV:674 | open | same as above |
| Listening | CC:856 | waves light in turn | CV:641 | open | same as above |
| Motion | CC:191-197 | cardMotion | Motion.cs | see Motion and behaviour | |

### Fonts

San Francisco and Segoe differ in shape, so their sizes are matched, not copied:
- Latin text is set 1.04 × the Mac's size (TH `LatinScale`): the same x-height.
- Then stretched across by size (TH `LatinStretch`): San Francisco is wider at small sizes and a
  little narrower around 16. With it, lines break where the Mac's do.
- San Francisco Medium and Semibold are both drawn in Segoe Semibold (TH `LatinWeight`); the
  ink measured closest.
- Chinese is Microsoft YaHei UI at 0.92 × the size (TH `ChineseScale`), Bold for PingFang
  Medium (YaHei has no Medium).
- Line heights are SwiftUI's for the system font at each size (CV `LineHeight`), measured on a
  Mac: 10 and 10.5 → 13, 11 → 14, 12 → 15, 13 → 16, 14 → 17, 15 and 16 → 19, 18 → 21,
  19 → 23, 34 → 40.

### Colours

The Mac's `Color.primary` is black or white at 0.85, so `Color.primary.opacity(x)` is 0.85 × x
(TH `Fill`): hairline 0.10, divider 0.08, note fill 0.045, row hover 0.05, pressed 0.09, button
hover 0.07. Text colours are the label colours (primary 0.85, secondary 0.50 light and 0.55
dark, tertiary 0.26 and 0.25). The dark surface is #1F1F21 (the Mac's 0.12, 0.12, 0.13).

The Mac's gallery pictures used to be drawn into a Generic RGB bitmap. That blends translucent
colours lighter than the screen does (a divider at 241 instead of 238). They are now drawn in
sRGB (CLI.swift `writePNG`), as on screen.

### Not compared

- Live glass style (macOS 26 only; Windows has the classic style only).
- The popover material behind the Mac card: Windows draws the surface opaque.

### Dark mode text

In sRGB, the Mac's dark-mode text has more ink than Windows': the secondary rows of word-mianzi
sum to 388k on the Mac and 280k on Windows, with the same peak colour (123 and 120). macOS
thickens light text on dark backgrounds; WPF's grayscale smoothing doesn't. So dark text looks
thinner on Windows, not brighter, and the secondary alpha stays 0.55. Light mode is within 10%.

### Tools

Side by sides: Mac, Windows, and an overlay, per case, after converting any Generic RGB picture
to sRGB. Band shifts: each row of text is found by its ink, and its vertical and horizontal
offset is the best match of the two pictures' ink profiles. These are scratch scripts (Python
with Pillow), not kept in the repo; the gallery pictures are.
