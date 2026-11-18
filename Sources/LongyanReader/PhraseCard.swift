import SwiftUI

/// A highlighted phrase: a translation on top, then each word with its meaning in this
/// passage. The card opens at once; the translation streams in, then the words fill in
/// from the top as the model chooses them (see `PhrasePrep`).
@MainActor
final class PhraseState: ObservableObject {
    let selection: Selection
    let tokens: [PhraseToken]
    let senses: [Int: [Sense]]
    /// Rows line up with the translation once it's whole: aligning on every streamed word
    /// re-read the whole translation per word and could flip a row's meaning mid-stream.
    @Published var translation: String? { didSet { if !streaming { alignToTranslation() } } }
    private var streaming = false
    private var alignedTo: String?
    /// For each word, the sense that agrees with the translation (until the model has chosen).
    @Published var translationSense: [Int: Int] = [:]
    @Published var translationError: String?
    @Published var expanded: Int?
    @Published var choices: [Int: SenseChoice] = [:]
    @Published var choosing: Set<Int> = []
    @Published var failures: [Int: String] = [:]
    /// Rows opened out to every meaning.
    @Published var showingAll: Set<Int> = []
    /// True while the model is still picking the words' senses; those rows show a placeholder.
    @Published var resolving = false
    /// Words whose meaning the reader picked; a model answer arriving later doesn't replace it.
    private(set) var userPicked: Set<Int> = []
    /// The model's own answers, kept so the reader can go back to them.
    @Published private(set) var suggested: [Int: SenseChoice] = [:]
    var onLayoutChange: () -> Void = {}

    /// The word's fixed line, if it has one (see `GrammarWords`).
    func grammarEntry(_ token: PhraseToken) -> GrammarWord? {
        (senses[token.id] ?? []).isEmpty ? nil : GrammarWords.entry(token.text, in: selection.passage, at: token.range.lowerBound)
    }

    /// The same, while the row still shows that line: picking a definition replaces it.
    func grammar(_ token: PhraseToken) -> GrammarWord? {
        userPicked.contains(token.id) ? nil : grammarEntry(token)
    }

    func pick(_ token: PhraseToken, sense index: Int) {
        guard let list = senses[token.id], list.indices.contains(index) else { return }
        // Clicking the meaning already shown changes nothing.
        guard grammar(token) != nil || shownSense(token) != index else { return }
        if grammarEntry(token) == nil, suggestedSense(token) == index {
            useSuggested(token)
            return
        }
        userPicked.insert(token.id)
        choices[token.id] = SenseChoice(senseNumber: index + 1, meaningHere: headlineGloss(list[index]))
        onLayoutChange()
    }

    /// The sense the row showed before the reader picked: the model's, else the one that fits
    /// the translation, else the first.
    private func suggestedSense(_ token: PhraseToken) -> Int {
        suggested[token.id].map { $0.senseNumber - 1 } ?? translationSense[token.id] ?? 0
    }

    /// Whether the reader has moved this row away from its suggested meaning.
    func canUseSuggested(_ token: PhraseToken) -> Bool {
        guard userPicked.contains(token.id) else { return false }
        return grammarEntry(token) != nil || shownSense(token) != suggestedSense(token)
    }

    /// The meaning `useSuggested` goes back to, for its button.
    func suggestedMeaning(_ token: PhraseToken) -> String? {
        if let entry = grammarEntry(token) { return entry.summary }
        if let answer = suggested[token.id] { return answer.meaningHere }
        return (senses[token.id] ?? [])[safe: suggestedSense(token)].map(headlineGloss)
    }

    /// Back to the model's answer, with its own wording. Without one yet, the row falls back
    /// to its default and takes the answer when it arrives.
    func useSuggested(_ token: PhraseToken) {
        userPicked.remove(token.id)
        choices[token.id] = suggested[token.id]
        onLayoutChange()
    }

    init(selection: Selection, dict: CEDict) {
        self.selection = selection
        let tokens = Segmenter.phrase(selection.range, in: selection.passage, dict: dict)
        self.tokens = tokens
        var senses: [Int: [Sense]] = [:]
        for t in tokens { senses[t.id] = dict.senses(for: t.text) }
        self.senses = senses
    }

