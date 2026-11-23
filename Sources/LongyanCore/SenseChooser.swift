import Foundation

package enum NuanceTag: String, CaseIterable {
    case none
    case lostInTranslation
    case culturalContext
}

package struct SenseChoice {
    package var senseNumber: Int
    package var meaningHere: String
    package var tag: NuanceTag = .none
    package var note: String = ""
    /// True when the model refused and the sense was matched to a translation instead.
    package var viaTranslation = false

    package init(senseNumber: Int, meaningHere: String, tag: NuanceTag = .none, note: String = "", viaTranslation: Bool = false) {
        self.senseNumber = senseNumber; self.meaningHere = meaningHere; self.tag = tag; self.note = note
        self.viaTranslation = viaTranslation
    }
}

/// Chooses which dictionary sense fits the passage: the reading model, else the system's own
/// model when there is one (`Platform.sensePicker`, Apple's on-device model on the Mac).
/// The model never writes definitions; it picks from the numbered list.
package enum SenseChooser {
    /// Whether the system's model can pick (Apple's needs macOS 26; below that only the local model picks).
    static var isAvailable: Bool { Platform.sensePicker?.isAvailable ?? false }

    /// Whether any sense picker can run: the local model (as last checked) or Apple's. Cards
    /// and phrase picks gate on this; gating on Apple's model alone left Macs without Apple
    /// Intelligence on dictionary order even with the local model running.
    package static var canChoose: Bool { LocalModel.lastKnownAvailable || isAvailable }

    /// Why no sense picker can run, for the card's dictionary-order line.
    package static var noPickerReason: String {
        if let why = LocalModel.problem?.reason { return why }
        return LocalModel.enabled ? "download the reading model to pick the meaning here" : "Apple's model: \(unavailableReason)"
    }

    package static var unavailableReason: String { Platform.sensePicker?.unavailableReason ?? "not on this system" }

    // Kept short: longer instructions made the on-device model refuse ordinary sentences.
    // The model only picks a sense; notes from a 3B model were confidently wrong, so it
    // writes none (good notes need to be written ahead of time by a stronger model).
    package static let instructions = """
    You help an English speaker read Chinese. You get a Chinese passage with one word marked 【like this】 and that word's numbered dictionary senses. \
    Say what the marked word alone means here, then pick the matching sense. Never invent a sense.
    """

    /// No pinyin in the prompt: repeated syllables like "kuan1 rong2" (or tone-marked ü)
    /// make the on-device model reject the whole prompt as an unsupported language.
    /// The English glosses are enough to tell the senses apart; the card shows pinyin itself.
    package static func prompt(_ passage: String, word: String, senses: [Sense]) -> String {
        let list = senses.enumerated().map { i, s in "\(i + 1). \(s.gloss)" }
        return """
        Passage: \(passage)
        Marked word: \(word)
        Senses:
        \(list.joined(separator: "\n"))
        """
    }

    /// The on-device model sometimes rejects ordinary text (a false "unsupported language"
    /// or a guardrail violation). Retry with just the sentence; if it still refuses,
    /// translate the sentence on-device and take the sense that matches the translation.
    package static func choose(for context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        if let n = NoteCues.senseNumber(context.word, at: context.wordRange, in: context.passage, senses: senses) {
            return SenseChoice(senseNumber: n, meaningHere: headlineGloss(senses[n - 1]))
        }
        let senses = senses.forModel
        return cleaned(try await chooseRaw(for: context, senses: senses), senses: senses)
    }

    /// The model's "meaning here" line is meant to be a few English words for the word
    /// itself. Models sometimes answer in Chinese (退休金 → "退休金") or describe the
    /// whole sentence; both read wrong on the card, so fall back to the chosen sense's gloss.
    static func cleaned(_ choice: SenseChoice, senses: [Sense]) -> SenseChoice {
        var c = choice
        let meaning = c.meaningHere.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let wordCount = meaning.split(whereSeparator: { $0 == " " || $0 == "/" }).count
        // Over six words, or long enough to have hit the output cap (and been cut off), is
        // a definition or a sentence rather than a gloss.
        if meaning.isEmpty || meaning.contains(where: isCJK) || wordCount > 6 || meaning.count >= 45,
           let sense = senses[safe: c.senseNumber - 1] {
            c.meaningHere = headlineGloss(sense)
        } else {
            c.meaningHere = meaning
        }
        return c
    }

    private static func chooseRaw(for context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        // A stronger local model (Ollama), when running, picks on its own: on the held-out
        // note test Qwen3.5 9B alone got 51/52 with no wrong notes, and the tie-break rules
        // (built around the 3B model's habits) pulled it down to 39/52. LONGYAN_TIEBREAK=1
        // re-applies them for comparison.
        if await LocalModel.isAvailable() {
            do {
                let choice = try await LocalModel.choose(context, senses: senses)
                if ProcessInfo.processInfo.environment["LONGYAN_TIEBREAK"] == "1", let picker = Platform.sensePicker {
                    return await picker.reconsider(choice, context: context, senses: senses)
                }
                return choice
            } catch let e as NoSenseFits {
                throw e   // the model read the sentence and nothing fit: don't guess another way
            } catch {}    // not answering: fall back below
        }
        var lastError: Error?
        // LONGYAN_SKIP_MODEL=1 exercises the translation fallback in tests.
        let passages = ProcessInfo.processInfo.environment["LONGYAN_SKIP_MODEL"] == "1"
            ? [] : [context.markedPassage, context.markedSentence]
        // Apple's model may be off (the local model was expected but stopped answering): go
        // straight to matching the translation.
        for passage in passages where isAvailable {
            guard let picker = Platform.sensePicker else { break }
            do {
                let choice = try await picker.choose(passage: passage, word: context.word, senses: senses)
                return await picker.reconsider(choice, context: context, senses: senses)
            } catch {
                lastError = error
            }
        }
        if let translation = try? await Translator.translate(context.sentence),
           let i = senseMatching(translation: translation, senses: senses, word: context.word) {
            return SenseChoice(senseNumber: i + 1, meaningHere: shortGloss([senses[i]]), viaTranslation: true)
        }
        throw lastError ?? NSError(domain: "LongyanReader", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "no sense matched the translation"])
    }

    /// The model's short meaningHere is usually better than its sense number
    /// (校长: "school principal" but sense "president"). If the chosen sense shares
    /// no word with meaningHere and exactly one other sense does, take that one.
    package static func agreeingSense(_ choice: SenseChoice, senses: [Sense]) -> Int {
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
    /// On a tie, a sense with a prewritten note wins, so its note gets shown.
    package static func senseMatching(translation: String, senses: [Sense], word: String? = nil) -> Int? {
        let scores = overlapScores(translation: translation, senses: senses)
        guard let best = scores.max(), best > 0 else { return nil }
        let tied = scores.indices.filter { scores[$0] == best }
        if let word, let noted = tied.first(where: { NotesStore.note(word, senses[$0]) != nil }) { return noted }
        return tied.first
    }

    package static func overlapScores(translation: String, senses: [Sense]) -> [Int] {
        let words = glossWords(translation)
        return senses.map { sense in
            glossWords(sense.gloss).filter { g in words.contains { w in w == g || (min(w.count, g.count) >= 4 && (w.hasPrefix(g) || g.hasPrefix(w))) } }.count
        }
    }

    package static func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["LONGYAN_TRACE"] == "1" { print("    · " + s) }
    }
}
