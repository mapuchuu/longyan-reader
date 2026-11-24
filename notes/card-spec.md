# Card spec for the Windows (WPF) port

This describes the Mac lookup card as built in SwiftUI/AppKit, so it can be rebuilt in WPF.
Every number cites its Swift source as `file:line`. Paths are under `Sources/LongyanReader/`
unless they start with `LongyanCore/`.

Units: a Mac point (pt) maps 1:1 to a WPF device-independent pixel. Font sizes are in pt and
map 1:1 to WPF `FontSize`.

Short names used below:
- **CC** = `CardChrome.swift`
- **PU** = `Popup.swift`
- **PC** = `PhraseCard.swift`
- **NV** = `NoteViews.swift`
- **TC** = `ToneColors.swift`
- **APP** = `App.swift`
- `× s` means "multiplied by the card's zoom" (see 1.6).

---

## 0. Colour roles

The code uses SwiftUI semantic styles. These are the macOS system values they resolve to.
They are system values, not set in this code, so treat them as close approximations.

| Role in code | Light | Dark |
|---|---|---|
| `.primary` text (labelColor) | black, alpha 0.85 | white, alpha 0.85 |
| `.secondary` text (secondaryLabelColor) | black, alpha 0.50 | white, alpha 0.55 |
| `.tertiary` text (tertiaryLabelColor) | black, alpha 0.26 | white, alpha 0.25 |
| `Color.accentColor` (system accent, default blue) | #0A60FF as rendered (not #007AFF) | #0A60FF as rendered (not #0A84FF) |

`Color.primary.opacity(x)` is used for fills and strokes. Treat it as black (light) or white
(dark) at alpha `x`. macOS may also apply labelColor's 0.85 alpha, so the real alpha can be
`0.85 × x`. The difference is small; match by eye on a Mac.

On Windows, use the user's accent colour if you want it to feel native. Use #007AFF / #0A84FF
to match the Mac exactly.

### Fixed colours (sRGB)

| Name | Light | Dark | Source |
|---|---|---|---|
| Card surface over the material (classic) | #FFFFFF at alpha 0.80 | #1F1F21 (0.12, 0.12, 0.13) at alpha 0.78 | CC:273-279 |
| Card surface, opaque (snapshots, no blur) | #FFFFFF | #1F1F21 | CC:276-277 |
| Glass tint (Liquid Glass style only) | #FFFFFF at alpha 0.55 | #141417 (0.08, 0.08, 0.09) at alpha 0.38 | CC:549-553 |
| Tone 1, brick | #A8544C | #E39E94 | TC:62 |
| Tone 2, sage | #4A8761 | #9ECCA8 | TC:63 |
| Tone 3, slate | #4A73A6 | #A1BDE3 | TC:64 |
| Tone 4, violet | #8061A3 | #C2ABE0 | TC:65 |
| Dummitt tone 2, amber | #996E1A | #EBC97A | TC:69 |
| Note icon, "Lost in translation" | #B05C80 | #E6A3C2 | NV:38 |
| Note icon, "Cultural context" | #458280 | #94C7C2 | NV:39 |

The #171719 once sampled from the renders was the Generic RGB file's raw value; in sRGB it is #1F1F21. Windows has no material, so it uses #1F1F21 opaque, as the Mac's snapshots do. `Color.primary` is black or white at 0.85, so every `Color.primary.opacity(x)` below is 0.85 × x.

Tone schemes (TC:5-12, TC:61-72):
- **Standard** (default): tones 1-4 = brick, sage, slate, violet.
- **Dummitt**: tones 1-4 = brick, amber, sage, slate.
- **Custom**: one colour per tone. Light version is darkened toward black in steps of 0.02
  until WCAG contrast on #FFFFFF is at least 4.2. Dark version is lightened toward white in
  steps of 0.02 until contrast on #1F1F21 is at least 7 (TC:105-115).
- **Off**: no tone colours.

Light/dark is picked per colour by the window's appearance (TC:165-170).

---

## 1. Window and chrome

### 1.1 Widths

| Kind | Default width | Source |
|---|---|---|
| word card | 360 | CC:45 |
| phrase card | 390 | CC:45 |
| hint (short message) | 260 | CC:45 |

- Min width 240, max width 1000 (CC:49).
- Width is saved per kind (`card.width.word`, `card.width.phrase`) (CC:48, CC:61, CC:165).
- With no saved width: default width × zoom (CC:62).
- Hints never zoom, never resize, never save (CC:52, CC:61, CC:152).

### 1.2 Padding inside the card

All × s (CC:395-397):
- left and right: 16 (`Space.l`)
- top: 16 (`Space.l`)
- bottom: 12 (`Space.m`)

### 1.3 Shape, border, background

- Corner radius 16, continuous corners (a squircle, not a plain arc) (CC:341, CC:353-356).
  In WPF a plain `CornerRadius="16"` is close enough. A squircle path is closer.
- Liquid Glass style (macOS 26 only, a menu option): radius 20 (CC:353). The Windows port can
  skip Glass and build only Classic.
- Border: 0.5 pt hairline, inside the edge, `Color.primary` at 0.10 alpha (CC:489).
  In WPF: a 0.5 DIP border at 0.085 (0.85 × 0.10).
- Background, classic style, two layers (CC:477-488):
  1. The system popover material: `NSVisualEffectView`, material `.popover`, blending
     `.behindWindow`, state always active (CC:295-301). It blurs whatever is behind the window.
  2. Over it, the card surface: white at 0.80 (light) or #1F1F21 at 0.78 (dark) (CC:273-279).
  So the card reads near-white or near-black with a little translucency.
  WPF: use Windows 11 acrylic or Mica Alt behind a transparent window
  (`DwmSetWindowAttribute` with `DWMWA_SYSTEMBACKDROP_TYPE` = `DWMSBT_TRANSIENTWINDOW`), with
  the surface colour on top. If no backdrop is available, use the opaque surface colour.
- All content is clipped to the rounded shape, so row highlights never show past the corners
  (CC:461-462, CC:493).

### 1.4 Shadow

The card draws its own shadow. The window itself has none (PU:339).
Two shadows, drawn from the card's outline only, cut out under the card so they do not
darken the translucent surface (CC:525-545):

