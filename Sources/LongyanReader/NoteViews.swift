import LongyanCore
import SwiftUI

/// The tag label and note, shared by both cards: a quiet grey block with a sentence-case
/// label like the card's other section labels, no icon or colour (on the cards, colour
/// only marks the reader's choice).
struct NuanceView: View {
    let note: StoredNote
    @Environment(\.cardScale) private var scale
    var body: some View {
        let lost = note.tag == "lost_in_translation"
        VStack(alignment: .leading, spacing: Space.xs * scale) {
            // A small coloured symbol tells the two kinds apart; the block itself stays plain.
            HStack(spacing: 4 * scale) {
                Image(systemName: lost ? "translate" : "globe.asia.australia.fill")
                    .cardFont(TextSize.subheadline, .semibold)
                    .foregroundStyle(lost ? NoteColors.lost : NoteColors.culture)
                Text(lost ? "Lost in translation" : "Cultural context")
                    .cardFont(TextSize.subheadline, .semibold)
                    .foregroundStyle(.secondary)
            }
            Text(note.shown)
                .cardFont(TextSize.body)
                .lineSpacing(2 * scale)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.m * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// The note symbols' colours: the muted family of the tone colours rather than the system's
/// saturated orange and teal. A dusty amber and a sage teal, deeper in light mode and softer
/// in dark mode, so each reads the same against either card.
enum NoteColors {
    static let lost = tone(light: (0.69, 0.36, 0.50), dark: (0.90, 0.64, 0.76))
    static let culture = tone(light: (0.27, 0.51, 0.50), dark: (0.58, 0.78, 0.76))
}
