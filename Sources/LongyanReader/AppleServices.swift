import Foundation
import FoundationModels
import LongyanCore
import NaturalLanguage
import SwiftUI
import Translation

/// The Mac's side of `Platform`: Apple's word tokenizer, English tagger, on-device model and
/// translator, and SwiftUI's card motion. Installed once at launch, before anything is looked up.
enum AppleServices {
    static func install() {
        Platform.wordBreaker = AppleWordBreaker()
        Platform.englishTagger = AppleEnglishTagger()
        Platform.sensePicker = AppleSensePicker()
        Platform.translator = AppleTranslator()
        MainActor.assumeIsolated { CardMotion.animate = { change in withAnimation(cardMotion) { change() } } }
    }
}

/// NLTokenizer, told which script the text is in: it splits 我們 and 覺得 when told it's simplified.
struct AppleWordBreaker: WordBreaker {
    func script(of text: String) -> ChineseScript {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.simplifiedChinese, .traditionalChinese]
        r.processString(text)
        return r.dominantLanguage == .traditionalChinese ? .traditional : .simplified
    }

    func words(in text: String, script: ChineseScript) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(script == .traditional ? .traditionalChinese : .simplifiedChinese)
        tokenizer.string = text
        var out: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in out.append(r); return true }
        return out
    }
}

/// NLTagger's lexical classes.
struct AppleEnglishTagger: EnglishTagger {
    func classes(in sentence: String, from start: String.Index) -> [LexicalClass] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        tagger.setLanguage(.english, range: sentence.startIndex..<sentence.endIndex)
        var tags: [LexicalClass] = []
        tagger.enumerateTags(in: start..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag {
                switch tag {
                case .noun: tags.append(.noun)
                case .verb: tags.append(.verb)
                case .adjective: tags.append(.adjective)
                case .adverb: tags.append(.adverb)
                case .determiner: tags.append(.determiner)
                case .number: tags.append(.number)
                default: tags.append(.other)
                }
            }
            return true
        }
        return tags
    }
}

/// Apple's on-device model (macOS 26 with Apple Intelligence on): picks a sense when the
/// reading model can't, then checks its pick against the prewritten notes.
struct AppleSensePicker: SystemSensePicker {
    var isAvailable: Bool {
        if #available(macOS 26, *), case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var unavailableReason: String {
        guard #available(macOS 26, *) else { return "needs macOS 26" }
        switch SystemLanguageModel.default.availability {
        case .available: return "available"
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off"
        case .unavailable(.modelNotReady): return "model still downloading"
        case .unavailable(.deviceNotEligible): return "this Mac can't run it"
        case .unavailable(let other): return "unavailable (\(other))"
        }
    }

    func choose(passage: String, word: String, senses: [Sense]) async throws -> SenseChoice {
        guard #available(macOS 26, *) else { throw CancellationError() }
        return try await SenseChooser.respond(SenseChooser.prompt(passage, word: word, senses: senses), senses: senses, nuance: false)
    }

    func reconsider(_ choice: SenseChoice, context: WordInContext, senses: [Sense]) async -> SenseChoice {
        guard #available(macOS 26, *) else { return choice }
        return await SenseChooser.preferNoted(choice, context: context, senses: senses)
    }
}

/// Apple's Translation framework, on-device. Needs macOS 26 (a session without SwiftUI);
/// below that the local model translates.
struct AppleTranslator: SystemTranslator {
    private static let chinese = Locale.Language(identifier: "zh-Hans")
    private static let english = Locale.Language(identifier: "en")

    func translate(_ text: String) async throws -> String {
        guard #available(macOS 26, *) else {
            throw NSError(domain: "LongyanReader", code: 8, userInfo: [NSLocalizedDescriptionKey: "Apple's translator needs macOS 26"])
        }
        let session = TranslationSession(installedSource: Self.chinese, target: Self.english)
        return try await session.translate(text).targetText
    }
}

/// Apple's model, as the sense chooser asks it.
extension SenseChooser {
    /// The output schema, built at runtime. (The @Generable macro needs full Xcode;
    /// this works with just the Command Line Tools.)
    @available(macOS 26, *)
    static func schema(senseCount: Int, withNuance: Bool = true) throws -> GenerationSchema {
        typealias S = DynamicGenerationSchema
        let root = S(name: "SenseChoice", properties: [
            S.Property(name: "meaningHere",
                       description: "In English only: what the marked word alone means here, 1 to 5 words. Never Chinese, never a translation or description of the sentence.",
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

    @available(macOS 26, *)
    static func respond(_ prompt: String, senses: [Sense], nuance: Bool) async throws -> SenseChoice {
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

    /// The 3B model tends to pick the plainest sense (关系 "relationship" in 他靠关系找到了工作).
    /// When a sense with a prewritten note fits the sentence's translation at least as well
    /// as the model's pick, show that sense, so its note appears.
    @available(macOS 26, *)
    static func preferNoted(_ choice: SenseChoice, context: WordInContext, senses: [Sense]) async -> SenseChoice {
        let chosen = choice.senseNumber - 1
        if NotesStore.hasExactNote(context.word, senses[chosen]),
           let away = await checkNotedPick(chosen, context: context, senses: senses) {
            return away
        }
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

    /// The reverse check: the model picked a noted sense, but a plain sense with examples
    /// may fit better (沙发的面子 is the sofa's cover, not "face"). Same rules as switching
    /// toward a note: the competitor must win both orders, and the translation must not
    /// side with the noted pick. Returns the switched choice, or nil to keep the pick.
    @available(macOS 26, *)
    static func checkNotedPick(_ chosen: Int, context: WordInContext, senses: [Sense]) async -> SenseChoice? {
        let rivals = senses.indices.filter {
            $0 != chosen && !NotesStore.hasExactNote(context.word, senses[$0])
                && !ExamplesStore.examples(context.word, senses[$0]).isEmpty
        }
        guard !rivals.isEmpty else { return nil }
        let translation = try? await Translator.translate(context.sentence)
        let scores = translation.map { overlapScores(translation: $0, senses: senses) } ?? senses.map { _ in 0 }
        // The translation names the plain sense at least as clearly ("lay down on the bed").
        if let best = rivals.max(by: { scores[$0] < scores[$1] }), scores[best] > 0, scores[best] >= scores[chosen] {
            trace("translation sides with \(senses[best].gloss.prefix(30)) over the noted sense")
            return SenseChoice(senseNumber: best + 1, meaningHere: shortGloss([senses[best]]))
        }
        for r in rivals.prefix(2) where !(scores[chosen] > 0 && scores[r] == 0) {
            if await prefersNoted(senses[r], over: senses[chosen], context: context) {
                trace("model picked \(senses[r].gloss.prefix(30)) twice over the noted sense")
                return SenseChoice(senseNumber: r + 1, meaningHere: shortGloss([senses[r]]))
            }
        }
        return nil
    }

    /// A yes/no question invites agreement (the 3B model says yes to "died" for 我们走吧),
    /// so offer exactly two meanings and ask in both orders. Unanimous or no switch:
    /// a missing note is fine, a wrong one is not.
    @available(macOS 26, *)
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
}