| Layer | Colour | SwiftUI radius | Y offset |
|---|---|---|---|
| 1 | black, alpha 0.16 | 16 | +8 (downward) |
| 2 | black, alpha 0.08 | 1.5 | +0.5 |

SwiftUI radius is about half a CSS blur radius. So layer 1 is about CSS `0 8px 32px`, layer 2
about `0 0.5px 3px`. In WPF, `DropShadowEffect` blur differs; tune by eye against a Mac.

### 1.5 Transparent window around the card

- The window is a borderless, transparent frame 28 pt larger than the card on every side,
  to hold the shadow (CC:343, PU:614-618).
- Window size = (card width + 56) × (card height + 56) (PU:617).
- The card sits at the top of that frame when placed below the selection, and at the bottom
  when placed above (CC:384-386).

### 1.6 Zoom (text size)

- One zoom for every card, saved as `card.zoom` (CC:13-15, CC:47).
- Range 0.8 to 2.2 (CC:46).
- Every font size, gap and inset in the content is multiplied by it. Exceptions that do not
  scale: the action buttons (26 × 22 boxes, 12 pt symbols), the close badge, the 1 pt divider,
  the grip and the edge grabber (CC:804-811, CC:953-956, CC:707).
- Ways to change it:
  - Pinch on the card (CC:368-373, CC:104-115).
  - Menu items Bigger Text (Cmd +), Smaller Text (Cmd -), Actual Size (Cmd 0) (APP:433-437).
    Each step multiplies zoom by 1.1 (CC:118-122). Actual Size sets zoom 1 and width to the
    default, for both kinds (APP:519-529, CC:144-149).
  - Dragging a corner (see 1.8).
- Width scales with zoom, so the card keeps its shape (CC:135-139).
- When zoom changes, the other kind's saved width is scaled by the same ratio (CC:154-163).

### 1.7 Height and scrolling

- Height always equals the content's height, up to a max. Past the max it scrolls (CC:65-67).
- Max height (PU:516-522): `max(120, min(room, screenVisibleHeight × 0.8))`, where `room` is
  the space between the selection and the screen edge on the chosen side, minus 16 (PU:518).
  Before placement it starts as `max(140, visibleHeight × 0.8)` (PU:329).
- Height changes under 0.5 pt are ignored (CC:70).
- No scroll bar ever (CC:423-427). Bounce only when the content is taller than the card (CC:428).
- Fades at the scroll edges (a mask over the content, CC:439-455):
  - Bottom: a 36 × s band fades the content to transparent while there is more below.
    "More below" means more than 2 pt of content past the bottom (CC:429-433, CC:449-451).
  - Top, when scrolled more than 1 pt (CC:434-438): content is fully hidden from the top of
    the card down to the bottom of the action buttons (button top + 22), then fades in over
    14 × s (CC:443-447). Unscrolled, nothing is hidden.
  - Both fades animate on and off with ease-out over 0.2 s (CC:453-454).
- Scrolling inside the card does not close it. It scrolls the content only.

### 1.8 Resizing

Resize grips live in bands straddling the card edge, half in the shadow margin (CC:572-601):
- Left edge: band 8 wide (4 outside + 4 inside). Right edge: 12 wide (4 outside + 8 inside)
  (CC:578-580, CC:588-589).
- Edge bands stop 14 short of each corner (CC:588-589).
- Corners: 14 × 14 squares. Bottom-right: 26 × 26 (CC:578, CC:582, CC:590-593).
- No top or bottom edge handles. Height is always the content's (CC:573-574).
- Cursor: the matching resize cursor while hovering and for the whole drag (CC:637-656).
  WPF: `SizeWE` for edges, `SizeNWSE` / `SizeNESW` for corners.
- Side edge drag: that edge follows the pointer, the other stays. Width clamps to 240-1000 and
  to the screen's visible area inset 8 (PU:549, PU:565-567).
- Corner drag: scales zoom and width together. The opposite corner stays put. Scale factor
  `f = 1 + (outX·w + outY·h) / (w² + h²)`, where outX/outY are the pointer's outward movement
  (PU:552-563). Zoom clamps to 0.8-2.2, width to 240-1000 (CC:127-133).
- Double-click an edge: width back to default × zoom. Double-click a corner: zoom 1 and
  default width (CC:630, CC:144-149).
- Corner tooltip: "Drag to resize · double-click for actual size". Edges have none (CC:631).
- During a resize or pinch, size changes follow the hand with no animation (CC:36-37, CC:365).
- Hints have no handles (CC:376).

Hover hints for resizing:
- **Grip** at bottom-right, 3 pt in from the corner (CC:491) (5 pt for Glass, CC:473): a
  13 × 13 box with three diagonal 1 pt lines. Line i (0, 1, 2) starts at inset `i × 3.5 + 2`
  and runs from (width − 2, inset) to (inset, height − 2). Colour `primary` at 0.22, or 0.45
  while resizing (CC:556-569). Shown only while the pointer is on the card or resizing; fades
  ease-out 0.15 s (CC:499-506). Not clickable.
- **Edge grabber**: a capsule 3 wide and `min(22, cardHeight × 0.3)` tall, centred on the
  right edge, 3 pt in. Colour `primary` at 0.20, or 0.40 while resizing. Only when the card is
  taller than 60. Same hover fade, 0.15 s (CC:510-520).

### 1.9 Moving

- Drag anywhere on the card except the resize bands and corners (PU:635-652, PU:221-246).
  Rows and buttons included.
- A press becomes a move after 4 pt of travel. The pressed control then gets a mouse-up far
  outside itself, so it does not count as a click (PU:233-236, PU:249-255).
- Moving shifts the anchor, so the card stays put as its content changes (PU:661-680).
- After a move or resize, scrolling elsewhere no longer closes the card (PU:657-659).
- No cursor change for moving.

### 1.10 Placement relative to the selection

The anchor is the selection's screen rectangle. With no selection (hotkey pointing at a word),
it is a 40 × 20 box centred on the pointer (APP:656-659).

- Gap between card and anchor: 8 pt (PU:620-628).
- Horizontal: card's left edge = anchor's left edge (PU:625).
- Below or above (PU:508-514):
  - `below` = anchor bottom − 16 − screen bottom. `above` = screen top − anchor top − 16.
  - Below if pinned, or opened in place, or `below ≥ max(contentHeight, 320)`, or
    `below ≥ above`. Otherwise above.
  - Decided once the content's height is first measured (PU:398-401).
