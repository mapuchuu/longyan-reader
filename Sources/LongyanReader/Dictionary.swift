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
extension Array where Element == Sense {
    /// Which meanings a list shows before "Show more": the chosen one, the first of each
    /// reading (干 is both "dry" and "to do"), then the rest in order. In dictionary order.
    func preview(chosen: Int?, limit: Int = 5) -> [Int] {
        var picked: [Int] = []
        if let chosen, indices.contains(chosen) { picked.append(chosen) }
        var readings = Set(picked.map { self[$0].pinyin })
        for i in indices where picked.count < limit && readings.insert(self[i].pinyin).inserted { picked.append(i) }
        for i in indices where picked.count < limit && !picked.contains(i) { picked.append(i) }
        return picked.sorted()
    }
}

struct Sense: Equatable {
    let pinyin: String          // numbered
    let gloss: String
    /// Too rare in modern prose to offer the model (sense-order.tsv); still listed on the card.
    var rare = false

    static func == (a: Sense, b: Sense) -> Bool { a.pinyin == b.pinyin && a.gloss == b.gloss }
}

extension Array where Element == Sense {
    /// The senses a model chooses between: the rare ones (always last) are left out, and the
    /// list is capped to keep the prompt short. Numbering matches the full list.
    var forModel: [Sense] {
        let common = prefix { !$0.rare }
        return Array((common.isEmpty ? self[...] : common).prefix(CEDict.modelSenseLimit))
    }
}

final class CEDict {
    /// Parsed from the text (the CLI run from the repo, and --compile-dict), or the compiled
    /// file the app ships (DictionaryFile), which opens in ~1 ms instead of ~1.4 s.
    private var byWord: [String: [DictEntry]] = [:]
    private var file: DictionaryFile?
    private(set) var maxWordLength = 1
    private(set) var entryCount = 0

    init(compiled url: URL) throws {
        let f = try DictionaryFile(contentsOf: url)
        file = f; maxWordLength = f.maxWordLength; entryCount = f.entryCount
    }

