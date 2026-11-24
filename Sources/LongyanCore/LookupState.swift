import Foundation
import Observation

/// Everything the popup shows for one lookup. Filled in two steps:
/// dictionary data immediately, then the model's choice when it arrives.
@MainActor
@Observable
package final class LookupState {
    package enum Phase: Equatable { case choosing, chosen, dictionaryOnly(String), failed(String) }

    package let context: WordInContext
    package let senses: [Sense]
    package var phase: Phase
    package var choice: SenseChoice?
    package var showAllSenses = false
    @ObservationIgnored package var onLayoutChange: () -> Void = {}

    /// The word a lone character belongs to here (彻 in 彻底), with its meaning in the sentence;
    /// for a word of several meanings that arrives after the character's own.
    package struct PartOf {
        package let word: String
        package var pinyin: String
        package var meaning: String?
        package init(word: String, pinyin: String, meaning: String?) { self.word = word; self.pinyin = pinyin; self.meaning = meaning }
    }
    package var partOf: PartOf?
    /// Opens the card for `partOf`'s word.
    @ObservationIgnored package var openPartOf: () -> Void = {}

    /// Set for 的 and 了, which show a fixed line instead of a chosen sense (`senseNumber` 0).
    package let grammar: GrammarWord?

    /// Set once the reader picks a meaning; a model answer arriving later doesn't replace it.
    package private(set) var userPicked = false
    /// The model's own answer, kept so the reader can go back to it.
    package var suggested: SenseChoice?
    /// Called when the reader changes the meaning (for History).
    @ObservationIgnored package var onUserPick: (SenseChoice) -> Void = { _ in }

    /// The reader picks a meaning. Clicking the one already chosen changes nothing, so the
    /// model's headline (理解: "to understand") isn't swapped for the dictionary's wording.
    package func pick(_ index: Int) {
        guard senses.indices.contains(index), choice?.senseNumber != index + 1 else { return }
        if let suggested, suggested.senseNumber == index + 1 {
            useSuggested()
            return
        }
        userPicked = true
        choice = SenseChoice(senseNumber: index + 1, meaningHere: headlineGloss(senses[index]))
        phase = .chosen
        onLayoutChange()
        onUserPick(choice!)
    }

    /// Back to the model's answer, with its own wording.
    package func useSuggested() {
        guard let suggested else { return }
        userPicked = false
        choice = suggested
        phase = .chosen
        onLayoutChange()
        onUserPick(suggested)
    }

    /// True when the headline is the model's reading of this passage rather than dictionary wording.
    package var isContextual: Bool {
        guard !userPicked, let choice, let sense = senses[safe: choice.senseNumber - 1] else { return false }
        let text = choice.meaningHere.lowercased()
        return !Gloss.readable(sense.gloss).lowercased().contains(text)
            && !text.contains(headlineGloss(sense).lowercased())
    }

    /// The model's answer arrived: show it unless the reader has already chosen.
    package func receive(_ answer: SenseChoice) {
        suggested = answer
        guard !userPicked else { return }
        choice = answer
        phase = .chosen
    }

    package init(context: WordInContext, senses: [Sense], phase: Phase) {
        self.context = context
        self.senses = senses
        self.phase = phase
        grammar = GrammarWords.entry(context.word, in: context.passage, at: context.wordRange.lowerBound)
        if let grammar, !senses.isEmpty {
            suggested = SenseChoice(senseNumber: 0, meaningHere: grammar.summary)
            choice = suggested
            self.phase = .chosen
        }
    }

    package var chosenIndex: Int? { choice.map { $0.senseNumber - 1 } }
    package var headerPinyin: String {
        if !userPicked, let grammar { return grammar.reading }
        return senses[safe: chosenIndex ?? 0]?.pinyin ?? ""
    }
}

package extension LookupState {
    /// What Copy puts on the clipboard: the word that was looked up, as it appears in the text.
    var copyText: String { context.word }

    /// What Add to Anki adds: the card as it stands, with the meaning the reader sees.
    var ankiNote: AnkiNote? {
        let sense = senses[safe: chosenIndex ?? 0]
        guard let meaning = choice?.meaningHere ?? sense.map(headlineGloss) else { return nil }
        let dictionary = sense.map { Gloss.readable($0.gloss) } ?? ""
        return AnkiNote(chinese: context.word, pinyin: Pinyin.marked(headerPinyin), meaning: meaning,
                        sentence: context.sentence == context.word ? "" : context.markedSentence,
                        dictionary: dictionary.lowercased() == meaning.lowercased() ? "" : dictionary,
                        note: choice.flatMap { NotesStore.note(context.word, senses[safe: $0.senseNumber - 1])?.shown } ?? "")
    }
}

/// What a card's Listen button says, and its tooltip.
package struct SpeechPlan: Equatable {
    package let text: String
    package let help: String
    package init(text: String, help: String) { self.text = text; self.help = help }
}

package enum Reading {
    /// Whether two numbered readings sound the same: same syllables, same tones, a neutral
    /// tone matching any (关系 guan1 xi5 and guan1 xi4 are one word).
    package static func same(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: " "), y = b.lowercased().split(separator: " ")
        guard x.count == y.count else { return false }
        return zip(x, y).allSatisfy { s, t in
            let (sb, st) = split(s), (tb, tt) = split(t)
            return sb == tb && (st == tt || st == 5 || tt == 5)
        }
    }

    private static func split(_ syllable: Substring) -> (String, Int) {
        guard let last = syllable.last, let tone = last.wholeNumberValue else { return (String(syllable), 5) }
        return (String(syllable.dropLast()), tone)
    }
}