- Below: the card's top edge is fixed 8 pt under the selection. It grows downward (PU:626-628).
- Above: the card's bottom edge is fixed 8 pt over the selection. It grows upward.
- Screen edges: the card is kept at least 8 pt inside the screen's visible area (menu bar and
  Dock excluded), on all four sides (PU:629-630). Because max height is limited to the room
  on its side (1.7), the card never has to be pushed back over the selection.
- Which screen: the one holding most of the anchor, else the one with the pointer (PU:576-585).
- A card placed above flips to hang from its top edge the first time it is clicked, without
  moving. From then on rows open downward, so the clicked row stays under the pointer
  (PU:493-504, PU:362).

### 1.11 Pinned cards

- Pin button toggles. Saved as `card.pinned` and the card's top-left corner as
  `card.pinnedTopLeft` (CC:173-189).
- Pinning keeps the card where it is and makes it hang from that corner (PU:477-491).
- A pinned card opens at its saved corner for every lookup and is replaced in place
  (PU:305-319, PU:462-465).
- A pinned card ignores click-away, scroll-away and global Esc (PU:380-388).
- Close badge (pinned only) (CC:980-1009):
  - 20 × 20 circle, centred on the card's top-left corner, shifted −7, −7 (so it hangs over
    the corner) (CC:992, CC:1007).
  - Symbol `xmark`, 8 pt bold, `secondary`, `primary` on hover (CC:989-991).
  - Fill: system regular material. Border 0.5 pt `primary` at 0.12. Shadow black 0.12,
    radius 2, y +1 (CC:993-995).
  - Shown only while the pointer is on the card or on the badge. Hidden: opacity 0, scale 0.7.
    Animated with a spring, response 0.25, damping 0.9 (CC:987, CC:1003-1006).
  - Pressed: opacity 0.55, ease-out 0.08 s (CC:970-976). Tooltip "Close" (CC:1000).

### 1.12 Window behaviour

- Never takes focus from the app being read (PU:208-210, PU:332-334). The first click lands on
  the control, not just on the window (PU:258-261).
  WPF: `ShowActivated="False"`, `WS_EX_NOACTIVATE`, `WS_EX_TOOLWINDOW`, `Topmost="True"`.
- Level: pop-up menu, above normal windows. On all desktops and over full-screen apps (PU:340-341).
- No system window animation (PU:335). No system shadow (PU:339).
- Light/dark follows the system, or a menu choice of Light or Dark (CC:262-270, APP:503-509).

---

## 2. Typography

Font: the system font (SF Pro) at every size (CC:221-231). Chinese falls back to the system's
CJK font (PingFang SC on the Mac). Windows: Segoe UI Variable for Latin and Microsoft YaHei UI
for Chinese, matched to the Mac's size, width, weight and line height as notes/windows-parity.md
("Fonts") describes.

Line heights (SwiftUI, system font, measured): 10 and 10.5 → 13, 11 → 14, 12 → 15, 13 → 16,
14 → 17, 15 and 16 → 19, 18 → 21, 19 → 23, 34 → 40. A text's `lineSpacing` adds between lines
only, not after the last.

Monospaced digits: only the sense number (CC:749). In WPF use
`Typography.NumeralAlignment="Tabular"`.

Text size constants (CC:206-210):

| Name | pt |
|---|---|
| `headword` | 34 |
| `headline` | 19 |
| `translation` | 16 |
| `rowWord` | 18 |
| `title3` | 15 |
| `body` | 13 |
| `callout` | 12 |
| `subheadline` | 11 |
| `footnote` | 10 |

Every size is × s.

### Every text role

| Role | Size | Weight | Colour | Other | Source |
|---|---|---|---|---|---|
| Headword (word card) | 34 | medium | per character tone (see 4.1) | one line | PU:44-47 |
| Header pinyin (word card) | 15 | regular | per syllable tone | wraps in the two-line layout | PU:48-51 |
| Meaning line | 19 | semibold | primary | wraps, no limit | PU:79-82 |
| "Meaning in this sentence" | 11 | regular | secondary | | PU:84 |
| Part of row, "Part of" | 12 | regular | secondary | | PU:96, PU:104 |
| Part of row, word | 13 | medium | primary | | PU:97 |
| Part of row, pinyin | 12 | regular | secondary | tone marks, no tone colours | PU:98 |
| Part of row, meaning | 12 | regular | primary | 1 line | PU:100 |
| Part of row, chevron | 10 | semibold | tertiary | `chevron.forward` | PU:102 |
| "Back to “…”" link | 12 | regular | accent | 1 line, with icon | PU:115-120 |
| "Reading the sentence…" | 12 | regular | secondary | with spinner | PU:125-126 |
| Status lines | 11 | regular | secondary | | PU:129-135 |
| Section label | 11 | semibold | secondary | sentence case | CC:695-702 |
| Reading header | 11 | semibold | secondary | | CC:788-790 |
| Sense number | sense size − 1 | medium | tertiary | tabular digits, 1 line, right-aligned | CC:748-753 |
| Sense gloss (word card) | 13 | regular, semibold if chosen | primary, secondary if dimmed | wraps | CC:754-757, PU:165 |
| Sense gloss (phrase detail) | 12 | as above | as above | wraps | PC:181 |
| Part of speech label | same as gloss | regular (even if chosen) | secondary | italic | CC:763 |
| Show All / Show Fewer | 12 | medium | accent | | PU:182-186 |
| Its chevron | 10 | semibold | accent | `chevron.down` | PU:183 |
| "Other words here: …" | 11 | regular | tertiary | | PU:192-193 |
| Note title | 11 | semibold | secondary | | NV:18-20 |
| Note icon | 11 | semibold | note colour | | NV:15-17 |
| Note body | 13 | regular | primary | line spacing +2 × s, wraps | NV:22-25 |
| Note mark | 11 | regular | tertiary | `text.bubble` | PU:200-205 |
| Choice mark | 12 | semibold | accent | `checkmark` | CC:717-719 |
| Phrase source text | 14 | regular | secondary | up to 4 lines | PC:27-31 |
| Translation | 16 | regular | primary | line spacing +2 × s, wraps | PC:62-64 |
| "No translation · …" | 11 | regular | secondary | | PC:67 |
| "Translating…" | 12 | regular | secondary | with spinner | PC:69-70 |
| Phrase row hanzi | 17 (rowWord − 1) | medium | per character tone | | PC:92 |
| Phrase row pinyin | 10.5 (footnote + 0.5) | regular | per syllable tone | | PC:98 |
| Phrase row gloss | 13 | regular | primary, secondary for particles or guesses | 2 lines closed, unlimited open | PC:104-107 |
| Phrase row chevron | 10 | semibold | tertiary | `chevron.forward` | PC:115-117 |
| "In this sentence: " + meaning | 12 | regular + medium | secondary + primary | wraps | PC:144-146 |
| Phrase detail failure | 11 | regular | secondary | | PC:140 |
| Phrase detail "Not in the dictionary" | 12 | regular | secondary | | PC:208 |
| "N more words not shown" | 11 | regular | tertiary | 4 × s above and below | PC:45-46 |
| Hint text | 12 | regular | secondary | | PU:839-843 |
| Action button symbols | 12 (fixed) | medium | see 4.2 | | CC:953 |

