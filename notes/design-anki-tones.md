# Design: Add to Anki, and tone color choices

Both features follow how the app already works:
- The card keeps its single row of plain symbol buttons.
- The menu bar menu is the only place for settings.
- Nothing shows unless it can be used: Listen hides with no Chinese voice, and Liquid Glass hides below macOS 26.
- Help text is short and plain.

## Add to Anki

**Where it is.** It's a fourth symbol in the card's button row: Listen, Copy, Anki, Pin. It uses `rectangle.stack.badge.plus`, the same size and tertiary color as the others. It's on word cards and phrase cards.

**When it shows.** Only while Anki is open with AnkiConnect installed. People who don't use Anki never see it, and nothing needs setting up. The app asks AnkiConnect (on 127.0.0.1:8765) whether it's there:
- at launch
- when the eye appears, at most every 10 s
- when the menu opens

A card takes the answer at the moment it opens, so the row never changes width while the card is up.

**What a click does.**
- It adds one note and the symbol turns into an accent checkmark, the way Copy does, then settles on `checkmark.rectangle.stack` in the accent color: "In Anki".
- If the word is already in the deck, the card opens in that state, and clicking shows the note in Anki's browser.
- If Anki doesn't answer, a warning symbol shows for 2 s, with help text "Anki didn't answer. Is it open?"

**What goes in.**
- The app creates a note type called "Longyan Reader" on first use, with these fields: Chinese, Pinyin, Meaning, Sentence, Dictionary, Note.
- The same layout as the export's cards:
  - the front is the Chinese
  - the back is the pinyin, then the meaning in bold, the sentence with the word in bold, the note, and the dictionary sense in small text
- A phrase gets the phrase and its translation.
- The meaning is whatever the card shows when you click, including a meaning you picked yourself.

**Deck.** The default is "Longyan Reader", the deck the export uses. A menu item, **Anki Deck**, lists your decks while Anki is open. It sits under Keep History, the other place lookups go.

**Left out for now:**
- mapping fields onto your own note types
- audio
- adding from the History window

Each of these can come later without changing anything above.

**Privacy.** The app talks only to Anki on this Mac, the way the Ollama check does. The privacy page, README and About need one line about it.

## Tone colors

**Where.** Appearance ▸ Tone Colors is a submenu. Each scheme has a short name, with its four colors beside it as dots, the way Finder shows tags:
- **Standard:** red, green, blue, purple, the order Pleco uses. The default.
- **Dummitt:** red, orange, green, blue, Nathan Dummitt's order, used by MDBG.
- **Custom:** the colors picked in the Tone Colors window.
- **Off:** four empty rings.
- **Edit Custom Colors…** comes after a separator. It opens the window and switches to Custom. Picking a scheme and editing colors are separate items, as in Finder's View menu.

The dots are 10 pt with a hairline edge so pale colors keep their shape. Each item's colors in words are in its help and for VoiceOver.

**Palettes.** Each palette has a light and a dark version, muted the way today's are:
- The new orange is (0.60, 0.43, 0.10) in light mode and (0.92, 0.79, 0.48) in dark: amber, so it stays clear of the red.
- On the card's background the orange has a contrast of 4.6 in light mode and 10.4 in dark. Today's green is 4.3 and 9.2.

**Custom window.** A grouped form, like System Settings:
- At the top, a preview drawn like a card's header: 妈麻马骂 with mā má mǎ mà beside it, in the current appearance only.
- Then one row per tone: "First tone" with its syllable underneath, and a color well.
- The footer says "The same colors are used in light and dark mode."
- Each picked color is darkened toward black on the light card until its contrast is 4.2, and lightened toward white on the dark card until it's 7, only as far as needed. So one pick per tone stays readable in both modes. The built-in palettes already pass both.
- Restore Defaults, under the form on the right, copies today's colors back.
- There's no Done button. Changes show on an open card straight away, so the window just closes.
- Until colors are picked, Custom uses today's light colors.

**Settings.**
- A new key, `toneScheme`, takes one of: standard, dummitt, custom or off.
- The old `toneColors = false` setting still means off.
- Custom colors are kept as hex strings in `toneCustom`.
- The neutral tone stays the secondary label color in every scheme.
