import SwiftUI

/// A highlighted phrase: a translation on top, then each word with its meaning in this
/// passage, chosen for every word before the card opens (see `PhrasePrep`).
@MainActor
final class PhraseState: ObservableObject {
    let selection: Selection
    let tokens: [PhraseToken]
    let senses: [Int: [Sense]]
    @Published var translation: String? { didSet { alignToTranslation() } }
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
        if translation != prep.translation { translation = prep.translation }
        if prep.translationDone, prep.translation == nil { translationError = prep.translationError }
        for (id, choice) in prep.picks where suggested[id] == nil { suggested[id] = choice }
        for (id, choice) in prep.picks where choices[id] == nil && !userPicked.contains(id) {
            withAnimation(cardMotion) { choices[id] = choice }
        }
        if resolving != !prep.done { withAnimation(cardMotion) { resolving = !prep.done } }
        // Streaming updates come in quickly; resize the card at most every 80 ms.
        guard !layoutPending else { return }
        layoutPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.layoutPending = false
            self?.onLayoutChange()
        }
    }

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
    static func resolve(_ tokens: [PhraseToken], in passage: [Character], dict: CEDict, translation: String? = nil,
                        onPick: @MainActor (Int, SenseChoice) -> Void = { _, _ in }) async -> [Int: SenseChoice] {
        var words = ambiguous(tokens, in: passage, dict: dict)
        guard SenseChooser.isAvailable else { return [:] }
        var out: [Int: SenseChoice] = [:]
        words.removeAll { t in
            let list = dict.senses(for: t.text)
            guard let n = NoteCues.senseNumber(t.text, at: t.range, in: passage, senses: list) else { return false }
            let choice = SenseChoice(senseNumber: n, meaningHere: headlineGloss(list[n - 1]))
            out[t.id] = choice
            onPick(t.id, choice)
            return true
        }
        guard let lo = words.first?.range.lowerBound, let hi = words.last?.range.upperBound else { return out }
        // The local model takes them all in one streamed request (in chunks, to stay inside its
        // context window): Ollama answers one request at a time, so word-by-word calls queue.
        if await LocalModel.isAvailable() {
            let sentence = Segmenter.context(for: lo..<hi, in: passage).sentence
            var start = 0
            while start < words.count {
                let chunk = Array(words[start..<min(start + 8, words.count)])
                start += chunk.count
                let lists = chunk.map { (word: $0.text, senses: dict.senses(for: $0.text, limit: CEDict.modelSenseLimit)) }
                func choice(_ i: Int, _ n: Int) -> SenseChoice {
                    SenseChoice(senseNumber: n, meaningHere: headlineGloss(lists[i].senses[n - 1]))
                }
                guard let picks = try? await LocalModel.chooseAll(passage: sentence, words: lists,
                                                                  onPick: { i, n in onPick(chunk[i].id, choice(i, n)) })
                else { continue }
                for (i, n) in picks.enumerated() { out[chunk[i].id] = choice(i, n) }
            }
            if !out.isEmpty || ProcessInfo.processInfo.environment["LONGYAN_BATCH_ONLY"] == "1" { return out }
        }
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
            return out
        }
    }

    /// The sense of a grammar word, when its position gives it away.
    static func grammarSense(_ t: PhraseToken, tokens: [PhraseToken], passage: [Character], senses: [Sense]) -> Int? {
        func index(_ prefix: String) -> Int? { senses.firstIndex { $0.gloss.hasPrefix(prefix) } }
        let i = tokens.firstIndex { $0.id == t.id } ?? 0
        let previous = i > 0 && tokens[i - 1].range.upperBound == t.range.lowerBound ? tokens[i - 1].text : nil
        // After a pronoun these are verbs: 他得了感冒, 我得走了, 我过春节.
        let afterVerb = previous != nil && !["我", "你", "他", "她", "它", "我们", "你们", "他们", "她们"].contains(previous!)
        let atEnd = t.range.upperBound >= passage.count || !(isCJK(passage[t.range.upperBound]) || passage[t.range.upperBound].isLetter)
        switch t.text {
        case "地": return index("structural particle")
        case "得" where afterVerb && !atEnd && passage[t.range.upperBound] != "了": return index("structural particle")
        case "过" where afterVerb: return index("(experienced action marker)")
        case "着" where afterVerb: return index("aspect particle")
        default: return nil
        }
    }

    private func alignToTranslation() {
        guard let translation else { return }
        for t in tokens where grammarEntry(t) == nil {
            if let list = senses[t.id], let i = SenseChooser.senseMatching(translation: translation, senses: list, word: t.text) {
                translationSense[t.id] = i
            }
        }
    }

    /// The gloss to show on a word's row: the model's meaning, else the sense that
    /// fits the translation, else the first dictionary sense.
    /// The row's gloss is always the dictionary wording of the meaning the row shows, so it
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

    func toggle(_ token: PhraseToken) {
        expanded = expanded == token.id ? nil : token.id
        defer { onLayoutChange() }
        guard expanded == token.id, grammarEntry(token) == nil, !resolving, choices[token.id] == nil, !choosing.contains(token.id),
              let list = senses[token.id], !list.isEmpty, SenseChooser.isAvailable else { return }
        choosing.insert(token.id)
        Task {
            do {
                let choice = try await SenseChooser.choose(
                    for: Segmenter.context(for: token.range, in: selection.passage), senses: list)
                suggested[token.id] = choice
                if !userPicked.contains(token.id) {
                    withAnimation(cardMotion) { choices[token.id] = choice }
                }
            } catch {
                failures[token.id] = "Dictionary order: couldn't place this word in the sentence"
            }
            choosing.remove(token.id)
            onLayoutChange()
        }
    }
}