"Line spacing +2" means 2 × s extra between lines, on top of the font's normal line height.

---

## 3. Spacing

Scale (CC:200-202), all × s where used:

| Name | pt |
|---|---|
| `xxs` | 2 |
| `xs` | 4 |
| `s` | 8 |
| `m` | 12 |
| `l` | 16 |
| `xl` | 20 (unused in the card) |

### Word card vertical rhythm (PU:17-37, PU:140-196)

```
Card padding top 16
┌ group, gap 4 between items ───────────────┐
│ header                                     │
│ meaning (meaning line, 2, "Meaning in…")   │
│ Part of row                                │
│ status (Back to link, then phase line)     │
└────────────────────────────────────────────┘
gap 12
note box (if any)
gap 12
┌ senses section, gap 8 between items ──────┐
│ divider                                    │
│ "Meanings"                                 │
│ rows (gap 0; each row has its own padding) │
│ "Other words here: …"                      │
└────────────────────────────────────────────┘
Card padding bottom 12
```

- Outer stack gap 12 (`m`) (PU:18).
- Top group gap 4 (`xs`) (PU:19).
- Meaning line to "Meaning in this sentence": 2 (`xxs`) (PU:78).
- Senses section gap 8 (`s`) (PU:148).
- Rows: gap 0 (PU:151). Each sense row has 5 above and below (CardRowStyle default, 3.1).
- Empty parts take no space. A missing view adds no gap.

### Phrase card vertical rhythm (PC:21-58)

- Outer stack gap 12 (PC:22).
- Top group (source text, translation) gap 4 (PC:25).
- Source text to action slot: horizontal gap 8 (PC:26).
- Words section gap 8: divider, "Words", rows (PC:39).
- Rows gap 0 (PC:42).
- The whole Words section is left out when there are no tokens (PC:38).

### Other gaps

- Header, headword to pinyin: 8 (PU:54). Pinyin to action slot: at least 8 (PU:57).
- Header two-line layout: 2 between lines (PU:60).
- Part of row items: 4 (PU:95).
- Spinner to text: 8 (PU:125, PC:69, PC:137).
- Sense row: SenseLine to note mark to choice mark, 8 (PU:161, PC:177).
- Sense number to gloss: 6 × s (CC:746).
- Show All text to chevron: 4 (PU:181, PC:198).
- Phrase row gutter (word column to gloss to note mark to chevron): 12 (`m`) (PC:19, PC:84).
- Phrase row hanzi to pinyin: 1 × s (PC:86). Between pinyin syllables: 2 × s (PC:93).
  Between hanzi: 0 (PC:87).
- Phrase detail: 2 above, 8 below, 8 between items (PC:134, PC:211-212).
- Note box: 12 left and right, 10 top and bottom, 4 between title and body, 4 between icon
  and title (NV:12-14, NV:27-28).
- Reading header: 8 above (0 for the first), 1 below (CC:791-792).

### Number column width (CC:743-745)

Wide enough for the longest number in the full list (`total`, not just the shown ones):
- 1 digit: 9 × s
- 2 digits: 17 × s (8 × digits + 1)
- 3 digits: 25 × s

Numbers are right-aligned in that column.

### Phrase word column width (PC:4-8, PC:101-103)

Each row's word block (hanzi over pinyin) is measured at its natural width. The column is the
widest of all rows. Every row uses that width, left-aligned, so every gloss starts at the
same x. Until it is measured, rows use their own width.

---

## 4. Components

### 4.1 Header (word card)

Layout (PU:39-74). Try the one-line layout first. If it does not fit the width, use the
two-line layout (SwiftUI `ViewThatFits`, horizontal).

One line, all on the first text baseline:
`[headword] 8 [pinyin] ≥8 [action slot]`
Headword and pinyin never wrap or shrink here (PU:55-56).

Two lines (word too long for one line):
- Line 1: the headword at full size, 1 line, allowed to shrink to 50% to fit (PU:67), then the
  action slot. The line's height is held at that of one full-size character (an invisible 国
  at 34 pt), so the buttons sit where they do on every other card (PU:62-68).
- 2 pt gap.
- Line 2: pinyin, wrapping (PU:71).

Tone colouring (PU:43-50, TC:182-184):
- The header pinyin is split into syllables. Character i gets syllable i's tone.
  A character with no syllable is tone 5 (neutral).
- Character colour, `hanziColor(t)`:
  - tone colours on, tone 1-4: that tone's colour
  - tone colours on, neutral tone: secondary
  - tone colours off: primary
- Pinyin syllable colour, `pinyinColor(t)`: tone 1-4 colour; neutral or colours off: secondary.
- Pinyin syllables are joined with single spaces (PU:49). Tone marks are applied (`hǎo`), not
  numbers.
- The pinyin crossfades when it changes (PU:56).

### 4.2 Action buttons

Order, left to right: **Listen, Copy, Anki, Pin** (CC:848-879). Each appears only if:

