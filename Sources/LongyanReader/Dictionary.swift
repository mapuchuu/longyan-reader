import Foundation

/// One CC-CEDICT line: a headword with one reading and its senses.
struct DictEntry {
    let traditional: String
    let simplified: String
    let pinyin: String          // numbered, e.g. "xue2 sheng5"
    let definitions: [String]

    /// Proper nouns are written with capitalised pinyin in CC-CEDICT.
    var isProperNoun: Bool { pinyin.first?.isUppercase ?? false }
}

/// A single meaning offered to the reader (and to the sense chooser).
struct Sense: Equatable {
    let pinyin: String          // numbered
    let gloss: String
}

final class CEDict {
    private var byWord: [String: [DictEntry]] = [:]
    private(set) var maxWordLength = 1
    private(set) var entryCount = 0

    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        text.enumerateLines { line, _ in
            guard let entry = CEDict.parse(line) else { return }
            self.entryCount += 1
            self.add(entry, as: entry.simplified)
            if entry.traditional != entry.simplified { self.add(entry, as: entry.traditional) }
        }
    }

    private func add(_ entry: DictEntry, as key: String) {
        byWord[key, default: []].append(entry)
        maxWordLength = max(maxWordLength, key.count)
    }

    // "傳統 传统 [chuan2 tong3] /tradition/traditional/"
    static func parse(_ line: String) -> DictEntry? {
        guard !line.hasPrefix("#"),
              let firstSpace = line.firstIndex(of: " "),
              let open = line.firstIndex(of: "["),
              let close = line.firstIndex(of: "]"),
              open < close else { return nil }
        let trad = String(line[..<firstSpace])
        let simp = line[line.index(after: firstSpace)..<open].trimmingCharacters(in: .whitespaces)
        let pinyin = String(line[line.index(after: open)..<close])
        let defs = line[line.index(after: close)...]
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !simp.isEmpty, !defs.isEmpty else { return nil }
        return DictEntry(traditional: trad, simplified: simp, pinyin: pinyin, definitions: defs)
    }

    func entries(for word: String) -> [DictEntry] { byWord[word] ?? [] }
    func contains(_ word: String) -> Bool { byWord[word] != nil }

    /// Senses worth choosing between, common readings first. Cross-references
    /// ("variant of", "used in", classifiers, surnames) are dropped; proper
    /// nouns go last.
    /// A single character standing alone can't take a "(bound form)" sense:
    /// those only occur inside longer words (行 "row" lives in 行列, not 行不行).
    func senses(for word: String, limit: Int = 14) -> [Sense] {
        let entries = entries(for: word)
        let ordered = entries.filter { !$0.isProperNoun } + entries.filter { $0.isProperNoun }
        let standalone = word.count == 1
        var out: [Sense] = []
        for entry in ordered {
            for def in entry.definitions where !CEDict.isCrossReference(def) && !(standalone && def.hasPrefix("(bound form)")) {
                let sense = Sense(pinyin: entry.pinyin, gloss: def)
                if !out.contains(sense) { out.append(sense) }
            }
        }
        if out.isEmpty, let first = ordered.first {
            // Only cross-references exist. Show what they point to (干活儿 → 干活), under this
            // word's own reading; else show them rather than nothing.
            let target = first.definitions.lazy.compactMap { CEDict.referenceTarget($0) }.first { $0 != word }
            let followed = target.map { senses(for: $0, limit: limit) } ?? []
            out = followed.isEmpty ? first.definitions.map { Sense(pinyin: first.pinyin, gloss: $0) }
                                   : followed.map { Sense(pinyin: first.pinyin, gloss: $0.gloss) }
        }
        return Array(out.prefix(limit))
    }

    static func isCrossReference(_ def: String) -> Bool {
        let lower = def.lowercased()
        return ["variant of", "old variant", "unofficial variant", "erhua variant", "used in ", "see ", "cl:",
                "taiwan pr.", "surname "].contains { lower.hasPrefix($0) }
    }

    /// The simplified word a "variant of" or "see" definition points to:
    /// "erhua variant of 幹活|干活[gan4 huo2]" → 干活.
    static func referenceTarget(_ def: String) -> String? {
        let lower = def.lowercased()
        guard lower.contains("variant of ") || lower.hasPrefix("see ") else { return nil }
        guard let match = def.range(of: #"(\p{Han}+\|)?\p{Han}+"#, options: .regularExpression) else { return nil }
        return def[match].split(separator: "|").last.map(String.init)
    }

    static func load() throws -> CEDict {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "cedict_ts", withExtension: "u8"),
            ProcessInfo.processInfo.environment["LONGYAN_CEDICT"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/cedict_ts.u8"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try CEDict(contentsOf: url)
        }
        throw NSError(domain: "LongyanReader", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "cedict_ts.u8 not found; run scripts/fetch-cedict.sh"])
    }
}
