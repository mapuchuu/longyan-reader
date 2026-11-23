import Foundation

/// A card built from a saved card JSON (windows/gallery/*.json, as the bridge sends cards), for
/// filming the Mac and Windows cards side by side without the model: `LongyanReader --show` on
/// both. The dictionary gives the senses and the rows, as on a real card; the JSON gives what the
/// model said (the chosen meaning and its wording, the translation). A card built this way never
/// asks the model: every row that would has its answer already, or stays in its loading state.
@MainActor
package enum CardFixture {
    package enum Built {
        case word(LookupState)
        case phrase(PhraseState)
    }

    /// The card for `json`, and what in it didn't match the dictionary (so the film may not
    /// show what the JSON says).
    package static func build(_ json: [String: Any], dict: CEDict) -> (card: Built, warnings: [String])? {
        switch json["kind"] as? String {
        case "word": return word(json, dict: dict)
        case "phrase": return phrase(json, dict: dict)
        default: return nil
        }
    }

    /// The card "Part of" opens from a built word card: the whole word, still reading the
    /// sentence, as no model will pick its meaning.
    package static func loading(_ word: String, dict: CEDict) -> LookupState {
        let passage = Array(word)
        return LookupState(context: WordInContext(word: word, passage: passage, wordRange: 0..<passage.count, alternatives: []),
                           senses: dict.senses(for: word), phase: .choosing)
    }

    private static func word(_ json: [String: Any], dict: CEDict) -> (card: Built, warnings: [String])? {
        guard let word = json["word"] as? String, !word.isEmpty else { return nil }
        var warnings: [String] = []
        let passage = Array(word)
        let context = WordInContext(word: word, passage: passage, wordRange: 0..<passage.count,
                                    alternatives: json["alternatives"] as? [String] ?? [])
        let senses = dict.senses(for: word)
        let state = LookupState(context: context, senses: senses, phase: .choosing)
        let rows = json["senses"] as? [[String: Any]] ?? []
        for row in rows {
            guard let i = row["index"] as? Int, let gloss = row["gloss"] as? String else { continue }
            guard let sense = senses[safe: i] else { warnings.append("sense \(i + 1) isn't in the dictionary"); continue }
            if gloss != Gloss.listed(sense.gloss) && gloss != Gloss.short(sense.gloss) {
                warnings.append("sense \(i + 1): the JSON says \"\(gloss)\", the dictionary \"\(Gloss.listed(sense.gloss))\"")
            }
        }
        let status = json["status"] as? String
        if state.grammar == nil {
            if let meaning = json["meaning"] as? String,
               let chosen = rows.first(where: { $0["chosen"] as? Bool == true })?["index"] as? Int, senses.indices.contains(chosen) {
                state.receive(SenseChoice(senseNumber: chosen + 1, meaningHere: meaning,
                                          viaTranslation: status == "Picked to match the translation"))
            } else if status == "Not in the dictionary" {
                state.phase = .dictionaryOnly(Gloss.notInDictionary)
            } else if let why = status?.components(separatedBy: "Dictionary order · ").dropFirst().first {
                state.phase = .dictionaryOnly(why)
            }
            // Otherwise "Reading the sentence…": it stays so, as no model will answer.
        }
        if json["back"] != nil { warnings.append("\"back\" (a meaning the reader picked) isn't built; the card shows the model's") }
        if let part = json["partOf"] as? [String: Any], let whole = part["word"] as? String {
            let marked = part["pinyin"] as? String ?? ""
            let wholeSenses = dict.senses(for: whole)
            let pinyin = wholeSenses.first(where: { Pinyin.marked($0.pinyin) == marked })?.pinyin ?? wholeSenses.first?.pinyin ?? ""
            state.partOf = .init(word: whole, pinyin: pinyin, meaning: part["meaning"] as? String)
        }
        if json["more"] as? String == "Show Fewer" { state.showAllSenses = true }
        return (.word(state), warnings)
    }

    private static func phrase(_ json: [String: Any], dict: CEDict) -> (card: Built, warnings: [String])? {
        guard let text = json["text"] as? String, !text.isEmpty else { return nil }
        var warnings: [String] = []
        let passage = Array(text)
        let selection = Selection(passage: passage, range: 0..<passage.count, bounds: nil, source: .accessibility, appName: nil)
        let state = PhraseState(selection: selection, dict: dict)
        if let t = json["translation"] as? String { state.translation = t }
        else if let e = json["translationError"] as? String { state.translationError = e.components(separatedBy: "No translation · ").last ?? e }
        let rows = json["rows"] as? [[String: Any]] ?? []
        if rows.map({ $0["text"] as? String ?? "" }) != Array(state.tokens.prefix(rows.count).map(\.text)) {
            warnings.append("the rows are \(rows.compactMap { $0["text"] as? String }), the dictionary splits \(state.tokens.map(\.text))")
        }
        var picks: [Int: SenseChoice] = [:]
        var pending = false
        for row in rows {
            guard let id = row["token"] as? Int, let token = state.tokens.first(where: { $0.id == id }),
                  token.text == row["text"] as? String else { continue }
            let list = state.senses[id] ?? []
            if row["pending"] as? Bool == true { pending = true; continue }
            guard !list.isEmpty, state.grammarEntry(token) == nil else { continue }
            let status = row["status"] as? String
            if let status, status.hasPrefix("Dictionary order") { state.failures[id] = status; continue }
            // The sense the row shows: the open row's chosen one, else the one whose gloss it shows.
            let detail = row["senses"] as? [[String: Any]]
            let gloss = row["gloss"] as? String ?? ""
            let index = detail?.first(where: { $0["chosen"] as? Bool == true })?["index"] as? Int
                ?? list.indices.first(where: { shortGloss([list[$0]]) == gloss })
                ?? state.shownSense(token) ?? 0
            if shortGloss([list[safe: index] ?? list[0]]) != gloss {
                warnings.append("row \(token.text): the JSON says \"\(gloss)\", the dictionary \"\(shortGloss([list[safe: index] ?? list[0]]))\"")
            }
            // The model's own wording shows in the open row only when it adds to the gloss ("here").
            let wording = row["here"] as? String ?? headlineGloss(list[safe: index] ?? list[0])
            picks[id] = SenseChoice(senseNumber: index + 1, meaningHere: wording, viaTranslation: status == "Picked to match the translation")
            if row["more"] as? String == "Show Fewer" { state.showingAll.insert(id) }
            if row["back"] != nil { warnings.append("row \(token.text): \"back\" isn't built") }
        }
        state.apply(picks)
        // Rows still being read stay so: no model will answer them.
        if pending { state.resolving = true }
        if let open = rows.first(where: { $0["open"] as? Bool == true })?["token"] as? Int { state.expanded = open }
        return (.phrase(state), warnings)
    }
}