| Button | Shown when | Source |
|---|---|---|
| Listen | a Chinese voice is installed, not a hint | CC:849, PU:348 |
| Copy | any word or phrase card | CC:859 |
| Anki | AnkiConnect answers and the card has something to add | CC:866, PU:350 |
| Pin | any word or phrase card | CC:869 |

Hints show no buttons (CC:411).

Box and look (CC:941-976):
- Each button 26 × 22, gap 2 (CC:848, CC:956). Not scaled by zoom.
- Symbol 12 pt, medium weight (CC:953).
- Symbol colour: the tint if it has one, else `primary` under the pointer, `secondary` while
  the pointer is anywhere on the card, `tertiary` otherwise (CC:954-955).
- Hover: rounded rectangle, radius 6, `primary` at 0.07 (CC:957-958). Ease-out 0.15 s (CC:963).
- Card-hover colour change: ease-out 0.2 s (CC:964).
- Pressed: whole button at opacity 0.55, ease-out 0.08 s (CC:970-976).
- Tooltip and accessible name = the help text (CC:965-966).

Placement (CC:403-417, CC:798-821):
- The first content line holds an invisible slot for them: width `n × 26 + (n − 1) × 2 − 6`,
  height 22. That is 76 for 3 buttons, 104 for 4 (CC:811). `n` is 3, or 4 with Anki (CC:33).
- The slot's centre sits `c` above the first line's baseline: c = 12 × s on the word card
  (PU:52), 5 × s on the phrase card (PC:33).
- The real buttons are drawn in a fixed layer over the card's top-right, lined up with that
  slot. They do not scroll with the content (CC:408-417).
- Right edge: the last symbol's edge lines up with the content's right edge. The buttons'
  right edge is `16 × s − 6` from the card's right edge (CC:415, CC:806).

Each button:

| Button | Symbol (SF Symbols) | Tint | Help text | Source |
|---|---|---|---|---|
| Listen | `speaker.wave.2` | accent while playing | word card: "Listen to “X”" (or a context variant); phrase card: "Listen"; while playing: "Stop" | CC:849-858, LongyanCore/LookupState.swift:153-158, APP:839 |
| Copy | `doc.on.doc`, then `checkmark` for 1.5 s after a copy | accent while showing the checkmark | "Copy “X”" (X cut to 13 characters + "…" past 14), then "Copied" | CC:859-865, CC:882-900 |
| Anki, ready | `rectangle.stack.badge.plus` | none | "Add “X” to Anki" | CC:918-937 |
| Anki, adding | `rectangle.stack.badge.plus` at opacity 0.4 | none | "Adding to Anki…" | CC:914, CC:934 |
| Anki, added | `checkmark.rectangle.stack` | accent | "In Anki · click to show it there" | CC:921, CC:927, CC:935 |
| Anki, failed | `exclamationmark.triangle` | none | the reason | CC:922, CC:936 |
| Pin, off | `pin` | none | "Pin: keep the card here for every lookup" | CC:869-878 |
| Pin, on | `pin.fill` | accent | "Unpin: close when you click elsewhere" | |

Symbol effects:
- Listen, while playing: the speaker's waves light up in turn, repeating (CC:856).
- Copy, Anki and Pin symbol changes: the old symbol slides down and out as the new one comes
  in (`replace.downUp`) (CC:863, CC:873, CC:913).
- Pin: a small downward bounce when toggled (CC:874). Drawn 1 pt lower than centre, to look
  level with the others (CC:875-877).

Windows: every symbol is our own vector drawing in windows/LongyanReader/Icons.cs (not Segoe
Fluent Icons, which look different), sized to the Mac symbol's frame and weight. They are drawn
for this app, not traced from SF Symbols. Compared in notes/windows-parity.md.

### 4.3 Meaning line (PU:76-90)

- Shown only once a meaning is chosen.
- 19 semibold, primary, wraps. Crossfades when the text changes (PU:82).
- If the meaning is the model's own wording for this sentence: "Meaning in this sentence",
  11 regular secondary, 2 below (PU:83-86). Fades in and out.
- The whole block fades in and out (PU:88).

### 4.4 Part of row (PU:92-110)

Shown when the word is part of a longer dictionary word in the sentence (彻 in 彻底).
- One line, items on the text baseline, 4 apart:
  "Part of" (12, secondary), the word (13 medium, primary), its pinyin with tone marks (12,
  secondary, no tone colours), its meaning once known (12, primary, 1 line, fades in), then
  `chevron.forward` (10 semibold, tertiary).
- A row button, CardRowStyle with bleed 4 and vertical padding 2 (PU:106). Hugs its content
  width, does not stretch (PU:107).
- Tooltip "Look up X" (PU:108).
- Click: opens that word's card in this card's place, hanging from the same top-left corner
  (PU:94, APP:738-741, PU:287-292).

### 4.5 Status (PU:112-138)

Two parts, stacked with the top group's 4 gap.

1. "Back to “meaning”" link: only after the reader picked a different meaning from the
   model's. Icon `arrow.uturn.backward` + text, 12 regular, accent, 1 line. Plain button, no
   hover background. Click restores the model's pick, animated. Fades in and out
   (PU:113-122).
2. The phase line:
   - Choosing: mini spinner, 8, "Reading the sentence…", 12 secondary. Fades (PU:124-127).
     The mini spinner is about 10 pt across (system `controlSize(.mini)`). WPF: a small
     indeterminate ring about 10 DIP.
   - Dictionary only: "Not in the dictionary", or "Dictionary order · {reason}". 11 secondary
     (PU:128-129).
   - Failed: "Dictionary order · couldn't tell which meaning fits here", 11 secondary, tooltip
     with the error (PU:130-132).
   - Chosen via the translation: "Picked to match the translation", 11 secondary (PU:133-136).
   - Chosen otherwise: nothing.

### 4.6 Note box (NuanceView, NV:7-32)

- Full content width.
- Background: rounded rectangle, radius 10 × s, continuous, `primary` at 0.045 (NV:30).
  No border, no shadow.
- Padding 12 left and right, 10 top and bottom (NV:27-28).
- Title row, 4 apart (NV:14-21):
  - Tag `lost_in_translation`: icon `translate`, colour #B05C80 / #E6A3C2, title
    "Lost in translation".
  - Any other tag: icon `globe.asia.australia.fill`, colour #458280 / #94C7C2, title
    "Cultural context".
  - Icon and title 11 semibold. Title secondary.
