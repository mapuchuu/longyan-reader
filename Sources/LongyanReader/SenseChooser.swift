import Foundation
import FoundationModels

enum NuanceTag: String, CaseIterable {
    case none
    case lostInTranslation
    case culturalContext
}

struct SenseChoice {
    var senseNumber: Int
    var meaningHere: String
    var tag: NuanceTag = .none
    var note: String = ""
    /// True when the model refused and the sense was matched to a translation instead.
    var viaTranslation = false
}

/// Chooses which dictionary sense fits the passage, using Apple's on-device model.
/// The model never writes definitions; it picks from the numbered list.
enum SenseChooser {
    static var availability: SystemLanguageModel.Availability { SystemLanguageModel.default.availability }

    static var isAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    static var unavailableReason: String {
        switch availability {
        case .available: return "available"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
        case .unavailable(.modelNotReady): return "model still downloading"
        case .unavailable(.deviceNotEligible): return "this Mac can't run it"
        case .unavailable(let other): return "unavailable (\(other))"
        }
    }

    // Kept short: longer instructions made the on-device model refuse ordinary sentences.
    // The model only picks a sense; notes from a 3B model were confidently wrong, so it
    // writes none (good notes need to be written ahead of time by a stronger model).
    static let instructions = """
    You help an English speaker read Chinese. You get a Chinese passage with one word marked 【like this】 and that word's numbered dictionary senses. \
    Say what the marked word alone means here, then pick the matching sense. Never invent a sense.
    """

    /// No pinyin in the prompt: repeated syllables like "kuan1 rong2" (or tone-marked ü)
    /// make the on-device model reject the whole prompt as an unsupported language.
    /// The English glosses are enough to tell the senses apart; the card shows pinyin itself.
    static func prompt(_ passage: String, word: String, senses: [Sense]) -> String {
        let list = senses.enumerated().map { i, s in "\(i + 1). \(s.gloss)" }
        return """
        Passage: \(passage)
        Marked word: \(word)
        Senses:
        \(list.joined(separator: "\n"))
        """
    }

    /// The output schema, built at runtime. (The @Generable macro needs full Xcode;
    /// this works with just the Command Line Tools.)
    static func schema(senseCount: Int, withNuance: Bool = true) throws -> GenerationSchema {
        typealias S = DynamicGenerationSchema
        let root = S(name: "SenseChoice", properties: [
            S.Property(name: "meaningHere",
                       description: "English for the marked word alone as used in this passage, 1 to 5 words. Not a translation of the sentence.",
                       schema: S(type: String.self)),
            S.Property(name: "senseNumber",
                       description: "The sense that matches meaningHere.",
                       schema: S(type: Int.self, guides: [.range(1...max(senseCount, 1))])),
        ] + (!withNuance ? [] : [
            S.Property(name: "tag",
                       description: "none for most words. lostInTranslation if no English word carries the meaning or register it has here. culturalContext if it needs knowledge specific to Chinese history, politics, society or culture.",
                       schema: S(name: "NuanceTag", anyOf: NuanceTag.allCases.map(\.rawValue))),
            S.Property(name: "note",
                       description: "Empty when tag is none. Otherwise one or two short sentences.",
                       schema: S(type: String.self)),
        ]))
        return try GenerationSchema(root: root, dependencies: [])
    }

