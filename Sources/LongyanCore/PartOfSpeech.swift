import Foundation

/// A meaning's part of speech, read off its English definition: CC-CEDICT has no tags, but
/// it writes verbs as "to …", measure words and particles say so, and an English tagger can
/// tell "big" from "volume" from "quite". When the wording doesn't make it clear, there's none.
package enum PartOfSpeech: String {
    case noun, verb, adjective, adverb, measureWord, particle

    /// Short, as dictionaries print it.
    package var label: String {
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

    /// Without an English tagger: the Mac's answers for the definitions where they differ from
    /// `guess` without one (scripts/parts-of-speech.sh), so both apps label every meaning alike.
    nonisolated(unsafe) package static var table: [String: PartOfSpeech?] = [:]

    /// Reads a table written by scripts/parts-of-speech.sh: definition, tab, part of speech or "-".
    package static func loadTable(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var t: [String: PartOfSpeech?] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard p.count == 2 else { continue }
            t[String(p[0])] = PartOfSpeech(rawValue: String(p[1]))
        }
        table = t
    }

    @MainActor package static func of(_ gloss: String) -> PartOfSpeech? {
        if let hit = known[gloss] { return hit }
        let found = Platform.englishTagger == nil ? (table[gloss] ?? guess(gloss)) : guess(gloss)
        known[gloss] = found
        return found
    }

    package static func guess(_ gloss: String) -> PartOfSpeech? {
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
        // scx as Apple's String.range(of:) reads \p{Han} (see CEDict.referenceTarget).
        guard !text.isEmpty, text.range(of: #"[\p{scx=Han}:]"#, options: .regularExpression) == nil else { return nil }
        if text.hasPrefix("to ") && !text.hasPrefix("to and ") { return .verb }
        let count = text.split(separator: " ").count
        guard count <= 4 else { return nil }
        if text.hasPrefix("a ") || text.hasPrefix("an ") || text.hasPrefix("the ") { return .noun }
        if adverbs.contains(text) { return .adverb }

        // Tagged in a sentence, where a word alone is a guess: "It is pretty." is an adjective.
        let frame = "It is "
        let sentence = frame + text + "."
        guard let tagger = Platform.englishTagger else { return nil }
        let tags = tagger.classes(in: sentence, from: sentence.index(sentence.startIndex, offsetBy: frame.count))
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
        let modifiers: Set<LexicalClass> = [.adjective, .adverb, .noun, .determiner, .number]
        guard tags.dropLast().allSatisfy(modifiers.contains) else { return nil }
        switch last {
        case .noun: return .noun
        case .adjective: return tags.dropLast().allSatisfy { $0 == .adverb } ? .adjective : nil
        case .adverb: return tags.dropLast().allSatisfy { $0 == .adverb } ? .adverb : nil
        default: return nil
        }
    }
}
