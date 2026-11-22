import LongyanCore
import SwiftUI

/// The widest word column among a phrase card's rows, so every row's meaning starts at the same x.
private struct WordColumnKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PhraseView: View {
    var state: PhraseState
    @Environment(\.cardScale) private var scale
    /// Read so the card redraws when the tone colours change.
    @Environment(\.toneRevision) private var toneRevision
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
            // Nothing to list (a selection of only punctuation): no empty Words section.
            if !state.tokens.isEmpty {
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
            let shown = SenseLine.byReading(all ? Array(senses.enumerated()) : collapsed)
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
                    .accessibilityAddTraits(chosen ? .isSelected : [])
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
