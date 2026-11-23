# Windows card parity with the Mac card

Every visual element and state of the Mac card, what the Windows card does, and whether they
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
IC = Icons.cs. Evidence paths are under the gallery workflow's artifact (win) and
windows/gallery/mac (mac); composites are made with the scratch tools described at the end.

## Card

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

## Word card

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

## Phrase card

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

## Buttons and symbols

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

## States

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
| Motion | CC:191-197 | cardMotion | Motion.cs | open | not compared in this pass |

## Fonts

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

## Colours

The Mac's `Color.primary` is black or white at 0.85, so `Color.primary.opacity(x)` is 0.85 × x
(TH `Fill`): hairline 0.10, divider 0.08, note fill 0.045, row hover 0.05, pressed 0.09, button
hover 0.07. Text colours are the label colours (primary 0.85, secondary 0.50 light and 0.55
dark, tertiary 0.26 and 0.25). The dark surface is #1F1F21 (the Mac's 0.12, 0.12, 0.13).

The Mac's gallery pictures used to be drawn into a Generic RGB bitmap. That blends translucent
colours lighter than the screen does (a divider at 241 instead of 238). They are now drawn in
sRGB (CLI.swift `writePNG`), as on screen.

## Not compared

- Live glass style (macOS 26 only; Windows has the classic style only).
- The popover material behind the Mac card: Windows draws the surface opaque.

## Dark mode text

In sRGB, the Mac's dark-mode text has more ink than Windows': the secondary rows of word-mianzi
sum to 388k on the Mac and 280k on Windows, with the same peak colour (123 and 120). macOS
thickens light text on dark backgrounds; WPF's grayscale smoothing doesn't. So dark text looks
thinner on Windows, not brighter, and the secondary alpha stays 0.55. Light mode is within 10%.

## Tools

Side by sides: Mac, Windows, and an overlay, per case, after converting any Generic RGB picture
to sRGB. Band shifts: each row of text is found by its ink, and its vertical and horizontal
offset is the best match of the two pictures' ink profiles. These are scratch scripts (Python
with Pillow), not kept in the repo; the gallery pictures are.
