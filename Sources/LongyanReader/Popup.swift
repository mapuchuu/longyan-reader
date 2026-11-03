import AppKit
import SwiftUI

/// Everything the popup shows for one lookup. Filled in two steps:
/// dictionary data immediately, then the model's choice when it arrives.
@MainActor
final class LookupState: ObservableObject {
    enum Phase: Equatable { case choosing, chosen, dictionaryOnly(String), failed(String) }

    let context: WordInContext
    let senses: [Sense]
    @Published var phase: Phase
    @Published var choice: SenseChoice?
    @Published var showAllSenses = false
    var onLayoutChange: () -> Void = {}

    /// Set for 的 and 了, which show a fixed line instead of a chosen sense (`senseNumber` 0).
    let grammar: GrammarWord?

    /// Set once the reader picks a meaning; a model answer arriving later doesn't replace it.
    @Published private(set) var userPicked = false
    /// The model's own answer, kept so the reader can go back to it.
    @Published var suggested: SenseChoice?

    /// The reader picks a meaning. Clicking the one already chosen changes nothing (it used
    /// to rewrite the headline from the dictionary gloss, e.g. 理解's "to comprehend;
    /// to understand" became "to comprehend").
    func pick(_ index: Int) {
        guard senses.indices.contains(index), choice?.senseNumber != index + 1 else { return }
        if let suggested, suggested.senseNumber == index + 1 {
            useSuggested()
            return
        }
        userPicked = true
        choice = SenseChoice(senseNumber: index + 1, meaningHere: headlineGloss(senses[index]))
        phase = .chosen
        onLayoutChange()
    }

    /// Back to the model's answer, with its own wording.
    func useSuggested() {
        guard let suggested else { return }
        userPicked = false
        choice = suggested
        phase = .chosen
        onLayoutChange()
    }

    /// True when the headline is the model's reading of this passage rather than dictionary wording.
    var isContextual: Bool {
        guard !userPicked, let choice, let sense = senses[safe: choice.senseNumber - 1] else { return false }
        let text = choice.meaningHere.lowercased()
        return !Gloss.readable(sense.gloss).lowercased().contains(text)
            && !text.contains(headlineGloss(sense).lowercased())
    }

    /// The model's answer arrived: show it unless the reader has already chosen.
    func receive(_ answer: SenseChoice) {
        suggested = answer
        guard !userPicked else { return }
        choice = answer
        phase = .chosen
    }

