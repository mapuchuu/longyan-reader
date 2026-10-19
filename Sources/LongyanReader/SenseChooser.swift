import Foundation
import FoundationModels

enum NuanceTag: String, CaseIterable {
    case none
    case lostInTranslation
    case culturalContext
}

struct SenseChoice {
    var senseNumber: Int
    var meaningHere: String
    var tag: NuanceTag
    var note: String
}

/// Chooses which dictionary sense fits the passage, using Apple's on-device model.
/// The model never writes definitions; it picks from the numbered list.
enum SenseChooser {
    static var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    static var unavailableReason: String {
        switch availability {
        case .available: return "available"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
        case .unavailable(.modelNotReady): return "model still downloading"
        case .unavailable(.deviceNotEligible): return "this Mac can't run it"
        case .unavailable(let other): return "unavailable (\(other))"
        }
    }

    // Kept short: longer instructions made the on-device model refuse ordinary history sentences.
    static let instructions = """
    You help an English speaker read Chinese. You get a Chinese passage with one word marked 【like this】 and that word's numbered dictionary senses. \
    Say what the marked word alone means here, then pick the matching sense. Never invent a sense. \
    Most words get tag none. A tagged word gets a note in plain English: what a native speaker feels or pictures when using it here. No em dashes.
    """

    /// No pinyin in the prompt: repeated syllables like "kuan1 rong2" (or tone-marked ü)
    /// make the on-device model reject the whole prompt as an unsupported language.
    /// The English glosses are enough to tell the senses apart; the card shows pinyin itself.
    static func prompt(_ passage: String, word: String, senses: [Sense]) -> String {
        let list = senses.enumerated().map { i, s in "\(i + 1). \(s.gloss)" }
        return """
        Passage: \(passage)
        Marked word: \(word)
        Senses:
        \(list.joined(separator: "\n"))
        """
    }

    /// The output schema, built at runtime. (The @Generable macro needs full Xcode;
    /// this works with just the Command Line Tools.)
    static func schema(senseCount: Int, withNuance: Bool = true) throws -> GenerationSchema {
        typealias S = DynamicGenerationSchema
        let root = S(name: "SenseChoice", properties: [
            S.Property(name: "meaningHere",
                       description: "English for the marked word alone as used in this passage, 1 to 5 words. Not a translation of the sentence.",
                       schema: S(type: String.self)),
            S.Property(name: "senseNumber",
                       description: "The sense that matches meaningHere.",
                       schema: S(type: Int.self, guides: [.range(1...max(senseCount, 1))])),
        ] + (!withNuance ? [] : [
            S.Property(name: "tag",
                       description: "none for most words. lostInTranslation if no English word carries the meaning or register it has here. culturalContext if it needs knowledge specific to Chinese history, politics, society or culture.",
                       schema: S(name: "NuanceTag", anyOf: NuanceTag.allCases.map(\.rawValue))),
            S.Property(name: "note",
                       description: "Empty when tag is none. Otherwise one or two short sentences.",
                       schema: S(type: String.self)),
        ]))
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// The on-device model sometimes rejects a prompt (a false "unsupported language"
    /// or "sensitive content"), so retry with less: the sentence alone, then no nuance fields.
    static func choose(for context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        let attempts: [(passage: String, nuance: Bool)] = [
            (context.markedPassage, true), (context.markedSentence, true), (context.markedSentence, false),
        ]
        var lastError: Error?
        for attempt in attempts {
            do {
                return try await respond(prompt(attempt.passage, word: context.word, senses: senses),
                                         senses: senses, nuance: attempt.nuance)
            } catch {
                lastError = error
            }
        }
        throw lastError!
    }

    private static func respond(_ prompt: String, senses: [Sense], nuance: Bool) async throws -> SenseChoice {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            schema: try schema(senseCount: senses.count, withNuance: nuance),
            options: GenerationOptions(sampling: .greedy)
        )
        let content = response.content
        var choice = SenseChoice(
            senseNumber: try content.value(Int.self, forProperty: "senseNumber"),
            meaningHere: try content.value(String.self, forProperty: "meaningHere"),
            tag: nuance ? NuanceTag(rawValue: (try? content.value(String.self, forProperty: "tag")) ?? "") ?? .none : .none,
            note: nuance ? (try? content.value(String.self, forProperty: "note")) ?? "" : ""
        )
        choice.senseNumber = min(max(choice.senseNumber, 1), max(senses.count, 1))
        choice.senseNumber = agreeingSense(choice, senses: senses)
        if choice.tag == .none { choice.note = "" }
        return choice
    }

    /// The model's short meaningHere is usually better than its sense number
    /// (校长: "school principal" but sense "president"). If the chosen sense shares
    /// no word with meaningHere and exactly one other sense does, take that one.
    static func agreeingSense(_ choice: SenseChoice, senses: [Sense]) -> Int {
        let want = glossWords(choice.meaningHere)
        guard !want.isEmpty else { return choice.senseNumber }
        let overlaps = senses.map { !glossWords($0.gloss).isDisjoint(with: want) }
        if overlaps[choice.senseNumber - 1] { return choice.senseNumber }
        let matching = overlaps.indices.filter { overlaps[$0] }
        return matching.count == 1 ? matching[0] + 1 : choice.senseNumber
    }

    /// Content words of an English gloss, crudely stemmed (principal/principals, finish/finished).
    static func glossWords(_ s: String) -> Set<String> {
        let stop: Set<String> = ["the", "a", "an", "to", "of", "in", "on", "for", "and", "or", "be", "is", "etc", "sb", "sth",
                                 "with", "used", "form", "bound", "one", "his", "her", "its", "their", "this", "that"]
        var out: Set<String> = []
        for part in s.lowercased().split(whereSeparator: { !$0.isLetter }) {
            var word = String(part)
            guard word.count > 2, !stop.contains(word) else { continue }
            if word.count > 3, word.hasSuffix("s") { word.removeLast() }
            out.insert(String(word.prefix(5)))
        }
        return out
    }

    /// The sense whose gloss shares the most words with an English translation of the
    /// passage, or nil when none does. Instant; used for a phrase's first-pass glosses.
    static func senseMatching(translation: String, senses: [Sense]) -> Int? {
        let words = glossWords(translation)
        let scores = senses.map { glossWords($0.gloss).intersection(words).count }
        guard let best = scores.max(), best > 0 else { return nil }
        return scores.firstIndex(of: best)
    }
}
