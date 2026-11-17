# longyan.app design

The site should feel like the app: exact, calm, made for reading Chinese. Black pages for type and UI, and bright paper backdrops between them, like a macOS wallpaper.

## Color

| Name | Hex | Use |
|---|---|---|
| Night | `#000000` | Page background. |
| Ink | `#f5f5f7` | Headlines and body text on Night. |
| Graphite | `#86868b` | Secondary text, the grey half of captions. |
| Moonlight | `#a1bde3` → `#c2abe0` | The eye: its text, mostly blue and lavender, with a little rose and mint where the tint turns, like a pearl. Each character has one tint; nothing moves. |
| Tone 1–4 | `#e39e94` `#9ecca8` `#a1bde3` `#c2abe0` | The app's dark-mode tone colors. Only the cards use them, where they mean something. |

Paper backdrops (`paper.js`) are five-stop ramps, deep to light: azure, rose, green, blue, violet and dusk. Each has folds of light that rise slowly and end in a clean crease, sometimes a disc of lighter paper, and on the feature tiles a lighter sheet along the bottom with a sharp edge. Grain is a CSS overlay at full resolution.

## Type

- **SF Pro Display**, semibold (600), tight tracking, for headlines. Crisp rather than airy.
- **SF Pro Text** for body and UI. Captions lead with a bold phrase and continue in grey.
- **PingFang SC** for Chinese, everywhere.

## Layout

1. **Story.** Pinned while it plays. The Longyan eye over a range of mountains, all of it in Chinese characters. The mountains are a halftone made of characters: light ones (一, 人) where it's dim, dense ones where it's bright, none where it's dark, with mist drifting through. A few faint characters are stars. The eye is set in everyday sentences, in pearl tints, in characters of nine sizes. Every character is whole; nothing is masked or cut. On the outline a character may stand a hair past the edge (well inside the blank margin round its ink, so the outline stays crisp), so the outline takes every size from fine to large and reads as type rather than a stencil. A few small characters sit right across the point where the pupil meets the wedge, so the hook reads as one stroke, as in the icon. Characters too thin to fill their square, like 一 and 人, are left out of it. It comes in left to right. Pointing at a character shows the word it's part of and what it means in that sentence, from the app. Scrolling breaks the eye up, and its characters float out from all over, in arcs, into one large sentence (up to 64px on a wide screen, 40px on a phone). Most come from the eye's big characters, so you see them lift out of the shape. Selecting works as in any Mac text: drag across characters, double-click a word, triple-click the sentence, shift-click to extend. Let go and the selection eases onto whole words and the app's card opens. No marks under the words. There is one sentence; no "Next sentence". It hands over from the canvas to selectable text in a single frame, with no fade, so nothing doubles or flashes; only the heading, "Highlight anything.", fades in. Then "Highlight" is selected with a sweep and stays selected, the sentence catches the light character by character, and "Try it!" shows under it and goes. The opening glides: an even pace, easing to a stop only at the end.
2. **Statement.** Three lines that fade in one at a time as you scroll ("Dictionaries give you every meaning." / "Longyan gives you the one your sentence means," with "one" in the card's checkmark blue / "and flags words that need more context."), beside the app's real word card for 躺平 in the demo sentence, built into the page. The card shows a little more with each line: first just 躺平, its pinyin and both meanings, none picked; then "to opt out of the rat race" opens in under the word and, a beat later, the check springs in on that meaning, its row lights up in the check's blue and stays lit, and the other meaning steps back; then the "Cultural context" note opens in. Each line waits until the last one and its card change have settled (1.8 s at least, just under half a screen of scrolling apart), and the section holds for reading after the last. On a phone each step also waits until the card is well up the screen. The pinned lines never move as the card grows. A click on a meaning shows the whole card. On a wide screen the section is pulled up over the opening's last 35vh, so it rises in right behind the demo sentence with no empty screen between, then holds still (100vh pinned plus 100vh of scroll): the card and first line come in as the content comes into view, the next two just under half a screen apart, then about two thirds of a screen to read and try the card. On a phone each sentence comes in as it comes up into view, close under the demo. Even a fast scroll brings them in a beat apart.
3. **Works where you read.** Full-bleed azure paper. A frosted window, cut off by the section's bottom edge, holds the recording.
4. **Made for reading.** Four tiles: a piece of the real UI on paper, with a caption.
5. **Install.** A grey band. The Open Anyway row from System Settings on paper, next to the four steps.
6. **Closing.** Full-bleed dusk paper, the icon, one line, the download button.

## Crispness

- The mark is drawn from its geometry, not traced: three nested eye shapes (each the hull of a circle and two points, half-widths 1, 5/8 and 3/14) and one wedge. The stroke is even all round and the edges are as sharp as the screen. The old PNG wobbled.
- One material: characters. Everything in the hero is drawn in them, whole. No masks, no halo, no glow.
- The selection is the system blue with an iridescent violet-and-rose sheen moving through it, sized to the selection so even one character shows it.
- On a wide screen the ridges are scaled to the screen's height, as on a phone, so they're broad ranges rather than many small bumps. They stay low under the headline and open into a valley under the eye. As the story plays they fall away and fade, as on a phone.
- On a wide screen the eye is second to the headline: about as tall as the headline and the line under it (a quarter of the width, at most 470px), level with the text.
- The bar's logo is the mark alone in white, the app icon's negative, 25px wide.
- Hairlines are 0.5px. Shadows are layered: a 0.5px ring, a tight shadow and a wide soft one.

## Motion

- On load the mountains rise into place and the eye comes in left to right, each character flashing white as it lands. It doesn't blink.
- The story is scrubbed by scroll, smoothed a little each frame so a wheel step doesn't jump. The eye breaking up into the sentence takes three quarters of a screen of scrolling; the sentence then holds for about 0.6 of a screen to try before the page moves on (235vh in all). The headline rises line by line on load. Once the sentences form, the word underlines draw in. The card is the app's, with its springs: it scales in from the selection, its height follows its content, and rows slide open.
- Below the story, sections rise into place once, and the video window lifts out of its backdrop as it comes into view.
- `prefers-reduced-motion`: no scramble, no rise, the hero drawn still. `?still` does the same for screenshots.

## The card

The demo card is the app's card, not a picture of it: same sizes, colors, Liquid Glass and motion, and the same answers. When the app's card changes, `card.js` changes with it. Only Pin is left out.

## Words

Plain and short. Say what the app does in the visitor's words. No "seamless", "powerful", "unlock". Buttons say what happens: "Download for Mac".
