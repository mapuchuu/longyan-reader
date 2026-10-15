import AppKit
import SwiftUI

/// Everything the popup shows for one lookup. Filled in two steps:
/// dictionary data immediately, then the model's choice when it arrives.
@MainActor
final class LookupState: ObservableObject {
    enum Phase: Equatable { case choosing, chosen, dictionaryOnly(String), failed(String) }

    let context: WordInContext
    let senses: [Sense]
    let source: CapturedText.Source
    let appName: String?
    @Published var phase: Phase
    @Published var choice: SenseChoice?

    init(context: WordInContext, senses: [Sense], source: CapturedText.Source, appName: String?, phase: Phase) {
        self.context = context
        self.senses = senses
        self.source = source
        self.appName = appName
        self.phase = phase
    }

    var chosenIndex: Int? { choice.map { $0.senseNumber - 1 } }
    var headerPinyin: String { senses[safe: chosenIndex ?? 0]?.pinyin ?? "" }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

let toneColors: [Int: Color] = [
    1: Color(red: 0.75, green: 0.22, blue: 0.17), 2: Color(red: 0.15, green: 0.68, blue: 0.38),
    3: Color(red: 0.16, green: 0.50, blue: 0.73), 4: Color(red: 0.56, green: 0.27, blue: 0.68),
]
func toneColor(_ t: Int) -> Color { toneColors[t] ?? Color(red: 0.53, green: 0.53, blue: 0.50) }

struct LookupView: View {
    @ObservedObject var state: LookupState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let choice = state.choice {
                Text(choice.meaningHere).font(.system(size: 15, weight: .semibold))
                if choice.tag != .none, !choice.note.isEmpty { nuance(choice) }
            }
            status
            Divider()
            senses
            if !state.context.alternatives.isEmpty {
                Text("Also in this spot: " + state.context.alternatives.joined(separator: "  "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            passage
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12)))
    }

    private var header: some View {
        let syllables = Pinyin.syllables(state.headerPinyin)
        return HStack(alignment: .lastTextBaseline, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(state.context.word.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch)).foregroundStyle(toneColor(syllables[safe: i]?.tone ?? 5))
                }
            }
            .font(.system(size: 28, weight: .medium))
            HStack(spacing: 4) {
                ForEach(Array(syllables.enumerated()), id: \.offset) { _, s in
                    Text(s.text).foregroundStyle(toneColor(s.tone))
                }
            }
            .font(.system(size: 15))
        }
    }

    private func nuance(_ choice: SenseChoice) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(choice.tag == .lostInTranslation ? "LOST IN TRANSLATION" : "CULTURAL CONTEXT")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(choice.tag == .lostInTranslation ? Color.orange : Color.teal)
            Text(choice.note).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var status: some View {
        switch state.phase {
        case .choosing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading the sentence…") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .dictionaryOnly(let why):
            Text("Dictionary order only (\(why))").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let why):
            Text("Couldn't choose a sense: \(why)").font(.system(size: 11)).foregroundStyle(.secondary)
        case .chosen:
            EmptyView()
        }
    }

    private var senses: some View {
        let shown = Array(state.senses.enumerated().prefix(7))
        let showReading = Set(state.senses.map(\.pinyin)).count > 1
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.offset) { i, sense in
                let chosen = state.chosenIndex == i
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                    if showReading {
                        Text(Pinyin.marked(sense.pinyin)).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(sense.gloss)
                        .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                        .foregroundStyle(chosen || state.choice == nil ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(chosen ? Color.accentColor.opacity(0.14) : .clear))
            }
            if state.senses.count > shown.count {
                Text("+\(state.senses.count - shown.count) more").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var passage: some View {
        let sentence = state.context.sentence
        let parts = sentence.components(separatedBy: state.context.word)
        var text = Text("")
        for (i, part) in parts.enumerated() {
            text = text + Text(part)
            if i < parts.count - 1 { text = text + Text(state.context.word).bold().foregroundColor(.primary) }
        }
        let where_ = [state.appName, state.source == .ocr ? "read from screen" : nil].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 3) {
            text.font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3)
            if !where_.isEmpty { Text(where_).font(.system(size: 10)).foregroundStyle(.tertiary) }
        }
    }
}

/// A floating panel that never steals focus from the app being read.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupController {
    private var panel: PopupPanel?
    private var hosting: NSView?
    private var anchor: NSPoint = .zero
    private var monitors: [Any] = []

    func show<V: View>(_ view: V, at mouse: NSPoint) {
        close()
        anchor = mouse
        let host = NSHostingView(rootView: view)
        let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        self.panel = panel
        self.hosting = host
        reposition()
        panel.orderFrontRegardless()

        let dismiss: (NSEvent) -> Void = { [weak self] _ in self?.close() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel], handler: dismiss) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }   // Esc
            return e
        }) { monitors.append(m) }
    }

    /// Sizes to the content and keeps the top edge just below the cursor
    /// (or above it when there's no room below).
    func reposition() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var x = anchor.x - 24
        var y = anchor.y - 18 - size.height
        if y < visible.minY { y = anchor.y + 18 }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    /// PNG of the current popup, for checking output without looking at the screen.
    func snapshot(to url: URL) {
        guard let hosting, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Small transient message when there's nothing to look up.
struct HintView: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
    }
}