package extension LookupState {
    /// The word alone when the voice will say it the way this card reads it: a word with one
    /// reading, or this card's reading being its everyday one (the first, in the hand-set
    /// order). A rarer reading (好 as hào) is read in context instead, which the voice gets
    /// right: the word it's part of here (好学), else the clause around it.
    var speech: SpeechPlan {
        let word = context.word
        let common = senses.filter { !$0.rare }
        var readings: [String] = []
        for s in common where !readings.contains(where: { Reading.same($0, s.pinyin) }) { readings.append(s.pinyin) }
        let here = headerPinyin
        if readings.count <= 1 || here.isEmpty || Reading.same(here, common.first?.pinyin ?? here) {
            return SpeechPlan(text: word, help: "Listen to “\(word)”")
        }
        if let part = partOf {
            return SpeechPlan(text: part.word, help: "Listen to “\(part.word)” (\(word) alone has another reading)")
        }
        return SpeechPlan(text: clause, help: "Listen in context (\(word) alone has another reading)")
    }

    /// The clause around the word, up to its punctuation, within about 20 characters each way.
    private var clause: String {
        let stops: Set<Character> = ["。", "！", "？", "；", "，", "、", "：", "!", "?", ";", ",", ":", "\n", "“", "”", "「", "」"]
        let p = context.passage, r = context.wordRange
        var lo = r.lowerBound, hi = r.upperBound
        while lo > 0, !stops.contains(p[lo - 1]), r.lowerBound - lo < 20 { lo -= 1 }
        while hi < p.count, !stops.contains(p[hi]), hi - r.upperBound < 20 { hi += 1 }
        return String(p[lo..<hi]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

package extension LookupState {
    /// What a word card opens with. Without a model to pick, the everyday meaning goes first
    /// and the card says why it's in dictionary order. Copied text (the ⌘C fallback) is only
    /// the word itself (`alone`): with no sentence a pick would be a guess shown as an answer,
    /// so dictionary order then too. A lone character inside a longer word (彻 in 彻底) also
    /// shows that word: a word with one meaning, or one a cue settles, at once; otherwise
    /// `partPick` is the pick to make after the character's own (八卦 is gossip, not trigrams).
    struct Opening {
        package let state: LookupState
        /// Whether the model should pick this word's meaning.
        package let modelReady: Bool
        /// The word a lone character belongs to, to open from its card.
        package let whole: WordInContext?
        /// That word, when its meaning still needs the model.
        package let partPick: (context: WordInContext, senses: [Sense])?
    }

    static func opening(_ context: WordInContext, dict: CEDict, alone: Bool = false) -> Opening {
        var senses = dict.senses(for: context.word)
        let grammar = GrammarWords.entry(context.word, in: context.passage, at: context.wordRange.lowerBound)
        let modelReady = SenseChooser.canChoose && !senses.isEmpty && grammar == nil && !(alone && senses.count > 1)
        // No model will pick, so nothing reads this list but the card: the everyday meaning goes first.
        if !modelReady, grammar == nil, case let i = dict.everydayIndex(for: context.word, in: senses), i > 0 {
            senses.insert(senses.remove(at: i), at: 0)
        }
        let why = senses.isEmpty ? Gloss.notInDictionary
            : alone && senses.count > 1 ? "this app doesn't share the sentence" : SenseChooser.noPickerReason
        let state = LookupState(context: context, senses: senses, phase: modelReady ? .choosing : .dictionaryOnly(why))
        var whole: WordInContext?
        var partPick: (context: WordInContext, senses: [Sense])?
        if let r = Segmenter.enclosingWord(of: context.wordRange, in: context.passage, dict: dict) {
            let w = Segmenter.context(for: r, in: context.passage)
            let wordSenses = dict.senses(for: w.word)
            let settled = wordSenses.count == 1 ? 1 : NoteCues.senseNumber(w.word, at: r, in: context.passage, senses: wordSenses)
            if let first = wordSenses.first {
                let sense = settled.flatMap { wordSenses[safe: $0 - 1] }
                state.partOf = .init(word: w.word, pinyin: (sense ?? first).pinyin, meaning: sense.map { Gloss.short($0.gloss) })
                whole = w
                if sense == nil, SenseChooser.canChoose { partPick = (w, wordSenses) }
            }
        }
        return Opening(state: state, modelReady: modelReady, whole: whole, partPick: partPick)
    }

    /// The model couldn't pick: the card stays in dictionary order and says why.
    func pickFailed(_ error: Error) {
        phase = error is NoSenseFits ? .dictionaryOnly("none of the listed meanings fit this sentence")
            : .failed(String(describing: error).prefix(80).description)
    }

    /// The meaning of the word a lone character belongs to arrived (`Opening.partPick`).
    func receivePartOf(_ choice: SenseChoice, senses: [Sense]) {
        partOf?.pinyin = senses[safe: choice.senseNumber - 1]?.pinyin ?? partOf?.pinyin ?? ""
        partOf?.meaning = choice.meaningHere
    }
}