- 4 gap, then the body: 13 regular primary, line spacing +2 × s, wraps (NV:22-25).
- Word card: shown for the chosen meaning's note. Appears with opacity plus a slide from
  4 × s above. A different note replaces it with the same transition (PU:25-29).
- Phrase detail: fades in and out only (PC:160).

### 4.7 Divider (CC:705-709)

A 1 pt tall rectangle, `primary` at 0.08, full content width (inside the 16 padding).
Not scaled.

### 4.8 Section label (CC:695-702)

Text "Meanings" (word card) or "Words" (phrase card). Sentence case, no uppercase, no extra
letter spacing. 11 semibold secondary.

### 4.9 Sense rows (word card PU:148-190, phrase detail PC:169-206)

Each row is a button with CardRowStyle (3.1). Inside: a row, vertically centred, gap 8:
`[SenseLine, fills the width] [NoteMark if this meaning has a note] [ChoiceMark]`.

SenseLine (CC:732-765), items on the first text baseline, gap 6 × s:
- Number: the sense's position in the full dictionary list (1-based), so gaps show where
  meanings were left out (CC:728-730). Size − 1, medium, tertiary, tabular digits, right-aligned
  in the number column (3, "Number column width").
- Definition: optional part of speech label, a space, then the gloss.
  - Labels: "n.", "v.", "adj.", "adv.", "m.w.", "part." (LongyanCore/PartOfSpeech.swift:10-19).
    Italic, regular weight, secondary.
  - Gloss: semibold if chosen, else regular. Secondary if dimmed, else primary. Wraps.
- Tooltip on the line: the full readable gloss (PU:166). On the row: "Use this meaning", or
  "Use this meaning · has a note" (PU:173).

Chosen and dimmed:
- Word card: chosen = this is the picked meaning. Dimmed = not chosen and some meaning is
  picked. With no pick yet, nothing is dimmed (PU:165).
- Phrase detail: dimmed = not chosen (PC:181). Grammar words (的, 了) have no chosen row (PC:172).

ChoiceMark (CC:713-726): `checkmark`, 12 semibold, accent, in a 14 × s box at the trailing
edge, right-aligned. Always takes its width. Not chosen: opacity 0, scale 0.6. Chosen:
opacity 1, scale 1. Animates with the pick (cardMotion).

NoteMark (PU:199-206): `text.bubble`, 11 regular, tertiary. Word card rows only (PC detail has
none).

Which rows show (PU:141-146, LongyanCore/Dictionary.swift:16-26):
- Collapsed: up to 5. The chosen one, then the first meaning of each reading, then the rest in
  order, until 5. Shown in dictionary order.
- Grammar words (的, 了) list only their own reading's meanings.
- Within the shown list, each reading's meanings are grouped together, readings in the order
  they first appear (CC:767-774).

Click a row: picks that meaning, animated (PU:160, PC:176).
Row vertical padding: 5 on the word card (PU:172), 3 in the phrase detail (PC:187).

### 4.10 Reading header (CC:782-796)

Shown before the first meaning of each reading, only when the word has more than one reading
(好 hǎo, hào). Word card: also only when not a grammar word, or when Show All is on (PU:152).
- Pinyin with tone marks, 11 semibold secondary. No tone colours.
- 8 × s above, except 0 for the first one. 1 × s below.
- Full width, left-aligned. Not a button.

### 4.11 Show All / Show Fewer (PU:176-189, PC:191-206)

- Shown when there are more meanings than the collapsed list shows.
- Text "Show All N" (N = total) or "Show Fewer", then 4, then `chevron.down`.
- Text 12 medium accent. Chevron 10 semibold accent.
- Chevron rotates 0° (collapsed) to 180° (expanded), with cardMotion.
- A row button, CardRowStyle (word: default; phrase detail: bleed 8, vertical 3).
- Click toggles with cardMotion, then the card relayouts (APP:880-884: 30 ms wait, then
  resize, animated).

### 4.12 Alternatives line (PU:191-194)

"Other words here: A · B" (joined with " · "), 11 regular tertiary. Last item in the senses
section. Only when there are alternatives.

### 4.13 Phrase card top (PC:23-36, PC:60-73)

- Source text: the highlighted Chinese, 14 regular secondary, up to 4 lines, wraps, fills the
  width. The action slot sits at its right on the first baseline.
- 4 gap, then the translation, one of:
  - The translation: 16 regular primary, line spacing +2 × s, wraps. Fades in.
  - Error: "No translation · {error}", 11 secondary.
  - Waiting: mini spinner, 8, "Translating…", 12 secondary. Fades.

### 4.14 Phrase rows (PC:75-129)

At most 24 rows. Past that: "N more words not shown", 11 tertiary, 4 × s above and below
(PC:16, PC:43-47).

Each row: a button with CardRowStyle, bleed 8, vertical 5 (PC:122). Inside, items on the
first text baseline, gap 12:
1. Word block, in the shared column width (3):
   - Hanzi: each character its tone colour (as in 4.1), 17 medium. While pending: all secondary.
   - 1 × s below: pinyin syllables, 2 × s apart, each its tone colour, 10.5 regular.
   - Character i takes syllable i's tone from the shown meaning's pinyin.
2. Gloss: 13 regular, fills the remaining width. Secondary for particle words (的 了 和 是 在
   也 都 就 与 或 但 而 对 于 把 被 让 给 从 到 着 过 吗 呢 吧 啊 嗯 呀 地 得, plus traditional
   forms, LongyanCore/PhraseState.swift:380-383) and for guesses (no pick could be made),
   else primary. 2 lines when closed, no limit when open. Crossfades when it changes.
3. NoteMark, if not pending and the shown meaning has a note.
4. `chevron.forward`, 10 semibold tertiary. Rotates 0° to 90° when the row is open, with
   cardMotion. Opacity 0 (keeps its space) when the row has nothing more to show.

Pending (waiting for the model to pick this word's sense,
LongyanCore/PhraseState.swift:144-146):
- Pinyin and gloss are drawn as redacted placeholders: rounded grey bars where the text would
  be (SwiftUI `.redacted(.placeholder)`). The gloss is also at opacity 0.6 (PC:99, PC:110-111).
  WPF: draw rounded rectangles at the text's size, `primary` at about 0.10 to 0.15, radius 2-3.
