import Foundation

/// What the shared code asks of the system it runs on. Everything else in LongyanCore is
/// plain Swift and Foundation, so it builds and behaves the same on every platform; these
/// are the few things only the system provides. Each app sets them once at launch, before
/// any lookup (the Mac app in `AppleServices.install()`).
package enum Platform {
    /// Splits Chinese text into words. Required: the segmenter reads its word boundaries, and
    /// a guess in its place would quietly change every card.
    package static var wordBreaker: WordBreaker {
        get {
            guard let b = _wordBreaker else { fatalError("Platform.wordBreaker isn't set: install the platform's services at launch") }
            return b
        }
        set { _wordBreaker = newValue }
    }
    nonisolated(unsafe) private static var _wordBreaker: WordBreaker?
    /// Tags English words by part of speech, for reading a definition's part of speech.
    nonisolated(unsafe) package static var englishTagger: EnglishTagger?
    /// A sense picker built into the system, used when the reading model can't answer.
    nonisolated(unsafe) package static var sensePicker: SystemSensePicker?
    /// A translator built into the system, used when the reading model can't translate.
    nonisolated(unsafe) package static var translator: SystemTranslator?
}

/// Simplified or traditional Chinese.
package enum ChineseScript: Sendable { case simplified, traditional }

package protocol WordBreaker: Sendable {
    /// Which script `text` is mostly written in (simplified when it can't tell).
    func script(of text: String) -> ChineseScript
    /// The words of `text`, in order, as ranges of it. Stretches it can't split (spaces,
    /// punctuation, a run it stops short of) are simply left out.
    func words(in text: String, script: ChineseScript) -> [Range<String.Index>]
}

/// The word classes `PartOfSpeech` reads; any other class is `other`.
package enum LexicalClass: Sendable { case noun, verb, adjective, adverb, determiner, number, other }

package protocol EnglishTagger: Sendable {
    /// The class of each word of `sentence` from `start` on, skipping spaces and punctuation;
    /// words the tagger can't place are left out.
    func classes(in sentence: String, from start: String.Index) -> [LexicalClass]
}

package protocol SystemSensePicker: Sendable {
    /// Whether it can run now.
    var isAvailable: Bool { get }
    /// Why not, for the card's dictionary-order line and --status ("available" when it can).
    var unavailableReason: String { get }
    /// One try at picking the sense of `word`, marked 【】 in `passage`. Throws when it refuses.
    func choose(passage: String, word: String, senses: [Sense]) async throws -> SenseChoice
    /// A second look at its own pick, toward or away from a sense with a prewritten note;
    /// the pick unchanged when there's nothing to reconsider.
    func reconsider(_ choice: SenseChoice, context: WordInContext, senses: [Sense]) async -> SenseChoice
}

package protocol SystemTranslator: Sendable {
    /// Chinese to English.
    func translate(_ text: String) async throws -> String
}

/// How a card animates a change the shared code makes (a row's meaning arriving): the Mac
/// app sets SwiftUI's card motion; until then the change just happens.
@MainActor
package enum CardMotion {
    package static var animate: (() -> Void) -> Void = { $0() }
}