    /// The on-device model sometimes rejects a prompt (a false "unsupported language"
    /// or "sensitive content"), so retry with less: the sentence alone, then no nuance fields.
    /// The on-device model sometimes rejects ordinary text (a false "unsupported language"
    /// or a guardrail violation). Retry with just the sentence; if it still refuses,
    /// translate the sentence on-device and take the sense that matches the translation.
    static func choose(for context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        var lastError: Error?
        // LONGYAN_SKIP_MODEL=1 exercises the translation fallback in tests.
        let passages = ProcessInfo.processInfo.environment["LONGYAN_SKIP_MODEL"] == "1"
            ? [] : [context.markedPassage, context.markedSentence]
        for passage in passages {
            do {
                let choice = try await respond(prompt(passage, word: context.word, senses: senses), senses: senses, nuance: false)
                return await preferNoted(choice, context: context, senses: senses)
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

    private static func respond(_ prompt: String, senses: [Sense], nuance: Bool) async throws -> SenseChoice {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            schema: try schema(senseCount: senses.count, withNuance: nuance),
            options: GenerationOptions(sampling: .greedy)
        )
        let content = response.content
        var choice = SenseChoice(
            senseNumber: try content.value(Int.self, forProperty: "senseNumber"),
            meaningHere: try content.value(String.self, forProperty: "meaningHere"),
            tag: nuance ? NuanceTag(rawValue: (try? content.value(String.self, forProperty: "tag")) ?? "") ?? .none : .none,
            note: nuance ? (try? content.value(String.self, forProperty: "note")) ?? "" : ""
        )
        choice.senseNumber = min(max(choice.senseNumber, 1), max(senses.count, 1))
        choice.senseNumber = agreeingSense(choice, senses: senses)
        if choice.tag == .none { choice.note = "" }
        return choice
    }

    /// The model's short meaningHere is usually better than its sense number
    /// (校长: "school principal" but sense "president"). If the chosen sense shares
    /// no word with meaningHere and exactly one other sense does, take that one.
    static func agreeingSense(_ choice: SenseChoice, senses: [Sense]) -> Int {
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
    static func senseMatching(translation: String, senses: [Sense], word: String? = nil) -> Int? {
        let scores = overlapScores(translation: translation, senses: senses)
        guard let best = scores.max(), best > 0 else { return nil }
        let tied = scores.indices.filter { scores[$0] == best }
        if let word, let noted = tied.first(where: { NotesStore.note(word, senses[$0]) != nil }) { return noted }
        return tied.first
    }

    static func overlapScores(translation: String, senses: [Sense]) -> [Int] {
        let words = glossWords(translation)
        return senses.map { sense in
            glossWords(sense.gloss).filter { g in words.contains { w in w == g || (min(w.count, g.count) >= 4 && (w.hasPrefix(g) || g.hasPrefix(w))) } }.count
        }
    }

    /// The 3B model tends to pick the plainest sense (关系 "relationship" in 他靠关系找到了工作).
    /// When a sense with a prewritten note fits the sentence's translation at least as well
    /// as the model's pick, show that sense, so its note appears.
    static func preferNoted(_ choice: SenseChoice, context: WordInContext, senses: [Sense]) async -> SenseChoice {
        let chosen = choice.senseNumber - 1
        let noted = senses.indices.filter { $0 != chosen && NotesStore.hasExactNote(context.word, senses[$0]) }
        let chosenHasNote = NotesStore.hasExactNote(context.word, senses[chosen])
        guard !noted.isEmpty, let translation = try? await Translator.translate(context.sentence) else { return choice }
        let scores = overlapScores(translation: translation, senses: senses)
        var pick: Int?
        if !chosenHasNote, let best = noted.max(by: { scores[$0] < scores[$1] }), scores[best] > 0, scores[best] >= scores[chosen] {
            pick = best
        } else {
            // Word overlap can't see synonyms. Two other signals, either of which is enough:
            // the model picks the noted sense twice (both orders, examples shown), or the
            // sentence is clearly closer to that sense's examples than to any other sense's.
            // Ask the model to choose between its pick and the noted sense, examples shown, in
            // both orders. Veto the switch when the sentence's translation matches the original
            // pick but not the noted sense ("I have a good relationship with him" is not guanxi).
            for i in noted.prefix(2) where !(scores[chosen] > 0 && scores[i] == 0) {
                if await prefersNoted(senses[i], over: senses[chosen], context: context) {
                    trace("model picked \(senses[i].gloss.prefix(30)) twice")
                    pick = i
                    break
                }
            }
        }
        guard let pick else { return choice }
        var switched = choice
        switched.senseNumber = pick + 1
        switched.meaningHere = shortGloss([senses[pick]])
        return switched
    }

    /// A yes/no question invites agreement (the 3B model says yes to "died" for 我们走吧),
    /// so offer exactly two meanings and ask in both orders. Unanimous or no switch:
    /// a missing note is fine, a wrong one is not.
    static func prefersNoted(_ noted: Sense, over current: Sense, context: WordInContext) async -> Bool {
        typealias S = DynamicGenerationSchema
        for (x, y) in [(current.gloss, noted.gloss), (noted.gloss, current.gloss)] {
            guard x != y, let schema = try? GenerationSchema(root: S(name: "Answer", properties: [
                S.Property(name: "meaning", description: "the meaning the marked word has in this passage",
                           schema: S(name: "Choice", anyOf: [x, y])),
            ]), dependencies: []) else { return false }
            let session = LanguageModelSession(instructions: "You help an English speaker read Chinese.")
            func option(_ gloss: String, _ sense: Sense) -> String {
                let ex = ExamplesStore.examples(context.word, sense).prefix(2)
                return ex.isEmpty ? "\"\(gloss)\"" : "\"\(gloss)\", as in: " + ex.joined(separator: " ")
            }
            let senseX = x == noted.gloss ? noted : current, senseY = y == noted.gloss ? noted : current
            let prompt = "Passage: \(context.markedSentence)\nWhich meaning does the marked word \(context.word) have here?\n\(option(x, senseX))\n\(option(y, senseY))"
            guard let r = try? await session.respond(to: prompt, schema: schema, options: GenerationOptions(sampling: .greedy)),
                  (try? r.content.value(String.self, forProperty: "meaning")) == noted.gloss else { return false }
        }
        return true
    }

    private static func trace(_ s: String) {
        if ProcessInfo.processInfo.environment["LONGYAN_TRACE"] == "1" { print("    · " + s) }
    }
}