    /// Takes the senses chosen up front; the reader's own picks stay.
    func apply(_ picks: [Int: SenseChoice]) {
        for (id, choice) in picks {
            suggested[id] = choice
            if !userPicked.contains(id) { choices[id] = choice }
        }
        resolving = false
        onLayoutChange()
    }

    /// Follows a phrase's prepared work as it streams in: the translation, then each word.
    func follow(_ prep: PhrasePrep) {
        prep.onChange = { [weak self, weak prep] in
            guard let self, let prep else { return }
            self.sync(prep)
        }
        sync(prep)
    }

    private var layoutPending = false
    private func sync(_ prep: PhrasePrep) {
        streaming = !prep.translationDone
        if translation != prep.translation { translation = prep.translation }
        if prep.translationDone { alignToTranslation() }
        if prep.translationDone, prep.translation == nil { translationError = prep.translationError }
        for (id, choice) in prep.picks where suggested[id] == nil { suggested[id] = choice }
        for (id, choice) in prep.picks where choices[id] == nil && !userPicked.contains(id) {
            withAnimation(cardMotion) { choices[id] = choice }
        }
        for (id, why) in prep.misses where failures[id] == nil { failures[id] = why }
        if resolving != !prep.done { withAnimation(cardMotion) { resolving = !prep.done } }
        // Streaming updates come in quickly; resize the card at most every 80 ms.
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.layoutPending = false
            self?.onLayoutChange()
        }
    }

    /// Whether this row shows a dictionary-order guess because no pick could be made.
    func isGuess(_ token: PhraseToken) -> Bool { failures[token.id] != nil && choices[token.id] == nil }

    /// Whether this row is still waiting for its sense (its gloss and pinyin aren't final yet).
    func pending(_ token: PhraseToken) -> Bool {
        resolving && choices[token.id] == nil && (senses[token.id]?.count ?? 0) > 1 && grammarEntry(token) == nil
    }

    /// Words worth asking the model about: those with more than one dictionary sense
    /// (other than those with a fixed line).
    static func ambiguous(_ tokens: [PhraseToken], in passage: [Character], dict: CEDict) -> [PhraseToken] {
        tokens.filter { dict.senses(for: $0.text).count > 1 && GrammarWords.entry($0.text, in: passage, at: $0.range.lowerBound) == nil }
    }

    /// Chooses the in-context sense of every ambiguous word at once, so the card opens with
    /// each row already resolved instead of changing when the reader opens it.
    /// Words left without a pick are passed to `onMiss` with why, so their rows show the
    /// dictionary-order guess as a guess.
    static func resolve(_ tokens: [PhraseToken], in passage: [Character], dict: CEDict, translation: String? = nil,
                        onPick: @MainActor (Int, SenseChoice) -> Void = { _, _ in },
                        onMiss: @MainActor (Int, String) -> Void = { _, _ in }) async -> [Int: SenseChoice] {
        var words = ambiguous(tokens, in: passage, dict: dict)
        guard SenseChooser.canChoose else { return [:] }
        var out: [Int: SenseChoice] = [:]
        var noFit: Set<Int> = []
        func reportMisses() {
            for t in words where out[t.id] == nil {
                onMiss(t.id, noFit.contains(t.id) ? "Dictionary order · none of the listed meanings fit this sentence"
                                                  : "Dictionary order · couldn't tell which meaning fits here")
            }
        }
        words.removeAll { t in
            let list = dict.senses(for: t.text)
            guard let n = NoteCues.senseNumber(t.text, at: t.range, in: passage, senses: list) else { return false }
            let choice = SenseChoice(senseNumber: n, meaningHere: headlineGloss(list[n - 1]))
            out[t.id] = choice
            onPick(t.id, choice)
            return true
        }
        // Grammar words whose position gives them away need no model call; the 4B model
        // reads them wrong often enough (安抚和平衡's 和 "harmonious", 一两个人's 一 "single").
        if ProcessInfo.processInfo.environment["LONGYAN_NO_RULES"] != "1" {
            words.removeAll { t in
                let list = dict.senses(for: t.text)
                guard let i = grammarSense(t, tokens: tokens, passage: passage, senses: list) else { return false }
                let choice = SenseChoice(senseNumber: i + 1, meaningHere: headlineGloss(list[i]))
                out[t.id] = choice
                onPick(t.id, choice)
                return true
            }
        }
        guard let lo = words.first?.range.lowerBound, let hi = words.last?.range.upperBound else { return out }
        // The local model takes them all in one streamed request (in chunks, to stay inside its
        // context window): Ollama answers one request at a time, so word-by-word calls queue.
        if await LocalModel.isAvailable() {
            var sentence = Segmenter.context(for: lo..<hi, in: passage).sentence
            // Mark the selection when it's part of a longer sentence, or the rest can pull the
            // words off their sense (a list earlier in the sentence made 再等三天's 等 "by the time").
            var selectionMarked = false
            if let a = tokens.first?.range.lowerBound, let b = tokens.last?.range.upperBound {
                let span = Segmenter.context(for: a..<b, in: passage)
                if span.sentence.count - span.word.count > 1 {
                    sentence = span.markedSentence
                    selectionMarked = true
                }
            }
            var answered = false
            var start = 0
            while start < words.count {
                let chunk = Array(words[start..<min(start + 8, words.count)])
                start += chunk.count
                let lists = chunk.map { (word: $0.text, senses: dict.senses(for: $0.text).forModel) }
                func choice(_ i: Int, _ n: Int) -> SenseChoice {
                    SenseChoice(senseNumber: n, meaningHere: headlineGloss(lists[i].senses[n - 1]))
                }
                guard let picks = try? await LocalModel.chooseAll(passage: sentence, selectionMarked: selectionMarked, words: lists,
                                                                  onPick: { i, n in onPick(chunk[i].id, choice(i, n)) })
                else { continue }
                answered = true
                for (i, n) in picks.enumerated() {
                    if let n { out[chunk[i].id] = choice(i, n) } else { noFit.insert(chunk[i].id) }
                }
            }
            // Only when the model answered: words settled by cues or rules above don't count.
            if answered || ProcessInfo.processInfo.environment["LONGYAN_BATCH_ONLY"] == "1" {
                reportMisses()
                return out
            }
        }
        words.removeAll { out[$0.id] != nil }
        // Apple's model: one word at a time, concurrently. Answers are passed on in reading
        // order (each once the words before it are in), so the rows still fill in from the top.
        return await withTaskGroup(of: (Int, SenseChoice?).self) { group in
            for t in words {
                let list = dict.senses(for: t.text)
                // This model misreads grammar words (地 "-ly", 我过春节 as a past marker), and their
                // position usually settles them. Next, a sense the translation agrees with beats
                // its guess (他才三岁 "only three years old" settles 才). Neither needs a model
                // call. Words with notes stay with the model: "passed away" isn't 走 "to go away".
                let settled = grammarSense(t, tokens: tokens, passage: passage, senses: list)
                    ?? (list.contains { NotesStore.hasExactNote(t.text, $0) } ? nil
                        : translation.flatMap { SenseChooser.senseMatching(translation: $0, senses: list, word: t.text) })
                if let settled {
                    let choice = SenseChoice(senseNumber: settled + 1, meaningHere: headlineGloss(list[settled]))
                    group.addTask { (t.id, choice) }
                    continue
                }
                group.addTask {
                    (t.id, try? await SenseChooser.choose(for: Segmenter.context(for: t.range, in: passage), senses: list))
                }
            }
            var arrived: [Int: SenseChoice?] = [:]
            var next = 0
            for await (id, choice) in group {
                arrived[id] = .some(choice)
                while next < words.count, let ready = arrived[words[next].id] {
                    if let ready { out[words[next].id] = ready; onPick(words[next].id, ready) }
                    next += 1
                }
            }
            reportMisses()
            return out
        }
    }

    /// Common measure words, for telling 一个 "one" from 一看 "as soon as".
    private static let measureWords: Set<Character> = Set("个只条张本件次天年位种块把双份些点辆家所头匹台封首部句场间")

    /// The sense of a grammar word, when its position gives it away.
    static func grammarSense(_ t: PhraseToken, tokens: [PhraseToken], passage: [Character], senses: [Sense]) -> Int? {
        func index(_ prefix: String) -> Int? { senses.firstIndex { $0.gloss.hasPrefix(prefix) } }
        let i = tokens.firstIndex { $0.id == t.id } ?? 0
        let previous = i > 0 && tokens[i - 1].range.upperBound == t.range.lowerBound ? tokens[i - 1].text : nil
        // After a pronoun these are verbs: 他得了感冒, 我得走了, 我过春节.
        let afterVerb = previous != nil && !["我", "你", "他", "她", "它", "我们", "你们", "他们", "她们"].contains(previous!)
        let atEnd = t.range.upperBound >= passage.count || !(isCJK(passage[t.range.upperBound]) || passage[t.range.upperBound].isLetter)
        let next = t.range.upperBound < passage.count ? passage[t.range.upperBound] : nil
        let before = t.range.lowerBound > 0 ? passage[t.range.lowerBound - 1] : nil
        let numerals: Set<Character> = ["一", "二", "两", "三", "四", "五", "六", "七", "八", "九", "十", "几", "数", "百", "千", "万"]
        switch t.text {
        // Alone (not in 和平, 和气 …) it joins things: 我和你, 安抚和平衡. 和了 is the game sense.
        case "和" where next != "了": return index("(joining two nouns)")
        // 一两个, 一个, 一次: the number. (一进门 "as soon as" is left to the model.)
        case "一" where next.map { numerals.contains($0) || measureWords.contains($0) } ?? false: return index("one")
        case "百" where before.map(numerals.contains) ?? false: return index("hundred")
        case "千" where before.map(numerals.contains) ?? false: return index("thousand")
        case "万" where before.map(numerals.contains) ?? false: return index("ten thousand")
        case "地": return index("structural particle")
        case "得" where afterVerb && !atEnd && passage[t.range.upperBound] != "了": return index("structural particle")
        case "过" where afterVerb: return index("(experienced action marker)")
        case "着" where afterVerb: return index("aspect particle")
        default: return nil
        }
    }

    private func alignToTranslation() {
        guard let translation, translation != alignedTo else { return }
        alignedTo = translation
        for t in tokens where grammarEntry(t) == nil {
            if let list = senses[t.id], let i = SenseChooser.senseMatching(translation: translation, senses: list, word: t.text) {
                translationSense[t.id] = i
            }
        }
    }

    /// The gloss to show on a word's row: the meaning the model chose, else the one that fits
    /// the translation, else the first. The row's gloss is always the dictionary wording of the meaning the row shows, so it
    /// only changes when that meaning changes (a pick, or the model choosing a different
    /// sense), never just because the row was opened. The model's own in-context wording is
    /// shown inside the open row instead (`meaningHere`).
    func gloss(_ token: PhraseToken) -> String {
        if let grammar = grammar(token) { return grammar.summary }
        let list = senses[token.id] ?? []
        guard let i = shownSense(token), list.indices.contains(i) else { return shortGloss(list) }
        return shortGloss([list[i]])
    }

    /// Index of the sense the row shows: the reader's or model's choice, else the one that
    /// fits the translation, else the first.
    func shownSense(_ token: PhraseToken) -> Int? {
        if let grammar = grammar(token) { return senses[token.id]?.firstIndex { $0.pinyin == grammar.reading } ?? 0 }
        if let c = choices[token.id] { return c.senseNumber - 1 }
        if let i = translationSense[token.id] { return i }
        return (senses[token.id] ?? []).isEmpty ? nil : 0
    }

    /// The model's wording for this word in this passage, when it adds something to the gloss.
    func meaningHere(_ token: PhraseToken) -> String? {
        guard let c = choices[token.id], !userPicked.contains(token.id), !c.viaTranslation else { return nil }
        let text = c.meaningHere.lowercased()
        // Only when it says something the dictionary wording doesn't already
        // ("Ming Dynasty" adds nothing to "Ming Dynasty (1368-1644)").
        let list = senses[token.id] ?? []
        let full = shownSense(token).flatMap { list[safe: $0] }.map { Gloss.readable($0.gloss).lowercased() } ?? ""
        if full.contains(text) || text.contains(headlineGloss(list[safe: shownSense(token) ?? 0] ?? Sense(pinyin: "", gloss: "")).lowercased()) {
            return nil
        }
        return c.meaningHere
    }

    /// The prewritten note for the sense this word currently shows, if any.
    func note(_ token: PhraseToken) -> StoredNote? {
        let list = senses[token.id] ?? []
        return NotesStore.note(token.text, shownSense(token).flatMap { list[safe: $0] })
    }

    /// Whether opening the row shows anything the row doesn't: other meanings, a note, the
    /// model's own wording, or why it's a guess. A word with one meaning and nothing else doesn't open.
    func canOpen(_ token: PhraseToken) -> Bool {
        (senses[token.id]?.count ?? 0) > 1 || note(token) != nil || meaningHere(token) != nil
            || failures[token.id] != nil || pending(token)
    }

    func toggle(_ token: PhraseToken) {
        expanded = expanded == token.id ? nil : token.id
        defer { onLayoutChange() }
        guard expanded == token.id, grammarEntry(token) == nil, !resolving, choices[token.id] == nil, !choosing.contains(token.id),
              let list = senses[token.id], !list.isEmpty, SenseChooser.canChoose else { return }
        choosing.insert(token.id)
        Task {
            do {
                let choice = try await SenseChooser.choose(
                    for: Segmenter.context(for: token.range, in: selection.passage), senses: list)
                suggested[token.id] = choice
                failures[token.id] = nil
                if !userPicked.contains(token.id) {
                    withAnimation(cardMotion) { choices[token.id] = choice }
                }
            } catch {
                failures[token.id] = "Dictionary order · couldn't tell which meaning fits here"
            }
            choosing.remove(token.id)
            onLayoutChange()
        }
    }
}

