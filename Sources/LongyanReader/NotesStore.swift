import Foundation
import SwiftUI

/// Nuance notes written ahead of time (notes.json), one per dictionary sense that needs one.
/// The on-device model only picks the sense; the note shown is the prewritten one.
struct StoredNote: Codable {
    let word: String
    let pinyin: String
    let gloss: String
    let tag: String          // "lost_in_translation" or "cultural_context"
    let note: String

    /// The note as shown: a full-width mark (？ 。 ，) carries its own space, so the space
    /// typed after it in English text would read as two.
    var shown: String { note.replacingOccurrences(of: "([？！。，、；：]) ", with: "$1", options: .regularExpression) }
}

enum NotesStore {
    static let shared: [String: StoredNote] = {
        let url = Bundle.main.url(forResource: "notes", withExtension: "json")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/notes.json")
        guard let data = try? Data(contentsOf: url),
              let notes = try? JSONDecoder().decode([StoredNote].self, from: data) else { return [:] }
        return Dictionary(notes.map { (key($0.word, $0.pinyin, $0.gloss), $0) }, uniquingKeysWith: { a, _ in a })
    }()

    private static let byWord: [String: StoredNote] = Dictionary(shared.values.map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })

    static func key(_ word: String, _ pinyin: String, _ gloss: String) -> String { "\(word)|\(pinyin)|\(gloss)" }

    /// The note for this sense. A four-character idiom's note describes the whole idiom,
    /// so it shows whichever paraphrase (literal or figurative) was picked.
    static func note(_ word: String, _ sense: Sense?) -> StoredNote? {
        guard let sense else { return nil }
        let word = headword(word)
        if let n = shared[key(word, sense.pinyin, sense.gloss)] { return n }
        return word.count == 4 ? byWord[word] : nil
    }

    /// True only for the sense the note was written for (no idiom fallback).
    static func hasExactNote(_ word: String, _ sense: Sense) -> Bool { shared[key(headword(word), sense.pinyin, sense.gloss)] != nil }

    /// Notes are written under the simplified form; traditional text finds them through it.
    static func headword(_ word: String) -> String {
        guard word.contains(where: isCJK), byWord[word] == nil, let dict = CEDict.current else { return word }
        return dict.simplified(word)
    }
}

/// Fixed casual patterns the model doesn't read as their noted sense, however it's asked
/// (这不科学, 你可以啊, 研究研究). A cue settles the sense without a model call.
struct NoteCue: Codable {
    let word: String
    let cue: String
    let gloss: String
}

enum NoteCues {
    static let byWord: [String: [NoteCue]] = {
        let url = Bundle.main.url(forResource: "note-cues", withExtension: "json")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/note-cues.json")
        guard let data = try? Data(contentsOf: url),
              let cues = try? JSONDecoder().decode([NoteCue].self, from: data) else { return [:] }
        return Dictionary(grouping: cues, by: \.word)
    }()

    /// The sense number (1-based) a cue settles for the word at `range`: the cue has to cover
    /// that occurrence of the word, not just appear somewhere in the passage.
    /// Cues are written in simplified; traditional text (這不科學) is compared once simplified.
    static func senseNumber(_ word: String, at range: Range<Int>, in passage: [Character], senses: [Sense]) -> Int? {
        let simple = byWord[word] == nil ? NotesStore.headword(word) : word
        let traditional = simple != word
        for c in byWord[simple] ?? [] {
            let cue = Array(c.cue)
            guard let i = senses.firstIndex(where: { $0.gloss == c.gloss }) else { continue }
            let first = max(0, range.upperBound - cue.count), last = min(range.lowerBound, passage.count - cue.count)
            guard first <= last else { continue }
            for start in first...last {
                let window = Array(passage[start..<start + cue.count])
                // A single character only takes a cue that holds the word it belongs to: 不行
                // settles 行, but not the 行 of 不行动, which is part of 行动.
                if word.count == 1, let dict = CEDict.current,
                   let enclosing = Segmenter.enclosingWord(of: range, in: passage, dict: dict),
                   enclosing.lowerBound < start || enclosing.upperBound > start + cue.count { continue }
                if window == cue { return i + 1 }
                if traditional, let dict = CEDict.current,
                   dict.simplified(String(window)) == c.cue || window.map({ dict.simplified(String($0)) }).joined() == c.cue { return i + 1 }
            }
        }
        return nil
    }
}

/// Example sentences per sense (examples.json), used to tell close senses apart.
enum ExamplesStore {
    static let shared: [String: [String]] = {
        let url = Bundle.main.url(forResource: "examples", withExtension: "json")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/examples.json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }()

    static func examples(_ word: String, _ sense: Sense) -> [String] {
        shared[NotesStore.key(word, sense.pinyin, sense.gloss)] ?? shared[NotesStore.key(NotesStore.headword(word), sense.pinyin, sense.gloss)] ?? []
    }
}

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
