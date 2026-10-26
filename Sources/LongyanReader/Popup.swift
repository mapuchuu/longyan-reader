import AppKit
import SwiftUI

/// Everything the popup shows for one lookup. Filled in two steps:
/// dictionary data immediately, then the model's choice when it arrives.
@MainActor
final class LookupState: ObservableObject {
    enum Phase: Equatable { case choosing, chosen, dictionaryOnly(String), failed(String) }

    let context: WordInContext
    let senses: [Sense]
    let sourceNote: String?        // e.g. "copied selection, no surrounding text"
    let appName: String?
    @Published var phase: Phase
    @Published var choice: SenseChoice?
    @Published var showAllSenses = false
    var onLayoutChange: () -> Void = {}

    /// The reader overrides the chosen sense by clicking it.
    func pick(_ index: Int) {
        guard senses.indices.contains(index) else { return }
        choice = SenseChoice(senseNumber: index + 1, meaningHere: shortGloss([senses[index]]))
        phase = .chosen
        onLayoutChange()
    }

    init(context: WordInContext, senses: [Sense], sourceNote: String? = nil, appName: String?, phase: Phase) {
        self.context = context
        self.senses = senses
        self.sourceNote = sourceNote
        self.appName = appName
        self.phase = phase
    }

    var chosenIndex: Int? { choice.map { $0.senseNumber - 1 } }
    var headerPinyin: String { senses[safe: chosenIndex ?? 0]?.pinyin ?? "" }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Tone colours, from the system palette so they sit right in light and dark mode.
let toneColors: [Int: Color] = [
    1: Color(nsColor: .systemRed), 2: Color(nsColor: .systemGreen),
    3: Color(nsColor: .systemBlue), 4: Color(nsColor: .systemPurple),
]
func toneColor(_ t: Int) -> Color { toneColors[t] ?? Color.secondary }

struct LookupView: View {
    @ObservedObject var state: LookupState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                meaning
                status
            }
            if let choice = state.choice,
               let note = NotesStore.note(state.context.word, state.senses[safe: choice.senseNumber - 1]) {
                NuanceView(note: note)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    .id(note.note)
            }
            senses
            passage
        }
        .animation(.smooth(duration: 0.25), value: state.choice?.senseNumber)
        .animation(.smooth(duration: 0.25), value: state.phase)
        .animation(.smooth(duration: 0.25), value: state.showAllSenses)
    }

    private var header: some View {
        let syllables = Pinyin.syllables(state.headerPinyin)
        return HStack(alignment: .lastTextBaseline, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(state.context.word.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch)).foregroundStyle(toneColor(syllables[safe: i]?.tone ?? 5))
                }
            }
            .font(.system(size: 30, weight: .semibold))
            HStack(spacing: 4) {
                ForEach(Array(syllables.enumerated()), id: \.offset) { _, s in
                    Text(s.text).foregroundStyle(toneColor(s.tone))
                }
            }
            .font(.system(size: 15, weight: .medium))
            .contentTransition(.opacity)
        }
    }

    @ViewBuilder private var meaning: some View {
        if let choice = state.choice {
            Text(choice.meaningHere)
                .font(.system(size: 17, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var status: some View {
        switch state.phase {
        case .choosing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .transition(.opacity)
        case .dictionaryOnly(let why):
            Text("Dictionary order · \(why)").font(.system(size: 11)).foregroundStyle(.secondary)
        case .failed(let why):
            Text("Dictionary order · couldn't place this word in the sentence").font(.system(size: 11)).foregroundStyle(.secondary)
                .help(why)
        case .chosen:
            if state.choice?.viaTranslation == true {
                Text("Matched to the sentence translation").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var senses: some View {
        // The first seven senses, plus the chosen one if it sits further down.
        let all = Array(state.senses.enumerated())
        let shown = state.showAllSenses ? all
            : all.filter { $0.offset < 7 || $0.offset == state.chosenIndex }
        let showReading = Set(state.senses.map(\.pinyin)).count > 1
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Meanings")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(shown, id: \.offset) { i, sense in
                    let chosen = state.chosenIndex == i
                    let note = NotesStore.hasExactNote(state.context.word, sense)
                        ? NotesStore.note(state.context.word, sense) : nil
                    Button { withAnimation(.smooth(duration: 0.25)) { state.pick(i) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                                .frame(width: 14, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                if showReading {
                                    Text(Pinyin.marked(sense.pinyin)).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text(sense.gloss)
                                    .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                                    .foregroundStyle(chosen || state.choice == nil ? .primary : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            if let note {
                                Circle().fill(note.tag == "lost_in_translation" ? Color.orange : Color.teal)
                                    .frame(width: 6, height: 6)
                            }
                            if chosen {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .buttonStyle(CardRowStyle(selected: chosen))
                    .help("Use this meaning")
                }
                if state.senses.count > shown.count {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { state.showAllSenses = true }
                        state.onLayoutChange()
                    } label: {
                        Text("Show \(state.senses.count - shown.count) more")
                            .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(CardRowStyle())
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            if !state.context.alternatives.isEmpty {
                Text("Also here: " + state.context.alternatives.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    private var passage: some View {
        let sentence = state.context.sentence
        let parts = sentence.components(separatedBy: state.context.word)
        var text = Text("")
        for (i, part) in parts.enumerated() {
            text = text + Text(part)
            if i < parts.count - 1 { text = text + Text(state.context.word).fontWeight(.semibold).foregroundColor(.primary) }
        }
        let where_ = [state.appName, state.sourceNote].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.15)).frame(width: 2)
            VStack(alignment: .leading, spacing: 3) {
                text.font(.system(size: 12)).foregroundColor(.secondary).lineLimit(4)
                if !where_.isEmpty { Text(where_).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A floating panel that never steals focus from the app being read.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets the first click land on a control instead of just focusing the panel.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class PopupController {
    private var panel: PopupPanel?
    private var hosting: NSView?
    private var layout: CardLayout?
    private var anchor: NSRect = .zero        // AppKit coordinates
    private var placedBelow = true
    private var monitors: [Any] = []
    var isShowing: Bool { panel != nil }

    /// Shows a card just below `anchor` (the selection, or a small box at the cursor).
    /// The card fades and springs in once its content has been measured.
    func show<V: View>(_ view: V, kind: CardLayout.Kind, near anchor: NSRect) {
        close()
        self.anchor = anchor
        let layout = CardLayout(kind: kind)
        let visible = visibleFrame()
        layout.maxHeight = max(CardLayout.minSize.height, visible.height * 0.8)
        let host = FirstMouseHostingView(rootView: CardChrome(layout: layout) { view })
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
        self.layout = layout
        layout.onChange = { [weak self] animated in self?.applySize(animated: animated) }

        placedBelow = anchor.minY - 8 - 200 >= visible.minY
        applySize(animated: false)
        panel.orderFrontRegardless()

        // Let SwiftUI measure the content, size the window to it, then animate in.
        DispatchQueue.main.async { [weak self, weak layout] in
            guard let self, let layout, self.layout === layout else { return }
            self.applySize(animated: false)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { layout.appeared = true }
        }

        // Close on a click elsewhere, scrolling, or Esc. Global monitors only see
        // events for other apps, so clicks and drags inside the card are unaffected.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel],
                                                     handler: { [weak self] _ in self?.close() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }) { monitors.append(m) }
    }

    private func visibleFrame() -> NSRect {
        (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    /// Sizes the window to the card. The edge nearest the selection stays put, so the
    /// card grows away from the text; size changes animate unless the reader is dragging.
    func applySize(animated: Bool) {
        guard let panel, let layout else { return }
        let visible = visibleFrame()
        let size = CGSize(width: layout.width, height: max(layout.height, 1))
        var x = anchor.minX
        var y = placedBelow ? anchor.minY - 8 - size.height : anchor.maxY + 8
        if placedBelow, y < visible.minY + 8 {
            // Grown past the bottom of the screen: slide up rather than flip sides.
            y = visible.minY + 8
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        guard frame != panel.frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak panel] in panel?.invalidateShadow() })
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    /// Kept for callers that changed content: the card follows its own size now.
    func reposition() { applySize(animated: true) }

    /// Fades the card out, then removes it.
    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let old = panel {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                old.animator().alphaValue = 0
            }, completionHandler: { old.orderOut(nil) })
        }
        panel = nil
        hosting = nil
        layout = nil
    }

    /// Debug: the current window frame and card layout, for checking sizing headlessly.
    var debugState: String {
        guard let panel, let layout else { return "no card" }
        return "frame \(Int(panel.frame.width))x\(Int(panel.frame.height)) at (\(Int(panel.frame.minX)),\(Int(panel.frame.minY))) · card width \(Int(layout.width)) content \(Int(layout.contentHeight)) userHeight \(layout.userHeight.map { "\(Int($0))" } ?? "auto") appeared \(layout.appeared)"
    }

    /// Debug: drive the corner grip as if dragged by (dx, dy) screen points.
    func debugDrag(dx: CGFloat, dy: CGFloat) {
        guard let panel, let layout else { return }
        let start = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        for step in 0...10 {
            let t = CGFloat(step) / 10
            layout.resize(to: NSPoint(x: start.x + dx * t, y: start.y + dy * t))
        }
        layout.endResize()
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
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
    }
}