- Hanzi turn secondary (PC:89).

Opens (LongyanCore/PhraseState.swift:351-354): more than one meaning, a note, the model's own
wording, a failure, or pending. A row that does not open is disabled, unless it is open
(PC:123). The code sets no extra look for a disabled row. SwiftUI may dim it slightly and may
still show the hover highlight; check on a Mac.

Only one row is open at a time. Clicking the open row closes it (LongyanCore/PhraseState.swift:356-357).

### 4.15 Phrase row detail (PC:131-213)

Appears under the open row. Transition: opacity plus a slide from 6 × s above (PC:126).
Uses the card's full width from the leading edge (PC:210), not the gloss column.
Padding 2 × s top, 8 × s bottom. Items 8 apart. In order:

1. One status line, the first that applies:
   - Pending or choosing: mini spinner, 8, "Reading the sentence…", 12 secondary.
   - Failure: the reason, 11 secondary.
   - Picked via the translation: "Picked to match the translation", 11 secondary.
   - The model's wording: "In this sentence: " (secondary) + meaning (medium, primary), 12,
     wraps. Fades.
2. "Back to “meaning”" link, same as 4.5.
3. Note box (4.6), fades.
4. Sense rows (4.9) at 12 pt, vertical padding 3, no note marks. Reading headers when the shown
   list has more than one reading (PC:168).
5. Show All / Show Fewer (4.11).
6. With no meanings: "Not in the dictionary", 12 secondary (PC:208).

---

## 5. CardRowStyle (CC:659-692)

A full-width button that highlights like a macOS list row.

- Default bleed 8 (`Space.s`) and vertical padding 5 (`Space.xs + 1`) (CC:663-664).
- Padding: vertical `vertical × s`, horizontal `bleed × s` (CC:679).
- Then the row is pulled out by `bleed × s` on each side (negative padding, CC:686). So the
  text stays on the content's left edge, and the highlight reaches `bleed` past it on both
  sides.
- Fills the available width, text left-aligned (CC:680). The whole rectangle is clickable
  (CC:685).
- Highlight: rounded rectangle, radius 6 × s, continuous (CC:682).
  - Rest: none.
  - Hover: `primary` at 0.05.
  - Pressed: `primary` at 0.09 (CC:683).
- Hover timing: ease-out 0.08 s going on, 0.2 s going off (CC:688).
- Press timing: ease-out 0.08 s (CC:689).

Variants used:

| Where | bleed | vertical | Source |
|---|---|---|---|
| Word sense rows, word Show All | 8 | 5 | PU:172, PU:188 |
| Part of row | 4 | 2 | PU:106 |
| Phrase rows | 8 | 5 | PC:122 |
| Phrase detail senses and Show All | 8 | 3 | PC:187, PC:205 |

With the 16 card padding and 8 bleed, a row highlight ends 8 from the card's edge.

---

## 6. Animation and feel

### 6.1 cardMotion (CC:191-197)

Every change inside a card uses one motion:
- Normal: spring, response 0.34 s, damping fraction 1 (critically damped, no overshoot).
- Reduce Motion on: ease-in-out, 0.15 s.

