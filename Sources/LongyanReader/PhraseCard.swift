import SwiftUI

/// A highlighted phrase: a translation on top, then each word with its meaning in this
/// passage, chosen for every word before the card opens (see `PhrasePrep`).
@MainActor
final class PhraseState: ObservableObject {
    let selection: Selection
    let tokens: [PhraseToken]
    let senses: [Int: [Sense]]
    let sourceNote: String?
    @Published var translation: String? { didSet { alignToTranslation() } }
    /// For each word, the sense that agrees with the translation (until the model has chosen).
    @Published var translationSense: [Int: Int] = [:]
    @Published var translationError: String?
    @Published var expanded: Int?
    @Published var choices: [Int: SenseChoice] = [:]
    @Published var choosing: Set<Int> = []
    @Published var failures: [Int: String] = [:]
    /// True while the model is still picking the words' senses; those rows show a placeholder.
    @Published var resolving = false
    /// Words whose meaning the reader picked; a model answer arriving later doesn't replace it.
    private(set) var userPicked: Set<Int> = []
    var onLayoutChange: () -> Void = {}

    func pick(_ token: PhraseToken, sense index: Int) {
        guard let list = senses[token.id], list.indices.contains(index) else { return }
        // Clicking the meaning already shown changes nothing.
        guard shownSense(token) != index else { return }
        userPicked.insert(token.id)
        choices[token.id] = SenseChoice(senseNumber: index + 1, meaningHere: headlineGloss(list[index]))
        onLayoutChange()
    }

    init(selection: Selection, dict: CEDict, sourceNote: String?) {
        self.selection = selection
        self.sourceNote = sourceNote
        let tokens = Segmenter.phrase(selection.range, in: selection.passage, dict: dict)
        self.tokens = tokens
        var senses: [Int: [Sense]] = [:]
        for t in tokens { senses[t.id] = dict.senses(for: t.text) }
        self.senses = senses
    }

    /// Takes the senses chosen up front; the reader's own picks stay.
    func apply(_ picks: [Int: SenseChoice]) {
        for (id, choice) in picks where !userPicked.contains(id) { choices[id] = choice }
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
        for (id, choice) in prep.picks where choices[id] == nil && !userPicked.contains(id) {
            withAnimation(.smooth(duration: 0.25)) { choices[id] = choice }
        }
        if resolving != !prep.done { withAnimation(.smooth(duration: 0.25)) { resolving = !prep.done } }
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
        resolving && choices[token.id] == nil && (senses[token.id]?.count ?? 0) > 1
    }

    /// Words worth asking the model about: those with more than one dictionary sense
    /// (particles included: 了 is "le" here, not "liǎo").
    static func ambiguous(_ tokens: [PhraseToken], dict: CEDict) -> [PhraseToken] {
        tokens.filter { dict.senses(for: $0.text).count > 1 }
    }

    /// Chooses the in-context sense of every ambiguous word at once, so the card opens with
    /// each row already resolved instead of changing when the reader opens it.
    static func resolve(_ tokens: [PhraseToken], in passage: [Character], dict: CEDict, translation: String? = nil,
                        onPick: @MainActor (Int, SenseChoice) -> Void = { _, _ in }) async -> [Int: SenseChoice] {
        let words = ambiguous(tokens, dict: dict)
        guard SenseChooser.isAvailable, let lo = words.first?.range.lowerBound, let hi = words.last?.range.upperBound else { return [:] }
        var out: [Int: SenseChoice] = [:]
        // The local model takes them all in one streamed request (in chunks, to stay inside its
        // context window): Ollama answers one request at a time, so word-by-word calls queue.
        if await LocalModel.isAvailable() {
            let sentence = Segmenter.context(for: lo..<hi, in: passage).sentence
            var start = 0
            while start < words.count {
                let chunk = Array(words[start..<min(start + 8, words.count)])
                start += chunk.count
                let lists = chunk.map { (word: $0.text, senses: dict.senses(for: $0.text)) }
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
                // This model misreads grammar words (地 "-ly", 我吃了饭 "to finish"), and their
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
        case "了": return index(atEnd ? "(modal particle indicating change" : "(completed action marker)")
        default: return nil
        }
    }

    private func alignToTranslation() {
        guard let translation else { return }
        for t in tokens {
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
        let list = senses[token.id] ?? []
        guard let i = shownSense(token), list.indices.contains(i) else { return shortGloss(list) }
        return shortGloss([list[i]])
    }

    /// Index of the sense the row shows: the reader's or model's choice, else the one that
    /// fits the translation, else the first.
    func shownSense(_ token: PhraseToken) -> Int? {
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
        guard expanded == token.id, !resolving, choices[token.id] == nil, !choosing.contains(token.id),
              let list = senses[token.id], !list.isEmpty, SenseChooser.isAvailable else { return }
        choosing.insert(token.id)
        Task {
            do {
                let choice = try await SenseChooser.choose(
                    for: Segmenter.context(for: token.range, in: selection.passage), senses: list)
                if !userPicked.contains(token.id) {
                    withAnimation(.smooth(duration: 0.3)) { choices[token.id] = choice }
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
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Words")
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(state.tokens.prefix(maxRows)) { token in row(token) }
                    if state.tokens.count > maxRows {
                        Text("+\(state.tokens.count - maxRows) more words")
                            .cardFont(11).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
            footer
        }
        .animation(.smooth(duration: 0.25), value: state.expanded)
        .animation(.smooth(duration: 0.25), value: state.translation)
        .animation(.smooth(duration: 0.25), value: state.choices.count)
        .animation(.smooth(duration: 0.25), value: state.choosing)
        .animation(.smooth(duration: 0.3), value: state.resolving)
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
            Button { withAnimation(.smooth(duration: 0.25)) { state.toggle(token) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
            if let note = state.note(token) {
                NuanceView(note: note).transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(senses.prefix(5).enumerated()), id: \.offset) { i, sense in
                    let chosen = state.shownSense(token) == i
                    Button { withAnimation(.smooth(duration: 0.25)) { state.pick(token, sense: i) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark").cardFont(9, .bold)
                                .foregroundStyle(Color.accentColor).opacity(chosen ? 1 : 0)
                            Text(Gloss.readable(sense.gloss))
                                .cardFont(12, chosen ? .semibold : .regular)
                                .foregroundStyle(chosen ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .buttonStyle(CardRowStyle())
                    .help("Use this meaning")
                }
            }
            if senses.isEmpty { Text("Not in the dictionary").cardFont(12).foregroundStyle(.secondary) }
        }
        .padding(.leading, 12 * scale).padding(.trailing, 8 * scale).padding(.top, 6 * scale).padding(.bottom, 10 * scale)
    }

    private var footer: some View {
        let parts = [state.selection.appName, state.sourceNote].compactMap { $0 } + [state.choices.isEmpty ? "Click a word for its meaning here" : "Click a word for its other meanings"]
        return Text(parts.joined(separator: " · "))
            .cardFont(10).foregroundStyle(.tertiary)
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
