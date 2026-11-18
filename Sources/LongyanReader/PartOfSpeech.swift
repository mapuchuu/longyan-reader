import Foundation
import NaturalLanguage

/// A meaning's part of speech, read off its English definition: CC-CEDICT has no tags, but
/// it writes verbs as "to …", measure words and particles say so, and Apple's tagger can
/// tell "big" from "volume" from "quite". When the wording doesn't make it clear, there's none.
enum PartOfSpeech: String {
    case noun, verb, adjective, adverb, measureWord, particle

    /// Short, as dictionaries print it.
    var label: String {
        switch self {
        case .noun: "n."
        case .verb: "v."
        case .adjective: "adj."
        case .adverb: "adv."
        case .measureWord: "m.w."
        case .particle: "part."
        }
    }

    @MainActor private static var known: [String: PartOfSpeech?] = [:]

    @MainActor static func of(_ gloss: String) -> PartOfSpeech? {
        if let hit = known[gloss] { return hit }
        let found = guess(gloss)
        known[gloss] = found
        return found
    }

    static func guess(_ gloss: String) -> PartOfSpeech? {
        let raw = gloss.lowercased()
        if raw.contains("particle") || raw.contains("marker") { return .particle }
        if raw.hasPrefix("classifier") || raw.hasPrefix("measure word") || raw.hasPrefix("(classifier") { return .measureWord }
        // Cross-references and names aren't meanings with a part of speech.
        for skip in ["variant of", "see ", "used in", "abbr", "also written", "surname", "old variant", "(used ", "used ", "prefix", "suffix", "radical", "(verb complement", "(result complement"] where raw.hasPrefix(skip) { return nil }
        let readable = Gloss.readable(gloss).lowercased()
        // CC-CEDICT's "(of a person) clever", "(of two people) close": describing words.
        let describes = readable.hasPrefix("(of ")
        // Each clause votes ("pretty; beautiful"); the first that has a clear answer and
        // isn't outvoted wins.
        let votes = readable.split(separator: ";").prefix(4).compactMap { clause(String($0), describes: describes) }
        guard let first = votes.first else { return nil }
        let tally = Dictionary(votes.map { ($0, 1) }, uniquingKeysWith: +)
        let best = tally.max { $0.value < $1.value || ($0.value == $1.value && $1.key == first) }!.key
        // "pretty; beautiful": the tagger reads "pretty" alone as the adverb.
        if let adj = tally[.adjective], adj == tally[best] { return .adjective }
        return tally[first] == tally[best] ? first : best
    }

    /// Words the tagger misreads in a frame ("It is never.").
    private static let adverbs: Set<String> = ["never", "always", "often", "seldom", "rarely", "ever", "already", "still",
                                               "also", "only", "just", "again", "soon", "even", "once", "almost", "nearly"]

    private static func clause(_ raw: String, describes: Bool) -> PartOfSpeech? {
        // Asides go: "(of a person) clever", "volume (of a container)".
        var text = raw.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        if let comma = text.firstIndex(of: ",") { text = String(text[..<comma]) }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.range(of: #"[\p{Han}:]"#, options: .regularExpression) == nil else { return nil }
        if text.hasPrefix("to ") && !text.hasPrefix("to and ") { return .verb }
        let count = text.split(separator: " ").count
        guard count <= 4 else { return nil }
        if text.hasPrefix("a ") || text.hasPrefix("an ") || text.hasPrefix("the ") { return .noun }
        if adverbs.contains(text) { return .adverb }

        // Tagged in a sentence, where a word alone is a guess: "It is pretty." is an adjective.
        let frame = "It is "
        let sentence = frame + text + "."
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        var tags: [NLTag] = []
        let from = sentence.index(sentence.startIndex, offsetBy: frame.count)
        tagger.enumerateTags(in: from..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag { tags.append(tag) }
            return true
        }
        guard let last = tags.last else { return nil }
        if describes, [.adjective, .adverb, .verb, .noun].contains(last), tags.count <= 2 { return .adjective }
        if tags.count == 1 {
            switch last {
            case .noun: return .noun
            case .adjective: return .adjective
            case .adverb: return text.hasSuffix("er") ? .adjective : .adverb   // "older"
            default: return nil   // a bare verb is CC-CEDICT's noun ("rest") or unclear
            }
        }
        // A phrase is what its last word is, when the words before it modify it:
        // "very good" (adjective), "express consignment" (noun).
        let modifiers: Set<NLTag> = [.adjective, .adverb, .noun, .determiner, .number]
        guard tags.dropLast().allSatisfy(modifiers.contains) else { return nil }
        switch last {
        case .noun: return .noun
        case .adjective: return tags.dropLast().allSatisfy { $0 == .adverb } ? .adjective : nil
        case .adverb: return tags.dropLast().allSatisfy { $0 == .adverb } ? .adverb : nil
        default: return nil
        }
    }
}
