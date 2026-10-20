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
    var body: some View {
        let lost = note.tag == "lost_in_translation"
        VStack(alignment: .leading, spacing: 4) {
            Text(lost ? "LOST IN TRANSLATION" : "CULTURAL CONTEXT")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(lost ? Color.orange : Color.teal)
            Text(note.note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