To reproduce the spring in WPF (SwiftUI's spring model, mass 1, stiffness = (2π / response)²):
- ω = 2π / 0.34 = 18.48 rad/s.
- Progress `x(t) = 1 − (1 + ωt) · e^(−ωt)`.
- Reaches 99% at about t = 0.36 s, 99.9% at about 0.5 s. Run it for 0.5 s.
- A custom `EasingFunctionBase` with that formula, over 0.5 s, matches it. A rough stand-in is
  `CubicEase EaseOut` over 0.4 s.

### 6.2 What animates with cardMotion

Word card, when any of these change: chosen sense, phase, Show All, user picked, Part of
meaning (PU:32-36). Phrase card: open row, translation, picks, choosing, resolving (PC:53-57).
Explicit wraps: picking a row, Show All, Back to, opening a phrase row (PU:114, PU:160,
PU:178, PC:83, PC:150, PC:176, PC:193).

Transitions:

| Element | In and out | Source |
|---|---|---|
| Note box (word card) | opacity + offset y from −4 × s | PU:27 |
| Phrase row detail | opacity + offset y from −6 × s | PC:126 |
| Meaning block, "Meaning in this sentence" | opacity | PU:85, PU:88 |
| Back to link | opacity | PU:121, PC:157 |
| "Reading the sentence…", "Translating…" | opacity | PU:127, PC:71 |
| Translation text | opacity | PC:65 |
| Part of meaning | opacity | PU:100 |
| "In this sentence" | opacity | PC:147 |
| Phrase note box | opacity | PC:160 |

Content crossfades (text replaced in place): header pinyin, meaning line, phrase row gloss
(PU:56, PU:82, PC:112).

Rotations: Show All chevron 0° to 180° (PU:184, PC:201). Phrase row chevron 0° to 90° (PC:118).
Choice mark: opacity 0 to 1 and scale 0.6 to 1 (CC:720-721). All with cardMotion.

Content around inserted or removed parts slides to its new place with the same motion.

### 6.3 Card height changes

- The card's height animates with cardMotion, but only after the card has appeared and not
  during a resize or pinch (CC:365, CC:72).
- The window does not animate. It is resized instantly (PU:591-612, CC:328-331):
  - Growing: the window grows at once to the new size, then the card's height animates
    inside it.
  - Shrinking: the window keeps its larger size while the card animates smaller, then snaps
    to the new size 0.32 s later.
  - The edge nearest the selection stays put: the top edge when below, the bottom edge when
    above.
- After a content change the app waits 30 ms for layout, then resizes (APP:880-884).
- WPF approach: keep the window as a transparent frame with a 28 margin. Animate the card
  border's `Height` (or a clip) with cardMotion. Resize the window before growing and after
  shrinking, as above.

### 6.4 Appearing (PU:297-448)

1. The window is created at opacity 0 and shown, so the content can be measured (PU:336, PU:367).
2. When the content's height is first known, placement is decided and the card shows 0.02 s
   later (PU:398-407). A fallback shows it 0.15 s after creation in any case (PU:368-370).
3. Hold: a word card whose model is ready waits up to 0.4 s for the model's pick, so it opens
   complete instead of changing right after (APP:756, PU:299-300, PU:371-375). If the pick
   arrives in time, it is applied with no animation and the card shows 0.04 s later
   (APP:787-794, PU:413-422). If the pick fails, the hold ends at once (APP:801).
   `isRevealed` tells the app whether the card is on screen yet, so a late pick animates in
   and an early one does not (PU:410, APP:787).
4. Reveal (PU:425-448):
   - Window opacity 0 to 1 over 0.14 s on AppKit's default timing for an `animator()` change,
     which is Core Animation's default curve, the cubic Bézier (0.25, 0.1, 0.25, 1). Not linear:
     it's half way at about a third of the time and 0.9 at about two thirds. Traced on the Mac
     (`--show --trace`), the window's alpha fits that curve over 0.14 s to within 0.01. It starts
     with the window's first frame.
   - At the same time the card goes from scale 0.96 to 1 and from y −4 to 0 (placed below) or
     +4 to 0 (placed above), on a spring with response 0.32 s, damping 0.82. Scale anchor:
     top edge when below, bottom edge when above (CC:382-383).
     WPF formula: ω = 2π / 0.32 = 19.63, ζ = 0.82, ωd = ω·√(1 − ζ²) = 11.24.
     `x(t) = 1 − e^(−ζωt) · (cos(ωd·t) + (ζ / √(1 − ζ²)) · sin(ωd·t))`. Slight overshoot (about
     1%). Run it for about 0.45 s.
   - Reduce Motion: no scale, no offset, the fade only (CC:381-383).
   - The card's height does not animate on the first frame, so it does not grow from nothing
     (CC:364-365).
5. Pinned card or a card opened in place: the new window fades in over the old one at the
   same spot, 0.12 s, no spring. The old window is removed when the fade ends (PU:429-441).

### 6.5 Disappearing (PU:717-734)

- Window opacity to 0 over 0.12 s on the same default curve as the reveal (0.25, 0.1, 0.25, 1),
  starting on the next frame, then removed. No scale or slide.
- Any speech from that card stops (PU:719).
- Hints close by themselves after 1.8 s if still on screen (APP:888-897).

### 6.6 Hover feedback timing (summary)

| What | Timing | Source |
|---|---|---|
| Row highlight on | ease-out 0.08 s | CC:688 |
| Row highlight off | ease-out 0.2 s | CC:688 |
| Row pressed | ease-out 0.08 s | CC:689 |
| Action button highlight | ease-out 0.15 s | CC:963 |
| Action symbols brighten when the card is hovered | ease-out 0.2 s | CC:964 |
| Action button pressed | ease-out 0.08 s | CC:974 |
| Grip and edge grabber | ease-out 0.15 s | CC:503, CC:517 |
| Close badge | spring 0.25 s, damping 0.9 | CC:1006 |
| Scroll edge fades | ease-out 0.2 s | CC:453-454 |

### 6.7 Cursors

- Resize cursors on resize bands and corners, held for the whole drag (CC:637-656).
- Arrow everywhere else, rows and buttons included. No hand cursor.

---

## 7. Dark mode

Dark mode changes only colours. Sizes, spacing and motion are the same.
- Surface: #1F1F21 at 0.78 over the material, instead of white at 0.80 (CC:276-277).
- Text roles switch to their dark values (section 0).
- All `primary`-based fills and strokes (border 0.10, divider 0.08, note box 0.045, hovers 0.05,
  0.07, 0.09, grip, grabber) become white at the same alpha.
- Tone and note colours switch to their pastel dark versions (section 0).
- Shadow stays black at the same alpha (CC:540-541).
- Accent: #0A84FF.
- Appearance follows the system unless the menu sets Light or Dark. An open card switches at
  once (CC:262-270, PU:709-712).

---

## 8. Other behaviour

- **Click away**: a left or right click in any other app closes the card, unless pinned
  (PU:377-384).
- **Scroll away**: scrolling in another app closes the card, unless pinned, or the card was
  moved or resized (PU:383, PU:657-659).
- **Esc**: pressed in any other app, closes the card unless pinned (PU:385-388). Pressed while
  the card's own window has the key event, closes it even when pinned (PU:389-393). Esc is not
  taken from other windows of the app (History, onboarding).
  WPF: use a low-level keyboard hook (`WH_KEYBOARD_LL`) for the global Esc and a mouse hook
  (`WH_MOUSE_LL`) for click and scroll away, since the card never has focus.
- **One card at a time.** A new lookup replaces the open card (PU:311-319). A hint beside a
  pinned card opens in a second window by the selection instead (APP:890).
- **Opening in place**: a card opened from inside another (Part of) replaces it, hanging from
  the same top-left corner (PU:279-292).
- **VoiceOver**: on reveal, the card announces "word, pinyin, meaning" since it never takes
  focus (PU:450-457). WPF: raise a UI Automation notification event.
- **Speech**: a new word or phrase card stops the previous card's speech (PU:304).
- **No scroll bar** and no horizontal scrolling (CC:423-428).
- Text is not selectable on the card.

### Selection button (Chip.swift, optional)

The small round button that appears by a fresh selection uses the same style:
- 24 pt circle, in a 30 pt hit area, inside a 44 pt transparent window (Chip.swift:79-81,
  Chip.swift:208, Chip.swift:215).
- Same material + surface + 0.5 pt `primary` 0.10 border as the card (Chip.swift:250-258).
- Shadow black 0.18, radius 5, y +2 (Chip.swift:213).
- The Longyan eye, 13 pt, secondary, primary on hover (Chip.swift:231-238).
- Scale 0.6 to 1 on appear (spring 0.3, damping 0.68), 1.08 on hover (spring 0.25, 0.7), 0.92
  pressed (spring 0.2, 0.7) (Chip.swift:212, Chip.swift:225-228).
- Placed 4 right of a one-line selection's end, vertically centred, else 6 right and 6 above
  the mouse-up point (Chip.swift:91-96).
- Fades in 0.12 s, out 0.1 s, hides itself after 6 s (Chip.swift:115-128, Chip.swift:166-175).
- Tooltip "Look up (⌃⌥L). Right-click to hide the eye." (Chip.swift:220).