/// The first dictionary sense, as one short meaning for a row.
func shortGloss(_ senses: [Sense]?) -> String {
    senses?.first.map { Gloss.short($0.gloss) } ?? "—"
}

/// A sense's first meaning, for the word card's headline.
func headlineGloss(_ sense: Sense) -> String { Gloss.short(sense.gloss) }

let particleWords: Set<String> = ["的", "了", "和", "是", "在", "也", "都", "就", "与", "或", "但", "而", "对", "于",
                                  "把", "被", "让", "给", "从", "到", "着", "过", "吗", "呢", "吧", "啊", "嗯", "呀", "地", "得"]

struct PhraseView: View {
    @ObservedObject var state: PhraseState
    @Environment(\.cardScale) private var scale
    private let maxRows = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                translation
                Text(state.selection.text)
                    .cardFont(14)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6 * scale) {
                SectionLabel(text: "Words")
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(state.tokens.prefix(maxRows)) { token in row(token) }
                    if state.tokens.count > maxRows {
                        Text("+\(state.tokens.count - maxRows) more words")
                            .cardFont(11).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
                .padding(3 * scale)
                .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(Color.primary.opacity(0.04)))
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
            Text(t).cardFont(17, .semibold)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else if let e = state.translationError {
            Text("No translation · \(e)").cardFont(11).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Translating…") }
                .cardFont(12).foregroundStyle(.secondary)
                .transition(.opacity)
        }
    }

    private func row(_ token: PhraseToken) -> some View {
        let senses = state.senses[token.id] ?? []
        let syllables = Pinyin.syllables(senses[safe: state.shownSense(token) ?? 0]?.pinyin ?? "")
        let isOpen = state.expanded == token.id
        let dim = particleWords.contains(token.text)
        let pending = state.pending(token)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(cardMotion) { state.toggle(token) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
                    HStack(spacing: 0) {
                        ForEach(Array(token.text.enumerated()), id: \.offset) { i, ch in
                            Text(String(ch)).foregroundStyle(pending ? Color.secondary : toneColor(syllables[safe: i]?.tone ?? 5))
                        }
                    }
                    .cardFont(17, .medium)
                    .frame(minWidth: 46 * scale, alignment: .leading)
                    Text(syllables.map(\.text).joined(separator: " "))
                        .cardFont(11).foregroundStyle(.secondary)
                        .frame(minWidth: 70 * scale, alignment: .leading)
                        .redacted(reason: pending ? .placeholder : [])
                    Text(state.gloss(token))
                        .cardFont(13)
                        .foregroundStyle(dim ? .secondary : .primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .redacted(reason: pending ? .placeholder : [])
                        .opacity(pending ? 0.6 : 1)
                        .contentTransition(.opacity)
                    Spacer(minLength: 4)
                    if !pending, let note = state.note(token) {
                        Circle().fill(noteTint(note.tag))
                            .frame(width: 6 * scale, height: 6 * scale)
                    }
                    Image(systemName: "chevron.right")
                        .cardFont(10, .semibold)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .buttonStyle(CardRowStyle(selected: isOpen))
            if isOpen {
                detail(token, senses: senses)
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    @ViewBuilder private func detail(_ token: PhraseToken, senses: [Sense]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if state.pending(token) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                    .cardFont(12).foregroundStyle(.secondary)
            } else if state.choosing.contains(token.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                    .cardFont(12).foregroundStyle(.secondary)
            } else if let f = state.failures[token.id] {
                Text(f).cardFont(11).foregroundStyle(.secondary)
            } else if state.choices[token.id]?.viaTranslation == true {
                Text("Matched to the sentence translation").cardFont(11).foregroundStyle(.secondary)
            } else if let here = state.meaningHere(token) {
                (Text("In this context: ").foregroundColor(.secondary) + Text(here).fontWeight(.medium))
                    .cardFont(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if state.canUseSuggested(token), let meaning = state.suggestedMeaning(token) {
                Button { withAnimation(cardMotion) { state.useSuggested(token) } } label: {
                    Label("Use suggested meaning: \(meaning)", systemImage: "arrow.uturn.backward")
                        .cardFont(11)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .transition(.opacity)
            }
            if let note = state.note(token) {
                NuanceView(note: note).transition(.opacity)
            }
            let listed = state.grammarEntry(token)?.listed(senses)
            let all = state.showingAll.contains(token.id)
            let preview = senses.preview(chosen: state.shownSense(token))
            let collapsed = Array(senses.enumerated()).filter { (listed?.contains($0.element) ?? preview.contains($0.offset)) || (listed != nil && state.grammar(token) == nil && $0.offset == state.shownSense(token)) }
            let shown = all ? Array(senses.enumerated()) : collapsed
            let showReading = Set(shown.map(\.element.pinyin)).count > 1
            VStack(alignment: .leading, spacing: 0) {
                ForEach(shown, id: \.offset) { i, sense in
                    let chosen = state.grammar(token) == nil && state.shownSense(token) == i
                    Button { withAnimation(cardMotion) { state.pick(token, sense: i) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark").cardFont(9, .bold)
                                .foregroundStyle(Color.accentColor).opacity(chosen ? 1 : 0)
                            if showReading {
                                Text(Pinyin.marked(sense.pinyin)).cardFont(11).foregroundStyle(.tertiary)
                            }
                            Text(listed?.contains(sense) == true ? Gloss.short(sense.gloss) : Gloss.listed(sense.gloss))
                                .cardFont(12, chosen ? .semibold : .regular)
                                .foregroundStyle(chosen ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(Gloss.readable(sense.gloss))
                        }
                    }
                    .buttonStyle(CardRowStyle())
                    .help("Use this meaning")
                }
                if senses.count > collapsed.count {
                    Button {
                        withAnimation(cardMotion) {
                            if all { state.showingAll.remove(token.id) } else { state.showingAll.insert(token.id) }
                        }
                        state.onLayoutChange()
                    } label: {
                        Text(all ? "Show less" : "Show \(senses.count - collapsed.count) more").cardFont(12).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(CardRowStyle())
                }
            }
            if senses.isEmpty { Text("Not in the dictionary").cardFont(12).foregroundStyle(.secondary) }
        }
        .padding(.leading, 12 * scale).padding(.trailing, 8 * scale).padding(.top, 6 * scale).padding(.bottom, 10 * scale)
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
           let t = try? await LocalModel.translate(selection.text, partial: { [weak self] in self?.translation = $0; self?.onChange() }) {
            translation = t
        } else {
            do { translation = try await Translator.translate(selection.text) }
            catch { translationError = String(describing: error).prefix(60).description }
        }
        translationDone = true
        translationMs = Int(Date().timeIntervalSince(started) * 1000)
        onChange()
        guard !Task.isCancelled else { return }
        _ = await PhraseState.resolve(tokens, in: selection.passage, dict: dict, translation: translation) { [weak self] id, choice in
            self?.picks[id] = choice
            self?.onChange()
        }
        done = true
        onChange()
    }

    func matches(_ selection: Selection) -> Bool { selection.text == text && selection.passage == passage }

    func finished() async {
        while !done, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func cancel() { task?.cancel() }
}
