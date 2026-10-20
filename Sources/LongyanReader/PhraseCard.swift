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
                choices[token.id] = try await SenseChooser.choose(
                    for: Segmenter.context(for: token.range, in: selection.passage), senses: list)
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
    private let maxRows = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.selection.text)
                .font(.system(size: 15))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            translation
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                ForEach(state.tokens.prefix(maxRows)) { token in row(token) }
                if state.tokens.count > maxRows {
                    Text("+\(state.tokens.count - maxRows) more words").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            footer
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    }

    @ViewBuilder private var translation: some View {
        if let t = state.translation {
            Text(t).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        } else if let e = state.translationError {
            Text("No translation (\(e))").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Translating…") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private func row(_ token: PhraseToken) -> some View {
        let senses = state.senses[token.id] ?? []
        let shown = state.choices[token.id].map { $0.senseNumber - 1 } ?? state.translationSense[token.id] ?? 0
        let syllables = Pinyin.syllables(senses[safe: shown]?.pinyin ?? "")
        let isOpen = state.expanded == token.id
        let dim = particleWords.contains(token.text)
        return VStack(alignment: .leading, spacing: 6) {
            Button { state.toggle(token) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(Array(token.text.enumerated()), id: \.offset) { i, ch in
                            Text(String(ch)).foregroundStyle(toneColor(syllables[safe: i]?.tone ?? 5))
                        }
                    }
                    .font(.system(size: 17, weight: .medium))
                    .frame(minWidth: 44, alignment: .leading)
                    Text(syllables.map(\.text).joined(separator: " "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .leading)
                    if let note = state.note(token) {
                        Circle().fill(note.tag == "lost_in_translation" ? Color.orange : Color.teal)
                            .frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    }
                    Text(state.gloss(token))
                        .font(.system(size: 13, weight: state.choices[token.id] == nil ? .regular : .semibold))
                        .foregroundStyle(dim ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOpen ? Color.accentColor.opacity(0.12) : .clear))
            }
            .buttonStyle(.plain)
            if isOpen { detail(token, senses: senses) }
        }
    }

    @ViewBuilder private func detail(_ token: PhraseToken, senses: [Sense]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.choosing.contains(token.id) {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the sentence…") }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let f = state.failures[token.id] {
                Text(f).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if state.choices[token.id]?.viaTranslation == true {
                Text("Matched to the sentence translation").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let note = state.note(token) { NuanceView(note: note) }
            ForEach(Array(senses.prefix(5).enumerated()), id: \.offset) { i, sense in
                let chosen = state.choices[token.id].map { $0.senseNumber == i + 1 } ?? (state.translationSense[token.id] == i)
                Text(sense.gloss)
                    .font(.system(size: 12, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if senses.isEmpty { Text("Not in the dictionary").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .padding(.leading, 14).padding(.bottom, 4)
    }

    private var footer: some View {
        let parts = [state.selection.appName, state.sourceNote].compactMap { $0 }
        return Text(parts.joined(separator: " · ") + (parts.isEmpty ? "" : " · ") + "click a word for its meaning here")
            .font(.system(size: 10)).foregroundStyle(.tertiary)
    }
}
