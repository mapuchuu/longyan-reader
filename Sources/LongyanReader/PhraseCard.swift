import SwiftUI

/// A highlighted phrase: a translation on top, then each word with a quick gloss.
/// Clicking a word asks the sense chooser what it means in this passage.
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
    var onLayoutChange: () -> Void = {}

    init(selection: Selection, dict: CEDict, sourceNote: String?) {
        self.selection = selection
        self.sourceNote = sourceNote
        let tokens = Segmenter.phrase(selection.range, in: selection.passage, dict: dict)
        self.tokens = tokens
        var senses: [Int: [Sense]] = [:]
        for t in tokens { senses[t.id] = dict.senses(for: t.text) }
        self.senses = senses
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
    func gloss(_ token: PhraseToken) -> String {
        if let c = choices[token.id] { return c.meaningHere }
        let list = senses[token.id] ?? []
        if let i = translationSense[token.id], list.indices.contains(i) { return shortGloss([list[i]]) }
        return shortGloss(list)
    }

    /// The prewritten note for the sense this word currently shows, if any.
    func note(_ token: PhraseToken) -> StoredNote? {
        let list = senses[token.id] ?? []
        let shown = choices[token.id].map { $0.senseNumber - 1 } ?? translationSense[token.id] ?? 0
        return NotesStore.note(token.text, list[safe: shown])
    }

    func toggle(_ token: PhraseToken) {
        expanded = expanded == token.id ? nil : token.id
        defer { onLayoutChange() }
        guard expanded == token.id, choices[token.id] == nil, !choosing.contains(token.id),
              let list = senses[token.id], !list.isEmpty, SenseChooser.isAvailable else { return }
        choosing.insert(token.id)
        Task {
            do {
                let choice = try await SenseChooser.choose(
                    for: Segmenter.context(for: token.range, in: selection.passage), senses: list)
                withAnimation(.smooth(duration: 0.3)) { choices[token.id] = choice }
            } catch {
                failures[token.id] = "Dictionary order: couldn't place this word in the sentence"
            }
            choosing.remove(token.id)
            onLayoutChange()
        }
    }
}

/// The first dictionary sense, shortened for a one-line gloss.
func shortGloss(_ senses: [Sense]?) -> String {
    guard let gloss = senses?.first?.gloss else { return "—" }
    // Drop leading notes like "(bound form)" or "(third-person singular)" when words follow.
    var text = gloss
    while text.hasPrefix("("), let close = text.firstIndex(of: ")") {
        let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { break }
        text = rest
    }
    let first = text.split(separator: ";").first.map(String.init) ?? text
    return first.count > 42 ? String(first.prefix(40)) + "…" : first
}

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
        let shown = state.choices[token.id].map { $0.senseNumber - 1 } ?? state.translationSense[token.id] ?? 0
        let syllables = Pinyin.syllables(senses[safe: shown]?.pinyin ?? "")
        let isOpen = state.expanded == token.id
        let dim = particleWords.contains(token.text)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.25)) { state.toggle(token) } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HStack(spacing: 0) {
                        ForEach(Array(token.text.enumerated()), id: \.offset) { i, ch in
                            Text(String(ch)).foregroundStyle(toneColor(syllables[safe: i]?.tone ?? 5))
                        }
                    }
                    .cardFont(17, .medium)
                    .frame(minWidth: 46 * scale, alignment: .leading)
                    Text(syllables.map(\.text).joined(separator: " "))
                        .cardFont(11).foregroundStyle(.secondary)
                        .frame(minWidth: 70 * scale, alignment: .leading)
                    Text(state.gloss(token))
                        .cardFont(13, state.choices[token.id] == nil ? .regular : .semibold)
                        .foregroundStyle(dim ? .secondary : .primary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer(minLength: 4)
                    if let note = state.note(token) {
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
            if state.choosing.contains(token.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                    .cardFont(12).foregroundStyle(.secondary)
            } else if let f = state.failures[token.id] {
                Text(f).cardFont(11).foregroundStyle(.secondary)
            } else if state.choices[token.id]?.viaTranslation == true {
                Text("Matched to the sentence translation").cardFont(11).foregroundStyle(.secondary)
            }
            if let note = state.note(token) {
                NuanceView(note: note).transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(senses.prefix(5).enumerated()), id: \.offset) { i, sense in
                    let chosen = state.choices[token.id].map { $0.senseNumber == i + 1 } ?? (state.translationSense[token.id] == i)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "checkmark").cardFont(9, .bold)
                            .foregroundStyle(Color.accentColor).opacity(chosen ? 1 : 0)
                        Text(sense.gloss)
                            .cardFont(12, chosen ? .semibold : .regular)
                            .foregroundStyle(chosen ? .primary : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if senses.isEmpty { Text("Not in the dictionary").cardFont(12).foregroundStyle(.secondary) }
        }
        .padding(.leading, 12 * scale).padding(.trailing, 8 * scale).padding(.top, 6 * scale).padding(.bottom, 10 * scale)
    }

    private var footer: some View {
        let parts = [state.selection.appName, state.sourceNote].compactMap { $0 } + ["Click a word for its meaning here"]
        return Text(parts.joined(separator: " · "))
            .cardFont(10).foregroundStyle(.tertiary)
    }
}
