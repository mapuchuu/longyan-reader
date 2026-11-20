import Foundation

/// Hand-set meaning order for the commonest characters (Resources/sense-order.tsv). CC-CEDICT
/// lists 眼's "salient point" beside "eye" and 到's "considerate" beside "to arrive", and both
/// the model and the card take the list as it comes. Each line gives a character, how many
/// senses it had when the line was written, the everyday senses in order, then after "|" the
/// rare ones (classical, old units, divination…), which go last and aren't offered to the model.
/// Numbers are 1-based positions in the list `CEDict.senses` builds before this is applied.
struct SenseOrder {
    let count: Int
    let common: [Int]
    let rare: [Int]

    /// Common senses in the given order, then any the line doesn't mention, then the rare ones.
    /// A line written for a different list (the count doesn't match) is ignored.
    func apply(to senses: [Sense]) -> [Sense] {
        guard senses.count == count else { return senses }
        let named = Set(common + rare)
        var out = common.compactMap { senses[safe: $0 - 1] }
        out += senses.indices.filter { !named.contains($0 + 1) }.map { senses[$0] }
        out += rare.compactMap { senses[safe: $0 - 1] }.map { var s = $0; s.rare = true; return s }
        return out
    }

    /// `senses` in the order of `ordered` (another form's list, already ordered), matched by
    /// gloss: those it has as common first, then any it lacks, then those it has as rare.
    static func follow(_ ordered: [Sense], _ senses: [Sense]) -> [Sense] {
        var position: [String: (Int, Bool)] = [:]
        for (i, s) in ordered.enumerated() where position[s.gloss] == nil { position[s.gloss] = (i, s.rare) }
        func group(_ s: Sense) -> Int { position[s.gloss].map { $0.1 ? 2 : 0 } ?? 1 }
        return senses.enumerated().sorted { a, b in
            let (ga, gb) = (group(a.element), group(b.element))
            if ga != gb { return ga < gb }
            return (position[a.element.gloss]?.0 ?? a.offset) < (position[b.element.gloss]?.0 ?? b.offset)
        }.map { var s = $0.element; if group(s) == 2 { s.rare = true }; return s }
    }

    /// LONGYAN_NO_SENSE_ORDER=1 turns the file off, for before/after comparisons.
    static let enabled = ProcessInfo.processInfo.environment["LONGYAN_NO_SENSE_ORDER"] == nil

    static let shared = load("sense-order")

    /// Resources/sense-everyday.tsv: the meaning to show first when no model picks one, in the
    /// same format. It's kept apart from sense-order.tsv because the order of the list the model
    /// reads nudges its pick: moving 追's "to chase" up for everyone made 4B slightly worse.
    static let everyday = enabled ? load("sense-everyday") : [:]

    private static func load(_ name: String) -> [String: SenseOrder] {
        let url = Bundle.main.url(forResource: name, withExtension: "tsv")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/\(name).tsv")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: SenseOrder] {
        var out: [String: SenseOrder] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let count = Int(f[1]) else { continue }
            let halves = f[2].split(separator: "|", omittingEmptySubsequences: false)
            let numbers = { (s: Substring?) in (s ?? "").split(separator: " ").compactMap { Int($0) } }
            out[f[0]] = SenseOrder(count: count, common: numbers(halves.first), rare: numbers(halves.count > 1 ? halves[1] : nil))
        }
        return out
    }
}
