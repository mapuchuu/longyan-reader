import Foundation

/// CC-CEDICT (plus extra-words.u8) compiled into one file that's read straight from disk:
/// opening it takes about a millisecond and nothing is copied into memory, where parsing the
/// 9.8 MB text took ~1.4 s and ~85 MB. `scripts/build-app.sh` writes it with --compile-dict
/// and checks every word against the text; the text stays the source.
///
/// Layout (all numbers little-endian UInt32):
///   header   magic "LYD1", version, then the counts and section offsets below
///   keys     per headword (sorted by UTF-8 bytes): text offset, text length, first list slot, slots
///   lists    entry numbers, each headword's in dictionary order
///   entries  traditional, simplified and pinyin (offset, length each), first definition, count
///   defs     offset, length
///   text     UTF-8
struct DictionaryFile {
    static let magic: UInt32 = 0x3144594C   // "LYD1"
    static let version: UInt32 = 1
    private static let headerWords = 12

    private let data: NSData
    private let base: UnsafeRawPointer
    let keyCount: Int, entryCount: Int, maxWordLength: Int
    private let keys: Int, lists: Int, entries: Int, defs: Int, text: Int

    init(contentsOf url: URL) throws {
        let d = try NSData(contentsOf: url, options: .alwaysMapped)
        data = d; base = d.bytes
        guard d.length >= Self.headerWords * 4 else { throw Self.bad(url) }
        let h = { (i: Int) in Int(UInt32(littleEndian: d.bytes.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))) }
        guard h(0) == Self.magic, h(1) == Self.version else { throw Self.bad(url) }
        keyCount = h(2); entryCount = h(3); maxWordLength = h(4)
        keys = h(5); lists = h(6); entries = h(7); defs = h(8); text = h(9)
        guard text <= d.length else { throw Self.bad(url) }
    }

    private func u32(_ offset: Int) -> Int {
        Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }
    private func string(_ offset: Int, _ length: Int) -> String {
        String(decoding: UnsafeRawBufferPointer(start: base + text + offset, count: length), as: UTF8.self)
    }

    /// The headword's slot, by binary search on its UTF-8 bytes.
    private func find(_ word: String) -> Int? {
        var word = word
        return word.withUTF8 { w -> Int? in
            var lo = 0, hi = keyCount
            while lo < hi {
                let mid = (lo + hi) / 2
                let k = keys + mid * 16
                let len = u32(k + 4)
                var c = memcmp(base + text + u32(k), w.baseAddress!, min(len, w.count))
                if c == 0 { c = len < w.count ? -1 : len > w.count ? 1 : 0 }
                if c == 0 { return mid }
                if c < 0 { lo = mid + 1 } else { hi = mid }
            }
            return nil
        }
    }

    func contains(_ word: String) -> Bool { !word.isEmpty && find(word) != nil }

    func entries(for word: String) -> [DictEntry] {
        guard !word.isEmpty, let slot = find(word) else { return [] }
        let k = keys + slot * 16
        return (0..<u32(k + 12)).map { i in
            let e = entries + u32(lists + (u32(k + 8) + i) * 4) * 32
            let firstDef = u32(e + 24)
            return DictEntry(traditional: string(u32(e), u32(e + 4)), simplified: string(u32(e + 8), u32(e + 12)),
                             pinyin: string(u32(e + 16), u32(e + 20)),
                             definitions: (0..<u32(e + 28)).map { d in
                                 let p = defs + (firstDef + d) * 8
                                 return string(u32(p), u32(p + 4))
                             })
        }
    }

    /// Writes the compiled form of `byWord` (headword → entries in dictionary order). An entry
    /// filed under both its traditional and simplified forms is stored once.
    static func write(_ byWord: [String: [DictEntry]], entryCount: Int, maxWordLength: Int, to url: URL) throws {
        var blob = Data(), stringAt: [String: (Int, Int)] = [:]
        func put(_ s: String) -> (Int, Int) {
            if let at = stringAt[s] { return at }
            let at = (blob.count, s.utf8.count)
            blob.append(contentsOf: Array(s.utf8))
            stringAt[s] = at
            return at
        }
        var keyTable: [UInt32] = [], listTable: [UInt32] = [], entryTable: [UInt32] = [], defTable: [UInt32] = []
        var entryNumber: [String: Int] = [:]   // an entry's identity: its fields joined
        func number(_ e: DictEntry) -> Int {
            let id = [e.traditional, e.simplified, e.pinyin, e.definitions.joined(separator: "/")].joined(separator: "\u{1}")
            if let n = entryNumber[id] { return n }
            let n = entryTable.count / 8
            entryNumber[id] = n
            let t = put(e.traditional), s = put(e.simplified), p = put(e.pinyin)
            entryTable += [t.0, t.1, s.0, s.1, p.0, p.1, defTable.count / 2, e.definitions.count].map { UInt32($0) }
            for d in e.definitions { let at = put(d); defTable += [UInt32(at.0), UInt32(at.1)] }
            return n
        }
        let sorted = byWord.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        for key in sorted {
            let list = byWord[key]!
            let at = put(key)
            keyTable += [at.0, at.1, listTable.count, list.count].map { UInt32($0) }
            for e in list { listTable.append(UInt32(number(e))) }
        }
        var out = Data()
        func append(_ words: [UInt32]) { for w in words { withUnsafeBytes(of: w.littleEndian) { out.append(contentsOf: $0) } } }
        let keysAt = headerWords * 4
        let listsAt = keysAt + keyTable.count * 4
        let entriesAt = listsAt + listTable.count * 4
        let defsAt = entriesAt + entryTable.count * 4
        let textAt = defsAt + defTable.count * 4
        append([magic, version, UInt32(sorted.count), UInt32(entryCount), UInt32(maxWordLength),
                UInt32(keysAt), UInt32(listsAt), UInt32(entriesAt), UInt32(defsAt), UInt32(textAt), 0, 0])
        append(keyTable); append(listTable); append(entryTable); append(defTable)
        out.append(blob)
        try out.write(to: url, options: .atomic)
    }

    private static func bad(_ url: URL) -> NSError {
        NSError(domain: "LongyanReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't a dictionary file this build can read"])
    }
}