/// The first dictionary sense, as one short meaning for a row.
func shortGloss(_ senses: [Sense]?) -> String {
    senses?.first.map { Gloss.short($0.gloss) } ?? LookupView.notInDictionary
}

/// A sense's first meaning, for the word card's headline.
func headlineGloss(_ sense: Sense) -> String { Gloss.short(sense.gloss) }

let particleWords: Set<String> = ["的", "了", "和", "是", "在", "也", "都", "就", "与", "或", "但", "而", "对", "于",
                                  "把", "被", "让", "给", "从", "到", "着", "过", "吗", "呢", "吧", "啊", "嗯", "呀", "地", "得"]

/// The widest word column among a phrase card's rows, so every row's meaning starts at the same x.
private struct WordColumnKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension PhraseState {
    /// What Copy puts on the clipboard: the highlighted text.
    var copyText: String { selection.text }
}

struct PhraseView: View {
    @ObservedObject var state: PhraseState
    @Environment(\.cardScale) private var scale
    @State private var column: CGFloat = 0
    private let maxRows = 24

    /// Gap between the word column and the meaning column.
    private var gutter: CGFloat { Space.m * scale }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            // The highlighted Chinese first, with Copy and Pin beside it, then its
            // translation: source over translation, as in Translate.
            VStack(alignment: .leading, spacing: Space.xs * scale) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s * scale) {
                    Text(state.selection.text)
                        .cardFont(14)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ActionSlot(centerAboveBaseline: 5 * scale)
                }
                translation
            }
            VStack(alignment: .leading, spacing: Space.s * scale) {
                CardDivider()
                SectionLabel(text: "Words")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(state.tokens.prefix(maxRows)) { token in row(token) }
                    if state.tokens.count > maxRows {
                        Text("\(state.tokens.count - maxRows) more words not shown")
                            .cardFont(TextSize.subheadline).foregroundStyle(.tertiary).padding(.vertical, Space.xs * scale)
                    }
                }
                .onPreferenceChange(WordColumnKey.self) { w in MainActor.assumeIsolated { column = w } }
            }
        }
        .animation(cardMotion, value: state.expanded)
        .animation(cardMotion, value: state.translation)
        .animation(cardMotion, value: state.choices.count)
        .animation(cardMotion, value: state.choosing)
        .animation(cardMotion, value: state.resolving)
    }

    @ViewBuilder private var translation: some View {
        if let t = state.translation {
            Text(t).cardFont(TextSize.translation)
                .lineSpacing(2 * scale)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else if let e = state.translationError {
            Text("No translation · \(e)").cardFont(TextSize.subheadline).foregroundStyle(.secondary)
        } else {
            HStack(spacing: Space.s * scale) { ProgressView().controlSize(.mini); Text("Translating…") }
                .cardFont(TextSize.callout).foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private func row(_ token: PhraseToken) -> some View {
        let senses = state.senses[token.id] ?? []
        let syllables = Pinyin.syllables(senses[safe: state.shownSense(token) ?? 0]?.pinyin ?? "")
        let isOpen = state.expanded == token.id
        let dim = particleWords.contains(token.text)
        let pending = state.pending(token)
        let opens = state.canOpen(token)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(cardMotion) { state.toggle(token) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: gutter) {
                    // The word with its pinyin under it, in a column as wide as the widest row's.
                    VStack(alignment: .leading, spacing: 1 * scale) {
                        HStack(spacing: 0) {
                            ForEach(Array(token.text.enumerated()), id: \.offset) { i, ch in
                                Text(String(ch)).foregroundStyle(pending ? Color.secondary : hanziColor(syllables[safe: i]?.tone ?? 5))
                            }
                        }
                        .cardFont(TextSize.rowWord - 1, .medium)
                        HStack(spacing: 2 * scale) {
                            ForEach(Array(syllables.enumerated()), id: \.offset) { _, s in
                                Text(s.text).foregroundStyle(pinyinColor(s.tone))
                            }
                        }
                        .cardFont(TextSize.footnote + 0.5)
                        .redacted(reason: pending ? .placeholder : [])
                    }
                    .fixedSize()
                    .background(GeometryReader { g in Color.clear.preference(key: WordColumnKey.self, value: g.size.width) })
                    .frame(width: column > 0 ? column : nil, alignment: .leading)
                    Text(state.gloss(token))
                        .cardFont(TextSize.body)
                        .foregroundStyle(dim || state.isGuess(token) ? .secondary : .primary)
                        .lineLimit(isOpen ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .redacted(reason: pending ? .placeholder : [])
                        .opacity(pending ? 0.6 : 1)
                        .contentTransition(.opacity)
                    if !pending, state.note(token) != nil { NoteMark() }
                    // Rows with nothing more to show (one meaning, no note) don't open.
                    Image(systemName: "chevron.forward")
                        .cardFont(TextSize.footnote, .semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .opacity(opens ? 1 : 0)
                }
            }
            .buttonStyle(CardRowStyle(vertical: Space.xs + 1))
            .disabled(!opens && !isOpen)
            if isOpen {
                detail(token, senses: senses)
                    .transition(.opacity.combined(with: .offset(y: -6 * scale)))
            }
        }
    }

    /// An open row: what the model read, any note, and the meanings to choose from, all
    /// lined up under the meaning column (the checkmarks sit in the gap before it).
    @ViewBuilder private func detail(_ token: PhraseToken, senses: [Sense]) -> some View {
        VStack(alignment: .leading, spacing: Space.s * scale) {
            Group {
                if state.pending(token) || state.choosing.contains(token.id) {
                    HStack(spacing: Space.s * scale) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                        .cardFont(TextSize.callout).foregroundStyle(.secondary)
                } else if let f = state.failures[token.id] {
                    Text(f).cardFont(TextSize.subheadline).foregroundStyle(.secondary)
                } else if state.choices[token.id]?.viaTranslation == true {
                    Text("Picked to match the translation").cardFont(TextSize.subheadline).foregroundStyle(.secondary)
                } else if let here = state.meaningHere(token) {
                    (Text("In this sentence: ").foregroundColor(.secondary) + Text(here).fontWeight(.medium))
                        .cardFont(TextSize.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                if state.canUseSuggested(token), let meaning = state.suggestedMeaning(token) {
                    Button { withAnimation(cardMotion) { state.useSuggested(token) } } label: {
                        Label("Back to “\(meaning)”", systemImage: "arrow.uturn.backward")
                            .cardFont(TextSize.callout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity)
                }
                if let note = state.note(token) {
                    NuanceView(note: note).transition(.opacity)
                }
            }
            let listed = state.grammarEntry(token)?.listed(senses)
            let all = state.showingAll.contains(token.id)
            let preview = senses.preview(chosen: state.shownSense(token))
            let collapsed = Array(senses.enumerated()).filter { (listed?.contains($0.element) ?? preview.contains($0.offset)) || (listed != nil && state.grammar(token) == nil && $0.offset == state.shownSense(token)) }
            let shown = all ? Array(senses.enumerated()) : collapsed
            let showReading = Set(shown.map(\.element.pinyin)).count > 1
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.offset) { position, item in
                    let (i, sense) = item
                    let chosen = state.grammar(token) == nil && state.shownSense(token) == i
                    if showReading && SenseLine.startsReading(shown, at: position) {
                        ReadingHeader(pinyin: sense.pinyin, first: position == 0)
                    }
                    Button { withAnimation(cardMotion) { state.pick(token, sense: i) } } label: {
                        HStack(alignment: .center, spacing: Space.s * scale) {
                            SenseLine(number: i + 1, total: senses.count,
                                      gloss: listed?.contains(sense) == true ? Gloss.short(sense.gloss) : Gloss.listed(sense.gloss),
                                      partOfSpeech: PartOfSpeech.of(sense.gloss),
                                      size: TextSize.callout, chosen: chosen, dimmed: !chosen)
                                .help(Gloss.readable(sense.gloss))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            ChoiceMark(chosen: chosen)
                        }
                    }
                    .buttonStyle(CardRowStyle(bleed: Space.s, vertical: 3))
                    .help("Use this meaning")
                }
                if senses.count > collapsed.count {
                    Button {
                        withAnimation(cardMotion) {
                            if all { state.showingAll.remove(token.id) } else { state.showingAll.insert(token.id) }
                        }
                        state.onLayoutChange()
                    } label: {
                        HStack(spacing: Space.xs * scale) {
                            Text(all ? "Show Fewer" : "Show All \(senses.count)")
                            Image(systemName: "chevron.down").cardFont(TextSize.footnote, .semibold)
                                .rotationEffect(.degrees(all ? 180 : 0))
                        }
                        .cardFont(TextSize.callout, .medium).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(CardRowStyle(bleed: Space.s, vertical: 3))
                }
            }
            if senses.isEmpty { Text("Not in the dictionary").cardFont(TextSize.callout).foregroundStyle(.secondary) }
        }
        // The detail uses the card's full width, from its leading edge like everything else.
        .padding(.top, Space.xxs * scale)
        .padding(.bottom, Space.s * scale)
    }
}

/// The work behind a phrase card, started as soon as the text is selected so it's usually
/// done or well along by the time the reader clicks: first the translation (streamed), then
/// every word's sense, streamed in order so the rows fill in from the top.
@MainActor
final class PhrasePrep {
    let text: String
    let passage: [Character]
    private(set) var translation: String?
    private(set) var translationDone = false
    private(set) var translationError: String?
    private(set) var picks: [Int: SenseChoice] = [:]
    /// Words left without a pick, with why.
    private(set) var misses: [Int: String] = [:]
    private(set) var done = false
    private(set) var translationMs = 0
    /// Called after every piece of progress.
    var onChange: () -> Void = {}
    private var task: Task<Void, Never>?

    init(_ selection: Selection, dict: CEDict) {
        text = selection.text
        passage = selection.passage
        let tokens = Segmenter.phrase(selection.range, in: selection.passage, dict: dict)
        task = Task { [weak self] in await self?.run(selection, tokens: tokens, dict: dict) }
    }

    private func run(_ selection: Selection, tokens: [PhraseToken], dict: CEDict) async {
        let started = Date()
        // The local model translates slang and idioms far better than Apple's translator;
        // Apple's is the fallback when Ollama isn't running.
        if await LocalModel.isAvailable(),
           let t = try? await LocalModel.translate(selection.text, context: Segmenter.translationContext(for: selection.range, in: selection.passage), dict: dict, partial: { [weak self] in self?.translation = $0; self?.onChange() }) {
            translation = t
        } else if Task.isCancelled {
            return   // a newer selection replaced this one: no second translation
        } else {
            translation = nil   // a stream that broke off mustn't stay up as the translation
            do { translation = try await Translator.translate(selection.text) }
            catch { translationError = error.localizedDescription }
        }
        translationDone = true
        translationMs = Int(Date().timeIntervalSince(started) * 1000)
        onChange()
        guard !Task.isCancelled else { return }
        _ = await PhraseState.resolve(tokens, in: selection.passage, dict: dict, translation: translation, onPick: { [weak self] id, choice in
            self?.picks[id] = choice
            self?.onChange()
        }, onMiss: { [weak self] id, why in
            self?.misses[id] = why
            self?.onChange()
        })
        done = true
        onChange()
    }

    func matches(_ selection: Selection) -> Bool { selection.text == text && selection.passage == passage }

    func finished() async {
        while !done, !(task?.isCancelled ?? false), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func cancel() { task?.cancel() }
}