    /// Writes the compiled file, then reopens it and checks every headword reads back the same.
    func compile(to url: URL) throws -> Int {
        try DictionaryFile.write(byWord, entryCount: entryCount, maxWordLength: maxWordLength, to: url)
        let back = try CEDict(compiled: url)
        func same(_ a: [DictEntry], _ b: [DictEntry]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy {
                $0.traditional == $1.traditional && $0.simplified == $1.simplified && $0.pinyin == $1.pinyin && $0.definitions == $1.definitions
            }
        }
        let mismatched = byWord.filter { !same($0.value, back.entries(for: $0.key)) }.map(\.key)
        guard mismatched.isEmpty, back.maxWordLength == maxWordLength, back.entryCount == entryCount,
              !back.contains("龘龘龘") else {
            throw NSError(domain: "LongyanReader", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "compiled dictionary doesn't match the text: \(mismatched.prefix(5))"])
        }
        return byWord.count
    }

    init(contentsOf url: URL) throws {
        addLines(try String(contentsOf: url, encoding: .utf8))
        // Words CC-CEDICT lacks (extra-words.u8, beside it), unless LONGYAN_NO_EXTRA_WORDS=1 for comparisons.
        if ProcessInfo.processInfo.environment["LONGYAN_NO_EXTRA_WORDS"] == nil,
           let text = try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("extra-words.u8"), encoding: .utf8) {
            addLines(text)
        }
    }

    private func addLines(_ text: String) {
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

    func entries(for word: String) -> [DictEntry] { file?.entries(for: word) ?? byWord[word] ?? [] }
    func contains(_ word: String) -> Bool { file?.contains(word) ?? (byWord[word] != nil) }

    /// Senses worth choosing between, common readings first. Cross-references
    /// ("variant of", "used in", classifiers, surnames) are dropped; proper
    /// nouns go last.
    /// Within that, senses that are rarely what's meant in running text go after the rest.
    /// That includes a single character's "(bound form)" senses (行 "row" lives in 行列, not
    /// 行不行), which still have to be on offer: words the dictionary lacks get split, and
    /// 薪 in 无薪 is "salary", a bound form, not the free-standing "firewood".
    /// `handOrdered: false` skips sense-order.tsv (to check its lines against the dictionary).
    func senses(for word: String, limit: Int = .max, handOrdered: Bool = true) -> [Sense] {
        let entries = entries(for: word)
        let ordered = entries.filter { !$0.isProperNoun } + entries.filter { $0.isProperNoun }
        let standalone = word.count == 1
        var out: [Sense] = []
        for entry in ordered {
            for def in entry.definitions where !CEDict.isCrossReference(def) && !CEDict.isDatingLabel(def) {
                let sense = Sense(pinyin: entry.pinyin, gloss: def)
                if !out.contains(sense) { out.append(sense) }
            }
        }
        func rank(_ s: Sense) -> Int {
            if CEDict.rareMarkers.contains(where: { s.gloss.hasPrefix($0) }) { return 2 }
            return standalone && s.gloss.hasPrefix("(bound form)") ? 1 : 0
        }
        out = [0, 1, 2].flatMap { r in out.filter { rank($0) == r } }
        if handOrdered, SenseOrder.enabled {
            if let order = SenseOrder.shared[word] { out = order.apply(to: out) }
            else if case let s = simplified(word), s != word, let order = SenseOrder.shared[s] {
                // A traditional form has its own sense list (別 8, 别 9): the simplified line's
                // numbers don't fit it, so its senses take their order from their glosses there.
                out = SenseOrder.follow(order.apply(to: senses(for: s, handOrdered: false)), out)
            }
        }
        if out.isEmpty, let first = ordered.first {
            // Only cross-references exist. Show what they point to (干活儿 → 干活), under this
            // word's own reading; else show them rather than nothing.
            let target = first.definitions.lazy.compactMap { CEDict.referenceTarget($0) }.first { $0 != word }
            let followed = target.map { senses(for: $0, limit: limit) } ?? []
            out = followed.isEmpty ? first.definitions.map { Sense(pinyin: first.pinyin, gloss: $0) }
                                   : followed.reduce(into: []) { out, s in   // two readings can share a gloss (冡)
                                         let sense = Sense(pinyin: first.pinyin, gloss: s.gloss)
                                         if !out.contains(sense) { out.append(sense) }
                                     }
        }
        return Array(out.prefix(limit))
    }

    /// Where in `list` (this word's `senses(for:)`) the everyday meaning is, to show first when
    /// no model picks: from sense-everyday.tsv, else 0. A traditional form uses its simplified
    /// form's line, matched by gloss.
    func everydayIndex(for word: String, in list: [Sense]) -> Int {
        let s = simplified(word)
        guard let (form, order) = SenseOrder.everyday[word].map({ (word, $0) }) ?? SenseOrder.everyday[s].map({ (s, $0) }),
              let first = order.apply(to: senses(for: form, handOrdered: false)).first else { return 0 }
        return list.firstIndex { $0.gloss == first.gloss && (form != word || $0.pinyin == first.pinyin) } ?? 0
    }

    /// How many senses a model chooses between, to keep its prompt short. Common senses sort first.
    static let modelSenseLimit = 14

    private static let rareMarkers = ["(literary)", "(old)", "(archaic)", "(classical)", "(dialect)", "(Internet slang)", "(Tw)"]

    /// A "definition" that only dates the word, "(neologism c. 2016)" after 吃瓜群众's real
    /// meanings: not a meaning, so never offered or picked as one.
    static func isDatingLabel(_ def: String) -> Bool {
        def.range(of: #"^\((neologism|attested)[^()]*\)$"#, options: .regularExpression) != nil
    }

    static func isCrossReference(_ def: String) -> Bool {
        let lower = def.lowercased()
        return ["variant of", "old variant", "unofficial variant", "erhua variant", "used in ", "see ", "cl:",
                "taiwan pr.", "surname ", "also pr.", "also written", "same as "].contains { lower.hasPrefix($0) }
    }

    /// The simplified word a "variant of" or "see" definition points to:
    /// "erhua variant of 幹活|干活[gan4 huo2]" → 干活.
    static func referenceTarget(_ def: String) -> String? {
        let lower = def.lowercased()
        guard lower.contains("variant of ") || lower.hasPrefix("see ") || lower.hasPrefix("same as ") else { return nil }
        guard let match = def.range(of: #"(\p{Han}+\|)?\p{Han}+"#, options: .regularExpression) else { return nil }
        return def[match].split(separator: "|").last.map(String.init)
    }

    /// The app's compiled copy when there is one (and extra words aren't switched off for a
    /// comparison), else the text: the bundle's, LONGYAN_CEDICT, or Resources/ in the repo.
    /// The last dictionary loaded, for lookups that only have a word (notes keyed by simplified form).
    /// Set once, on the queue that loads the dictionary; read from any thread.
    static var current: CEDict? {
        get { currentLock.withLock { _current } }
        set { currentLock.withLock { _current = newValue } }
    }
    private static let currentLock = NSLock()
    nonisolated(unsafe) private static var _current: CEDict?

    /// 關係 → 关系: notes, examples and sense orders are keyed by the simplified headword.
    func simplified(_ word: String) -> String {
        entries(for: word).first { $0.traditional == word && $0.simplified != word }?.simplified ?? word
    }

    static func load() throws -> CEDict {
        let d = try loadDictionary()
        current = d
        return d
    }

    private static func loadDictionary() throws -> CEDict {
        if ProcessInfo.processInfo.environment["LONGYAN_NO_EXTRA_WORDS"] == nil,
           ProcessInfo.processInfo.environment["LONGYAN_CEDICT"] == nil,
           let url = Bundle.main.url(forResource: "cedict", withExtension: "bin") {
            return try CEDict(compiled: url)
        }
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
