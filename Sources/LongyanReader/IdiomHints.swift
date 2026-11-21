import Foundation

/// EXPERIMENT (LONGYAN_HINTS=1): dictionary notes for the translator. Small models miss idioms and slang the
/// dictionary already explains (躺赢 "to win without lifting a finger", 炒冷饭 "to rehash the same story"), and
/// words whose meaning their characters don't give. For each word of the selection that the dictionary marks as an
/// idiom, slang or figurative, or that is outside the commonest words and whose meaning shares nothing with its
/// characters', this gives two short senses.
/// The model is told to use a note only if it fits, since 开夜车 can be meant literally.
enum IdiomHints {
    static let enabled = ProcessInfo.processInfo.environment["LONGYAN_HINTS"] == "1"

    private static let markers = ["(idiom)", "(fig.)", "(slang)", "(Internet slang)", "neologism", "(coll.)"]

    /// The 20,000 commonest words (jieba's counts, notes/frequency.txt): the model knows these.
    private static let common: Set<String> = {
        let path = FileManager.default.currentDirectoryPath + "/notes/frequency.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init))
    }()

    /// (word, gloss) for the selection's words worth a note, at most four.
    static func hints(for range: Range<Int>, in passage: [Character], dict: CEDict) -> [(String, String)] {
        var out: [(String, String)] = []
        for t in Segmenter.phrase(range, in: passage, dict: dict) where t.text.count >= 2 && out.count < 4 {
            let entries = dict.entries(for: t.text).filter { !$0.isProperNoun }
            let defs = entries.flatMap(\.definitions).filter { !CEDict.isCrossReference($0) && !($0.contains("|") && $0.contains("[")) }
            guard !defs.isEmpty else { continue }
            if t.text.allSatisfy({ "零一二三四五六七八九十百千万两萬兩".contains($0) }) { continue }
            let marked = defs.contains { d in d.hasPrefix("fig.") || markers.contains { d.contains($0) } }
            let special = marked || (!common.contains(dict.simplified(t.text)) && !compositional(t.text, defs, dict))
            if special, let g = gloss(defs) { out.append((t.text, g)) }
        }
        return out
    }

    static func hints(for text: String, dict: CEDict) -> [(String, String)] {
        let chars = Array(text); return hints(for: 0..<chars.count, in: chars, dict: dict)
    }

    /// The prompt line for 4B, or nil.
    static func note(for text: String, dict: CEDict?) -> String? {
        guard enabled, let dict, case let h = hints(for: text, dict: dict), !h.isEmpty else { return nil }
        return "Dictionary notes (use one only if it fits here): " + h.map { "\($0.0): \($0.1)" }.joined(separator: "; ")
    }

    /// Whether the word's meaning shares a content word with its characters' meanings (下周 "next week" from
    /// 下 "next" and 周 "week"); 吃醋 "to feel jealous" shares none with "eat" and "vinegar".
    static func compositional(_ word: String, _ defs: [String], _ dict: CEDict) -> Bool {
        let parts = Set(word.map { dict.entries(for: String($0)).flatMap(\.definitions) }.joined().flatMap(contentWords))
        return !Set(defs.flatMap(contentWords)).isDisjoint(with: parts)
    }

    private static let stop: Set<String> = ["the", "and", "for", "with", "one", "one's", "sth", "sb", "something", "someone",
        "used", "who", "that", "this", "from", "into", "out", "not", "have", "has", "make", "get", "take", "fig", "lit", "idiom", "etc"]
    private static func contentWords(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init).filter { $0.count >= 3 && !stop.contains($0) }.map(OutsideWords.stem)
    }

    /// Two senses, the figurative first if there is one, without their labels.
    static func gloss(_ defs: [String]) -> String? {
        let fig = defs.filter { $0.contains("fig.") }
        let picked = Array((fig + defs.filter { !fig.contains($0) && !$0.hasPrefix("lit.") && !$0.hasPrefix("(lit.)") }).prefix(2))
        let g = (picked.isEmpty ? Array(defs.prefix(1)) : picked).compactMap(clean).joined(separator: "; ")
        return g.isEmpty ? nil : g
    }

    private static func clean(_ d: String) -> String? {
        if d.contains("|") && d.contains("[") { return nil }   // a pointer to another entry, not a meaning
        var g = d
        g = g.replacingOccurrences(of: #"\((idiom|fig\.|slang|Internet slang|coll\.|used jokingly|dialect|lit\.|lit\. and fig\.|neologism[^)]*)\)\s*"#,
                                   with: "", options: .regularExpression)
        g = g.replacingOccurrences(of: #"^(fig\.|lit\.)\s*"#, with: "", options: .regularExpression)
        g = g.trimmingCharacters(in: .whitespaces)
        if g.count > 70, let cut = g.firstIndex(of: ";") { g = String(g[..<cut]) }
        return g.isEmpty ? nil : g
    }
}