    init(context: WordInContext, senses: [Sense], phase: Phase) {
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

    var chosenIndex: Int? { choice.map { $0.senseNumber - 1 } }
    var headerPinyin: String {
        if !userPicked, let grammar { return grammar.reading }
        return senses[safe: chosenIndex ?? 0]?.pinyin ?? ""
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Tone colours, muted so they sit quietly on the card: dusty brick, sage, slate and
/// violet in light mode, soft pastels in dark mode. Neutral tone uses the secondary label.
private func tone(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}
let toneColors: [Int: Color] = [
    1: tone(light: (0.66, 0.33, 0.30), dark: (0.89, 0.62, 0.58)),
    2: tone(light: (0.29, 0.53, 0.38), dark: (0.62, 0.80, 0.66)),
    3: tone(light: (0.29, 0.45, 0.65), dark: (0.63, 0.74, 0.89)),
    4: tone(light: (0.50, 0.38, 0.64), dark: (0.76, 0.67, 0.88)),
]
func toneColor(_ t: Int) -> Color { toneColors[t] ?? Color.secondary }

/// Note colours in the same muted family: amber for lost in translation, teal for cultural context.
let lostTint = tone(light: (0.66, 0.44, 0.20), dark: (0.91, 0.74, 0.52))
let cultureTint = tone(light: (0.22, 0.50, 0.52), dark: (0.58, 0.80, 0.80))
func noteTint(_ tag: String) -> Color { tag == "lost_in_translation" ? lostTint : cultureTint }

struct LookupView: View {
    @ObservedObject var state: LookupState
    @Environment(\.cardScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
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
        }
        .animation(cardMotion, value: state.choice?.senseNumber)
        .animation(cardMotion, value: state.phase)
        .animation(cardMotion, value: state.showAllSenses)
        .animation(cardMotion, value: state.userPicked)
    }

    private var header: some View {
        let syllables = Pinyin.syllables(state.headerPinyin)
        return HStack(alignment: .lastTextBaseline, spacing: 10 * scale) {
            HStack(spacing: 0) {
                ForEach(Array(state.context.word.enumerated()), id: \.offset) { i, ch in
                    Text(String(ch)).foregroundStyle(toneColor(syllables[safe: i]?.tone ?? 5))
                }
            }
            .cardFont(30, .medium)
            HStack(spacing: 4) {
                ForEach(Array(syllables.enumerated()), id: \.offset) { _, s in
                    Text(s.text).foregroundStyle(toneColor(s.tone))
                }
            }
            .cardFont(15, .medium)
            .contentTransition(.opacity)
        }
    }

    @ViewBuilder private var meaning: some View {
        if let choice = state.choice {
            VStack(alignment: .leading, spacing: 2) {
                if state.isContextual {
                    Text("In this context").cardFont(11).foregroundStyle(.secondary).transition(.opacity)
                }
                Text(choice.meaningHere)
                    .cardFont(17, .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var status: some View {
        if state.userPicked, let suggested = state.suggested, suggested.senseNumber != state.choice?.senseNumber {
            Button { withAnimation(cardMotion) { state.useSuggested() } } label: {
                Label("Use suggested meaning: \(suggested.meaningHere)", systemImage: "arrow.uturn.backward")
                    .cardFont(11)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .transition(.opacity)
        }
        switch state.phase {
        case .choosing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                .cardFont(12).foregroundStyle(.secondary)
                .transition(.opacity)
        case .dictionaryOnly(let why):
            Text("Dictionary order · \(why)").cardFont(11).foregroundStyle(.secondary)
        case .failed(let why):
            Text("Dictionary order · couldn't place this word in the sentence").cardFont(11).foregroundStyle(.secondary)
                .help(why)
        case .chosen:
            if state.choice?.viaTranslation == true {
                Text("Matched to the sentence translation").cardFont(11).foregroundStyle(.secondary)
            }
        }
    }

    private var senses: some View {
        // A few senses, always including the chosen one; 的 and 了 list only their own reading's.
        let all = Array(state.senses.enumerated())
        let listed = state.grammar?.listed(state.senses)
        let preview = state.senses.preview(chosen: state.chosenIndex)
        let collapsed = all.filter { listed?.contains($0.element) ?? preview.contains($0.offset) || $0.offset == state.chosenIndex }
        let shown = state.showAllSenses ? all : collapsed
        let showReading = Set(state.senses.map(\.pinyin)).count > 1
        return VStack(alignment: .leading, spacing: 6 * scale) {
            SectionLabel(text: "Meanings")
            VStack(alignment: .leading, spacing: 1) {
                ForEach(shown, id: \.offset) { i, sense in
                    let chosen = state.chosenIndex == i
                    let note = NotesStore.hasExactNote(state.context.word, sense)
                        ? NotesStore.note(state.context.word, sense) : nil
                    Button { withAnimation(cardMotion) { state.pick(i) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                            Text("\(i + 1)").cardFont(11, monospacedDigit: true).foregroundStyle(.tertiary)
                                .frame(width: 14 * scale, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                if showReading && (listed == nil || state.showAllSenses) {
                                    Text(Pinyin.marked(sense.pinyin)).cardFont(11).foregroundStyle(.secondary)
                                }
                                Text(listed?.contains(sense) == true ? Gloss.short(sense.gloss) : Gloss.listed(sense.gloss))
                                    .cardFont(13, chosen ? .semibold : .regular)
                                    .foregroundStyle(chosen || state.choice == nil ? .primary : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .help(Gloss.readable(sense.gloss))
                            }
                            Spacer(minLength: 4)
                            if let note {
                                Circle().fill(noteTint(note.tag))
                                    .frame(width: 6 * scale, height: 6 * scale)
                            }
                            if chosen {
                                Image(systemName: "checkmark").cardFont(11, .semibold)
                                    .foregroundStyle(Color.accentColor)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                    }
                    .buttonStyle(CardRowStyle(selected: chosen))
                    .help("Use this meaning")
                }
                if state.senses.count > collapsed.count {
                    Button {
                        withAnimation(cardMotion) { state.showAllSenses.toggle() }
                        state.onLayoutChange()
                    } label: {
                        Text(state.showAllSenses ? "Show less" : "Show \(state.senses.count - collapsed.count) more")
                            .cardFont(12).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(CardRowStyle())
                }
            }
            .padding(3 * scale)
            .background(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous).fill(Color.primary.opacity(0.04)))
            if !state.context.alternatives.isEmpty {
                Text("Also here: " + state.context.alternatives.joined(separator: " · "))
                    .cardFont(11).foregroundStyle(.tertiary)
            }
        }
    }
}

/// A floating panel that never steals focus from the app being read.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Whether a drag starting at this point (window coordinates) moves the card.
    var canMove: (NSPoint) -> Bool = { _ in false }
    /// The card is being dragged: the pointer's screen position, then nil when it's let go.
    var onMove: (NSPoint?) -> Void = { _ in }
    private var pressedAt: NSPoint?
    private var moving = false

    /// Handled here, not with a SwiftUI gesture, because the card's scroll view takes drags
    /// before one would see them. A drag can start anywhere but the grip, rows included: past
    /// a few points it stops being a click, so the row it started on isn't picked.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressedAt = canMove(event.locationInWindow) ? NSEvent.mouseLocation : nil
            moving = false
        case .leftMouseDragged:
            if let pressedAt {
                let mouse = NSEvent.mouseLocation
                if !moving, hypot(mouse.x - pressedAt.x, mouse.y - pressedAt.y) >= 4 {
                    moving = true
                    releaseOutside(event)
                    onMove(pressedAt)
                }
                if moving { onMove(mouse); return }
            }
        case .leftMouseUp:
            pressedAt = nil
            if moving { moving = false; onMove(nil); return }
        default: break
        }
        super.sendEvent(event)
    }

    /// Lets go of whatever was pressed, away from it, so it doesn't count as a click.
    private func releaseOutside(_ event: NSEvent) {
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -1000, y: -1000), modifierFlags: [],
                                       timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                                       eventNumber: event.eventNumber, clickCount: 1, pressure: 0) {
            super.sendEvent(up)
        }
    }
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
    /// Set by the usage simulation so the reader's own clicks and typing elsewhere don't
    /// close its cards mid-check.
    var ignoresOutsideInput = false
    /// Which kind of card is open, and a token that changes with every new card.
    private(set) var kind: CardLayout.Kind?
    private(set) var generation = 0

    /// Shows a card just below `anchor` (the selection, or a small box at the cursor).
    /// The card fades and springs in once its content has been measured. With `holdFor`, it
    /// waits up to that long for `endHold`, so an answer on its way is there when it opens.
    func show<V: View>(_ view: V, kind: CardLayout.Kind, near anchor: NSRect, holdFor hold: TimeInterval = 0) {
        close()
        wasMoved = false
        revealPending = false
        held = hold > 0
        self.anchor = anchor
        let layout = CardLayout(kind: kind)
        self.kind = kind
        generation += 1
        let visible = visibleFrame()
        layout.maxHeight = max(140, visible.height * 0.8)
        let host = FirstMouseHostingView(rootView: CardChrome(layout: layout) { view })
        host.sizingOptions = []        // only `setWindow` sizes the window
        let panel = PopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true   // clicking the card leaves the app being read in focus
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false        // the card draws its own shadow, shaped like the card
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        panel.appearance = CardAppearance.current
        self.panel = panel
        self.hosting = host
        self.layout = layout
        layout.onChange = { [weak self, weak layout] animated in
            self?.applySize(animated: animated)
            if let layout, layout.contentHeight > 0 { self?.measured(layout) }
        }
        panel.onMove = { [weak self] mouse in self?.move(to: mouse) }
        panel.canMove = { [weak self] point in self?.canMove(from: point) ?? false }

        choosePlacement(for: layout)
        applySize(animated: false)
        // Ordered in while still invisible, so SwiftUI measures the content; `reveal` shows it.
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak layout] in
            if let layout { self?.reveal(layout) }
        }
        if hold > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self, weak layout] in
                if let self, self.layout === layout { self.endHold() }
            }
        }

        // Close on a click elsewhere, scrolling (unless the card was dragged aside to read
        // past it), or Esc. Global monitors only see events for other apps, so clicks and
        // drags inside the card are unaffected.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel],
                                                     handler: { [weak self] e in
            guard let self, !self.ignoresOutsideInput else { return }
            if e.type == .scrollWheel { self.scrolledOutside() } else { self.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self, !self.ignoresOutsideInput else { return }
            if e.keyCode == 53 { self.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53 { self?.close(); return nil }
            return e
        }) { monitors.append(m) }
    }

    /// The first measurement: the side can be settled now that the height is known, and
    /// the card shows a frame later, once that has been drawn.
    private func measured(_ layout: CardLayout) {
        guard !layout.appeared else { return }
        choosePlacement(for: layout)
        applySize(animated: false)
        guard !held, !revealPending else { return }
        revealPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self, weak layout] in
            if let layout { self?.reveal(layout) }
        }
    }

    /// Whether the open card has been shown yet.
    var isRevealed: Bool { layout?.appeared ?? true }

    /// Stops holding the card back: it opens a moment later, once its new content is measured.
    func endHold() {
        guard held else { return }
        held = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak layout = self.layout] in
            guard let self, let layout, self.layout === layout, !layout.appeared else { return }
            self.choosePlacement(for: layout)
            self.applySize(animated: false)
            self.reveal(layout)
        }
    }

    /// Fades the window in, which keeps the blur behind the card intact, as the card springs in.
    private func reveal(_ layout: CardLayout) {
        guard self.layout === layout, !layout.appeared, !held, let panel else { return }
        revealPending = false
        panel.displayIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { layout.appeared = true }
    }

    /// Below the selection when the card fits there, else whichever side has more room. The
    /// card scrolls past that room, so it never slides over the selection as it fills in.
    private func choosePlacement(for layout: CardLayout) {
        let visible = visibleFrame()
        let below = anchor.minY - 16 - visible.minY, above = visible.maxY - anchor.maxY - 16
        placedBelow = below >= max(layout.contentHeight, 320) || below >= above
        layout.placedBelow = placedBelow
        fitMaxHeight(layout)
    }

    private func fitMaxHeight(_ layout: CardLayout) {
        let visible = visibleFrame()
        let room = placedBelow ? anchor.minY - 16 - visible.minY : visible.maxY - anchor.maxY - 16
        layout.maxHeight = max(200, min(room, visible.height * 0.8))
    }

    /// The screen showing most of the anchor, else the one with the pointer.
    private func visibleFrame() -> NSRect {
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.frame.intersection(anchor)
            return r.isNull ? 0 : max(r.width * r.height, 1)
        }
        let screens = NSScreen.screens
        if let best = screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best.visibleFrame }
        let mouse = NSEvent.mouseLocation
        return (screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
    }

    private var shrinkWork: DispatchWorkItem?
    private var revealPending = false
    private var held = false

    /// Fits the transparent window around the card plus its shadow margin. The card animates
    /// its own size; the window only changes instantly, growing before an expansion and
    /// shrinking once a contraction has finished, so it never clips the animation and
    /// never animates itself. The edge nearest the selection stays put.
    func applySize(animated: Bool) {
        guard let panel, layout != nil else { return }
        let needed = windowSize()
        let current = panel.frame.size
        shrinkWork?.cancel()
        if animated, needed.height < current.height || needed.width < current.width {
            // Hold the larger window until the card has finished shrinking.
            setWindow(CGSize(width: max(needed.width, current.width), height: max(needed.height, current.height)))
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.panel === panel else { return }
                self.setWindow(self.windowSize())
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
        } else {
            setWindow(needed)
        }
    }

    private func windowSize() -> CGSize {
        guard let layout else { return .zero }
        let m = CardChrome<EmptyView>.margin
        return CGSize(width: layout.width + 2 * m, height: max(layout.height, 1) + 2 * m)
    }

    /// Places the window so the card sits 8 pt from the selection, inside the screen.
    private func setWindow(_ size: CGSize) {
        guard let panel else { return }
        let visible = visibleFrame()
        let m = CardChrome<EmptyView>.margin
        var x = anchor.minX - m
        // Below: the card's top edge is fixed 8 pt under the selection; the window grows down.
        // Above: the card's bottom edge is fixed 8 pt over it; the window grows up.
        var y = placedBelow ? anchor.minY - 8 + m - size.height : anchor.maxY + 8 - m
        x = min(max(x, visible.minX + 8 - m), visible.maxX - size.width + m - 8)
        y = min(max(y, visible.minY + 8 - m), visible.maxY - size.height + m - 8)
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Anywhere on the card except the grip and, when the card scrolls, its scroll bar.
    private func canMove(from point: NSPoint) -> Bool {
        guard let panel, let layout, layout.kind != .hint else { return false }
        let m = CardChrome<EmptyView>.margin
        let card = NSRect(x: m, y: layout.placedBelow ? panel.frame.height - m - layout.height : m,
                          width: layout.width, height: layout.height)
        guard card.contains(point) else { return false }
        if point.x > card.maxX - 22, point.y < card.minY + 22 { return false }
        return layout.contentHeight <= layout.maxHeight || point.x < card.maxX - 16
    }

    private var moveStart: (mouse: NSPoint, anchor: NSRect)?
    private var wasMoved = false

    func scrolledOutside() {
        if !wasMoved { close() }
    }

    /// Dragging the card moves its anchor, so it stays put as its content changes. The next
    /// card gets its own anchor and opens by its word as usual. Nil ends the drag.
    private func move(to mouse: NSPoint?) {
        guard let panel else { return }
        guard let mouse else {
            // Settle on where the card actually is, which may be inside where the pointer went.
            let m = CardChrome<EmptyView>.margin
            anchor.origin.x = panel.frame.minX + m
            anchor.origin.y = placedBelow ? panel.frame.maxY + 8 - m : panel.frame.minY - 8 + m - anchor.height
            moveStart = nil
            if let layout { fitMaxHeight(layout); applySize(animated: true) }
            return
        }
        if moveStart == nil { moveStart = (mouse, anchor) }
        wasMoved = true
        guard let start = moveStart else { return }
        anchor = start.anchor.offsetBy(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y)
        setWindow(panel.frame.size)
    }

    /// Debug: the card window's position.
    var windowOrigin: NSPoint? { panel?.frame.origin }
    var windowFrame: NSRect? { panel?.frame }

    /// Debug: a point on the card's top padding, in screen coordinates.
    var dragHandlePoint: NSPoint? {
        guard let panel, let layout else { return nil }
        let m = CardChrome<EmptyView>.margin
        let top = layout.placedBelow ? panel.frame.maxY - m : panel.frame.minY + m + layout.height
        return NSPoint(x: panel.frame.minX + m + layout.width / 2, y: top - 6)
    }

    /// Switches an open card to the chosen appearance straight away.
    func setAppearance(_ appearance: NSAppearance?) {
        panel?.appearance = appearance
    }

    /// Kept for callers that changed content: the card follows its own size now.
    func reposition() { applySize(animated: true) }

    /// Fades the card out, then removes it.
    func close() {
        if ProcessInfo.processInfo.environment["LONGYAN_TRACE_CLOSE"] != nil || UserDefaults.standard.bool(forKey: "traceClose"), panel != nil {
            let trace = Thread.callStackSymbols.prefix(8).joined(separator: "\n")
            try? trace.write(to: Log.directory.appendingPathComponent("close-trace.txt"), atomically: true, encoding: .utf8)
        }
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
        kind = nil
    }

    /// Redraws the open card, e.g. after switching between Classic and Liquid Glass.
    func refreshStyle() { layout?.objectWillChange.send() }

    /// Debug: the card's surface colour near its top-right corner (above the content),
    /// read from the live view. The glass itself doesn't draw offscreen, but the tint and
    /// the classic wash do, so this tells whether they are present.
    func surfaceSample() -> (alpha: CGFloat, brightness: CGFloat)? {
        guard let hosting, let layout,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let m = CardChrome<EmptyView>.margin
        let scale = CGFloat(rep.pixelsWide) / max(hosting.bounds.width, 1)
        // Top-left origin in the bitmap; the card hangs from the top when placed below.
        let x = (m + layout.width - 34) * scale
        let y = (layout.placedBelow ? m + 8 : hosting.bounds.height - m - layout.height + 8) * scale
        guard let c = rep.colorAt(x: Int(x), y: Int(y))?.usingColorSpace(.sRGB) else { return nil }
        return (c.alphaComponent, c.brightnessComponent)
    }

    /// Debug: whether the window currently has room for the whole card plus its margin.
    var windowFitsCard: Bool {
        guard let panel, let layout else { return true }
        let m = CardChrome<EmptyView>.margin
        return panel.frame.height + 0.5 >= max(layout.height, 1) + 2 * m && panel.frame.width + 0.5 >= layout.width + 2 * m
    }

    var currentLayout: CardLayout? { layout }

    /// Debug: card windows still on screen (should be at most one).
    static var visibleCardWindows: Int {
        NSApp.windows.filter { $0 is PopupPanel && $0.isVisible && $0.alphaValue > 0.01 }.count
    }

    /// Debug: the current window frame and card layout, for checking sizing headlessly.
    var debugState: String {
        guard let panel, let layout else { return "no card" }
        return "frame \(Int(panel.frame.width))x\(Int(panel.frame.height)) at (\(Int(panel.frame.minX)),\(Int(panel.frame.minY))) · card width \(Int(layout.width)) content \(Int(layout.contentHeight)) scale \(String(format: "%.2f", layout.scale)) appeared \(layout.appeared)"
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
        Text(text).cardFont(12).foregroundStyle(.secondary)
    }
}
