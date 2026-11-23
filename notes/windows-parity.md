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
STATUS_CARD

## Word card

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
STATUS_WORD

## Phrase card

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
STATUS_PHRASE

## Buttons and symbols

| Element | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
STATUS_BUTTONS

## States

| State | Mac | Values | Windows | Status | Evidence |
|---|---|---|---|---|---|
STATUS_STATES

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
