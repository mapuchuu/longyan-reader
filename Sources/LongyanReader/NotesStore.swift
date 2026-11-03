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
        if let n = shared[key(word, sense.pinyin, sense.gloss)] { return n }
        return word.count == 4 ? byWord[word] : nil
    }

    /// True only for the sense the note was written for (no idiom fallback).
    static func hasExactNote(_ word: String, _ sense: Sense) -> Bool { shared[key(word, sense.pinyin, sense.gloss)] != nil }
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
    static func senseNumber(_ word: String, at range: Range<Int>, in passage: [Character], senses: [Sense]) -> Int? {
        for c in byWord[word] ?? [] {
            let cue = Array(c.cue)
            guard let i = senses.firstIndex(where: { $0.gloss == c.gloss }) else { continue }
            let first = max(0, range.upperBound - cue.count), last = min(range.lowerBound, passage.count - cue.count)
            guard first <= last else { continue }
            for start in first...last where Array(passage[start..<start + cue.count]) == cue { return i + 1 }
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
        shared[NotesStore.key(word, sense.pinyin, sense.gloss)] ?? []
    }
}

/// The tag label and note, shared by both cards.
struct NuanceView: View {
    let note: StoredNote
    @Environment(\.cardScale) private var scale
    var body: some View {
        let lost = note.tag == "lost_in_translation"
        let tint = noteTint(note.tag)
        VStack(alignment: .leading, spacing: 5) {
            Label(lost ? "Lost in translation" : "Cultural context",
                  systemImage: lost ? "text.bubble" : "building.columns")
                .cardFont(11, .semibold)
                .foregroundStyle(tint)
            Text(note.note).cardFont(13).fixedSize(horizontal: false, vertical: true)
                .lineSpacing(1.5)
        }
        .padding(10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(tint.opacity(0.10)))
    }
}
