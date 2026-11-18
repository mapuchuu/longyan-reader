import Foundation

/// English words a fragment's translation mustn't use: the dictionary glosses of the
/// sentence's words outside the fragment that no word or character in it shares. Kept out
/// while decoding (EmbeddedModel.generate), they stop the 4B model finishing the clause
/// with words from outside the selection (卷了，我想 "…I want to lie flat").
enum OutsideWords {
    /// The kept-out words (`banned`), and every gloss word of the outside words (common ones too, stemmed): a
    /// reply cut short at a kept-out word drops these from its end, the "get" of 结婚's
    /// "get married" in 催我早点 "urged me to get".
    static func lists(part: String, context: String, dict: CEDict) -> (banned: [String], outside: Set<String>) {
        let sentence = Array(context), fragment = Array(part)
        guard let lo = start(of: fragment, in: sentence) else { return ([], []) }
        let r = lo..<(lo + fragment.count)
        var inside = Set<String>()
        for t in Segmenter.phrase(r, in: sentence, dict: dict) { inside.formUnion(glossWords(t.text, dict)) }
        for c in fragment where isCJK(c) { inside.formUnion(glossWords(String(c), dict)) }
        var out = Set<String>()
        // Words of two or more characters only: a single character's glosses are too many and
        // too common (想 "to want", 还 "still") to keep out.
        for t in Segmenter.phrase(0..<sentence.count, in: sentence, dict: dict)
        where t.text.count >= 2 && t.text.allSatisfy(isCJK) && (t.range.upperBound <= r.lowerBound || t.range.lowerBound >= r.upperBound) {
            out.formUnion(glossWords(t.text, dict))
        }
        let own = out.subtracting(inside)
        return (own.filter { $0.count >= 3 && !common.contains($0) }.sorted(), Set(own.map(stem)))
    }

    /// Function words and verbs too general to belong to one Chinese word.
    private static let common: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "that", "this", "one", "sth", "someone", "something",
        "have", "has", "get", "make", "take", "come", "goes", "use", "put", "give", "let", "can", "may", "will", "not",
        "very", "also", "too", "all", "out", "off", "over", "back", "who", "what", "which", "abbr", "fig", "lit",
        "etc", "esp", "used", "being", "person", "thing", "things", "people", "way", "kind",
    ]

    fileprivate static func glossWords(_ word: String, _ dict: CEDict) -> Set<String> {
        var out = Set<String>()
        for s in dict.senses(for: word) {
            // "(fig.)", "(esp. in a race)": asides, not the sense.
            let gloss = s.gloss.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
            for w in gloss.lowercased().split(whereSeparator: { !$0.isLetter }) { out.insert(String(w)) }
        }
        return out
    }

    /// The fragment's place in the sentence; nil when it isn't there or is there twice.
    private static func start(of part: [Character], in s: [Character]) -> Int? {
        guard !part.isEmpty, part.count <= s.count else { return nil }
        let hits = (0...(s.count - part.count)).filter { Array(s[$0..<($0 + part.count)]) == part }
        return hits.count == 1 ? hits[0] : nil
    }
}

extension OutsideWords {
    /// Whether an English reply already says every word of two or more characters in the
    /// fragment (any word, when it has none), by their glosses: 他每天 "He" doesn't yet
    /// (每天 "every day" is still to come), 东西又便宜 "the items are both cheap and" does.
    static func coverage(part: String, dict: CEDict) -> @Sendable (String) -> Bool {
        let fragment = Array(part)
        let words = Segmenter.phrase(0..<fragment.count, in: fragment, dict: dict).filter { $0.text.allSatisfy(isCJK) }
        let long = words.filter { $0.text.count >= 2 }
        let needed = (long.isEmpty ? words : long).map { Set(glossWords($0.text, dict).map(stem)) }.filter { !$0.isEmpty }
        let anyOne = long.isEmpty
        return { english in
            let said = Set(english.lowercased().split(whereSeparator: { !$0.isLetter }).map { stem(String($0)) })
            guard !needed.isEmpty else { return !said.isEmpty }
            return anyOne ? needed.contains { !$0.isDisjoint(with: said) } : needed.allSatisfy { !$0.isDisjoint(with: said) }
        }
    }

    static func stem(_ w: String) -> String {
        for end in ["ing", "ed", "es", "s"] where w.count > end.count + 2 && w.hasSuffix(end) { return String(w.dropLast(end.count)) }
        return w
    }
}
