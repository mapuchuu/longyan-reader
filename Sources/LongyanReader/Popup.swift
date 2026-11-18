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

    /// The word a lone character belongs to here (彻 in 彻底), with its meaning in the sentence;
    /// for a word of several meanings that arrives after the character's own.
    struct PartOf { let word: String; var pinyin: String; var meaning: String? }
    @Published var partOf: PartOf?
    /// Opens the card for `partOf`'s word.
    var openPartOf: () -> Void = {}

    /// Set for 的 and 了, which show a fixed line instead of a chosen sense (`senseNumber` 0).
    let grammar: GrammarWord?

    /// Set once the reader picks a meaning; a model answer arriving later doesn't replace it.
    @Published private(set) var userPicked = false
    /// The model's own answer, kept so the reader can go back to it.
    @Published var suggested: SenseChoice?
    /// Called when the reader changes the meaning (for History).
    var onUserPick: (SenseChoice) -> Void = { _ in }

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
        onUserPick(choice!)
    }

    /// Back to the model's answer, with its own wording.
    func useSuggested() {
        guard let suggested else { return }
        userPicked = false
        choice = suggested
        phase = .chosen
        onLayoutChange()
        onUserPick(suggested)
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

extension LookupState {
    /// What Copy puts on the clipboard: the word that was looked up, as it appears in the text.
    var copyText: String { context.word }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Tone colours, muted so they sit quietly on the card: dusty brick, sage, slate and
/// violet in light mode, soft pastels in dark mode. Neutral tone uses the secondary label.
func tone(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
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
/// A character's colour: its tone's when tone colours are on, else the primary label.
func hanziColor(_ t: Int) -> Color { ToneColors.enabled ? toneColor(t) : .primary }
/// A pinyin syllable's colour: its tone's when tone colours are on, else the secondary label.
func pinyinColor(_ t: Int) -> Color { ToneColors.enabled ? toneColor(t) : .secondary }

struct LookupView: View {
    /// The dictionary-order reason for a word with no entry; shown on its own, without the prefix.
    static let notInDictionary = "not in dictionary"
    @ObservedObject var state: LookupState
    @Environment(\.cardScale) private var scale

    private var note: StoredNote? {
        state.choice.flatMap { NotesStore.note(state.context.word, state.senses[safe: $0.senseNumber - 1]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m * scale) {
            VStack(alignment: .leading, spacing: Space.xs * scale) {
                header
                meaning
                partOf
                status
            }
            if let note {
                NuanceView(note: note)
                    .transition(.opacity.combined(with: .offset(y: -4 * scale)))
                    .id(note.note)
            }
            senses
        }
        .animation(cardMotion, value: state.choice?.senseNumber)
        .animation(cardMotion, value: state.phase)
        .animation(cardMotion, value: state.showAllSenses)
        .animation(cardMotion, value: state.userPicked)
        .animation(cardMotion, value: state.partOf?.meaning)
    }

    /// The word large, its pinyin beside it on the same baseline, and Copy and Pin at the end
    /// of the line, beside the word they copy. A word too long for that line keeps its size
    /// and takes the line for itself, with the pinyin under it; it never squeezes.
    private var header: some View {
        let syllables = Pinyin.syllables(state.headerPinyin)
        let headword = state.context.word.enumerated().reduce(Text("")) { text, item in
            text + Text(String(item.element)).foregroundStyle(hanziColor(syllables[safe: item.offset]?.tone ?? 5))
        }
        .cardFont(TextSize.headword, .medium)
        let pinyin = syllables.enumerated().reduce(Text("")) { text, item in
            text + Text((item.offset > 0 ? " " : "") + item.element.text).foregroundStyle(pinyinColor(item.element.tone))
        }
        .cardFont(TextSize.title3)
        let slot = ActionSlot(centerAboveBaseline: 12 * scale)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s * scale) {
                headword.fixedSize()
                pinyin.fixedSize().contentTransition(.opacity)
                Spacer(minLength: Space.s * scale)
                slot
            }
            VStack(alignment: .leading, spacing: Space.xxs * scale) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s * scale) {
                    headword.lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: Space.s * scale)
                    slot
                }
                pinyin.fixedSize(horizontal: false, vertical: true).contentTransition(.opacity)
            }
        }
    }

    @ViewBuilder private var meaning: some View {
        if let choice = state.choice {
            VStack(alignment: .leading, spacing: Space.xxs * scale) {
                Text(choice.meaningHere)
                    .cardFont(TextSize.headline, .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                if state.isContextual {
                    Text("Meaning in this sentence").cardFont(TextSize.subheadline).foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var partOf: some View {
        if let part = state.partOf {
            Button { state.openPartOf() } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.xs * scale) {
                    Text("Part of").foregroundStyle(.secondary)
                    Text(part.word).cardFont(TextSize.body, .medium)
                    Text(Pinyin.marked(part.pinyin)).foregroundStyle(.secondary)
                    if let meaning = part.meaning {
                        Text(meaning).lineLimit(1).transition(.opacity)
                    }
                    Image(systemName: "chevron.forward").cardFont(TextSize.footnote, .semibold).foregroundStyle(.tertiary)
                }
                .cardFont(TextSize.callout)
            }
            .buttonStyle(CardRowStyle(bleed: Space.xs, vertical: Space.xxs))
            .fixedSize()
            .help("Look up \(part.word)")
        }
    }

    @ViewBuilder private var status: some View {
        if state.userPicked, let suggested = state.suggested, suggested.senseNumber != state.choice?.senseNumber {
            Button { withAnimation(cardMotion) { state.useSuggested() } } label: {
                Label("Back to “\(suggested.meaningHere)”", systemImage: "arrow.uturn.backward")
                    .cardFont(TextSize.callout)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .transition(.opacity)
        }
        switch state.phase {
        case .choosing:
            HStack(spacing: Space.s * scale) { ProgressView().controlSize(.mini); Text("Reading the sentence…") }
                .cardFont(TextSize.callout).foregroundStyle(.secondary)
                .transition(.opacity)
        case .dictionaryOnly(let why):
            Text(why == Self.notInDictionary ? "Not in the dictionary" : "Dictionary order · \(why)").cardFont(TextSize.subheadline).foregroundStyle(.secondary)
        case .failed(let why):
            Text("Dictionary order · couldn't tell which meaning fits here").cardFont(TextSize.subheadline).foregroundStyle(.secondary)
                .help(why)
        case .chosen:
            if state.choice?.viaTranslation == true {
                Text("Picked to match the translation").cardFont(TextSize.subheadline).foregroundStyle(.secondary)
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
        return VStack(alignment: .leading, spacing: Space.s * scale) {
            CardDivider()
            SectionLabel(text: "Meanings")
            VStack(alignment: .leading, spacing: 0) {
                let headed = showReading && (listed == nil || state.showAllSenses)
                ForEach(Array(shown.enumerated()), id: \.element.offset) { position, item in
                    let (i, sense) = item
                    let chosen = state.chosenIndex == i
                    let hasNote = NotesStore.hasExactNote(state.context.word, sense)
                    if headed && SenseLine.startsReading(shown, at: position) {
                        ReadingHeader(pinyin: sense.pinyin, first: position == 0)
                    }
                    Button { withAnimation(cardMotion) { state.pick(i) } } label: {
                        HStack(alignment: .center, spacing: Space.s * scale) {
                            SenseLine(number: i + 1, total: state.senses.count,
                                      gloss: listed?.contains(sense) == true ? Gloss.short(sense.gloss) : Gloss.listed(sense.gloss),
                                      partOfSpeech: PartOfSpeech.of(sense.gloss),
                                      size: TextSize.body, chosen: chosen, dimmed: !(chosen || state.choice == nil))
                                .help(Gloss.readable(sense.gloss))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if hasNote { NoteMark() }
                            ChoiceMark(chosen: chosen)
                        }
                    }
                    .buttonStyle(CardRowStyle())
                    .help(hasNote ? "Use this meaning · has a note" : "Use this meaning")
                }
                if state.senses.count > collapsed.count {
                    Button {
                        withAnimation(cardMotion) { state.showAllSenses.toggle() }
                        state.onLayoutChange()
                    } label: {
                        HStack(spacing: Space.xs * scale) {
                            Text(state.showAllSenses ? "Show Fewer" : "Show All \(state.senses.count)")
                            Image(systemName: "chevron.down").cardFont(TextSize.footnote, .semibold)
                                .rotationEffect(.degrees(state.showAllSenses ? 180 : 0))
                        }
                        .cardFont(TextSize.callout, .medium).foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(CardRowStyle())
                }
            }
            if !state.context.alternatives.isEmpty {
                Text("Other words here: " + state.context.alternatives.joined(separator: " · "))
                    .cardFont(TextSize.subheadline).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Marks a meaning that has a prewritten note: a small speech-bubble symbol, quiet until read.
struct NoteMark: View {
    var body: some View {
        Image(systemName: "text.bubble")
            .cardFont(TextSize.subheadline)
            .foregroundStyle(.tertiary)
    }
}

/// A floating panel that never steals focus from the app being read.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Whether a drag starting at this point (window coordinates) moves the card.
    var canMove: (NSPoint) -> Bool = { _ in false }
    /// The card is being dragged: the pointer's screen position, then nil when it's let go.
    var onMove: (NSPoint?) -> Void = { _ in }
    /// Any press on the card, before it's handled.
    var onPress: () -> Void = {}
    private var pressedAt: NSPoint?
    private var moving = false

    /// Handled here, not with a SwiftUI gesture, because the card's scroll view takes drags
    /// before one would see them. A drag can start anywhere but the grip, rows included: past
    /// a few points it stops being a click, so the row it started on isn't picked.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            onPress()
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
    /// False for the controller that shows hints beside a pinned card: those always open by
    /// the selection and close as usual.
    var followsPin = true
    private var pinned: Bool { followsPin && CardPin.shared.isOn }
    /// Set for a card opened from inside the open one (彻 → 彻底): it takes that card's place,
    /// hanging from the same top-left corner, as a pinned card's next lookup does.
    private var opensInPlace = false
    /// The open card took the previous one's place, so it hangs from that corner.
    private var hangsInPlace = false
    /// The current card's spot, for a card opened from inside it; nil if none is open.
    private var inPlaceAnchor: NSRect?

    /// The next `show` replaces the open card in its place instead of opening by the selection.
    func nextOpensInPlace() {
        guard panel != nil, let corner = cardTopLeft else { return }
        opensInPlace = true
        inPlaceAnchor = NSRect(x: corner.x, y: corner.y + 8, width: 1, height: 1)
    }
    /// Which kind of card is open, and a token that changes with every new card.
    private(set) var kind: CardLayout.Kind?
    private(set) var generation = 0

    /// Shows a card just below `anchor` (the selection, or a small box at the cursor).
    /// The card fades and springs in once its content has been measured. With `holdFor`, it
    /// waits up to that long for `endHold`, so an answer on its way is there when it opens.
    func show<V: View>(_ view: V, kind: CardLayout.Kind, near anchor: NSRect, holdFor hold: TimeInterval = 0,
                       copyText: (() -> String)? = nil, speech: (() -> SpeechPlan)? = nil) {
        // A new card silences the last one's reading; a hint beside it doesn't.
        if kind != .hint { Speaker.shared.stop() }
        // A pinned card is replaced in place: the old one stays up until the new one is ready.
        // So is a card opened from inside the open one.
        let inPlace = opensInPlace && kind != .hint ? inPlaceAnchor : nil
        opensInPlace = false
        inPlaceAnchor = nil
        let pinned = self.pinned || inPlace != nil
        if pinned, let old = panel {
            swapping?.orderOut(nil)
            swapping = old
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            panel = nil; hosting = nil; layout = nil; self.kind = nil
        } else {
            close()
        }
        wasMoved = false
        revealPending = false
        held = hold > 0
        self.anchor = inPlace ?? (pinned ? (pinnedAnchor ?? anchor) : anchor)
        hangsInPlace = inPlace != nil
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
        layout.copyText = copyText
        layout.speech = Speaker.shared.available ? speech : nil
        layout.togglePin = { [weak self] in self?.togglePin() }
        layout.closeCard = { [weak self] in self?.close() }
        layout.onResize = { [weak self] edges, mouse in self?.resize(edges, to: mouse) }
        layout.onChange = { [weak self, weak layout] animated in
            self?.applySize(animated: animated)
            if let layout, layout.contentHeight > 0 { self?.measured(layout) }
        }
        panel.onMove = { [weak self] mouse in self?.move(to: mouse) }
        panel.canMove = { [weak self] point in self?.canMove(from: point) ?? false }
        panel.onPress = { [weak self] in self?.hangFromTop() }

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
        // past it), or Esc; a pinned card ignores all three. Global monitors only see events
        // for other apps, so clicks and drags inside the card are unaffected.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel],
                                                     handler: { [weak self] e in
            guard let self, !self.ignoresOutsideInput, !self.pinned else { return }
            if e.type == .scrollWheel { self.scrolledOutside() } else { self.close() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            guard let self, !self.ignoresOutsideInput, !self.pinned else { return }
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
        if let old = swapping {
            // Pinned: the new content fades in over the old card, in the same spot, then
            // the old one goes. No spring, since the card hasn't moved.
            swapping = nil
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { layout.appeared = true }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }, completionHandler: { old.orderOut(nil) })
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { layout.appeared = true }
    }

    /// The old card, kept on screen while a pinned card's next content gets ready.
    private var swapping: PopupPanel?

    /// Where a pinned card opens: its saved top-left corner, as the anchor a card hangs below.
    private var pinnedAnchor: NSRect? {
        CardPin.shared.topLeft.map { NSRect(x: $0.x, y: $0.y + 8, width: 1, height: 1) }
    }

    /// The open card's top-left corner on screen.
    private var cardTopLeft: NSPoint? {
        guard let panel, let layout else { return nil }
        let m = CardChrome<EmptyView>.margin
        let top = placedBelow ? panel.frame.maxY - m : panel.frame.minY + m + layout.height
        return NSPoint(x: panel.frame.minX + m, y: top)
    }

    /// Pins the card where it is (it hangs from that corner from now on), or unpins it, when
    /// it stays open until the next click elsewhere, as an unpinned card does.
    func togglePin() {
        let pin = CardPin.shared
        if pin.isOn {
            pin.isOn = false
            return
        }
        guard let corner = cardTopLeft, let layout else { pin.isOn = true; return }
        pin.topLeft = corner
        pin.isOn = true
        anchor = NSRect(x: corner.x, y: corner.y + 8, width: 1, height: 1)
        placedBelow = true
        layout.placedBelow = true
        fitMaxHeight(layout)
        applySize(animated: false)
    }

    /// Once the reader clicks in a card that sits above the selection, it hangs from its top
    /// edge as a card below does: opening a row grows it downward, so the row just clicked
    /// stays under the pointer instead of the whole card climbing (and dropping back as the
    /// row closes). Until then it stands on the selection, so filling in never covers it.
    func hangFromTop() {
        guard !placedBelow, let layout, layout.appeared, let corner = cardTopLeft else { return }
        anchor = NSRect(x: corner.x, y: corner.y + 8, width: 1, height: 1)
        placedBelow = true
        layout.placedBelow = true
        fitMaxHeight(layout)
        applySize(animated: false)
    }

    /// Below the selection when the card fits there, else whichever side has more room. The
    /// card scrolls past that room, so it never slides over the selection as it fills in.
    private func choosePlacement(for layout: CardLayout) {
        let visible = visibleFrame()
        let below = anchor.minY - 16 - visible.minY, above = visible.maxY - anchor.maxY - 16
        placedBelow = pinned || hangsInPlace || below >= max(layout.contentHeight, 320) || below >= above
        layout.placedBelow = placedBelow
        fitMaxHeight(layout)
    }

    private func fitMaxHeight(_ layout: CardLayout) {
        let visible = visibleFrame()
        let room = placedBelow ? anchor.minY - 16 - visible.minY : visible.maxY - anchor.maxY - 16
        // Never taller than its room (down to a small floor), so the screen edge never has to
        // push the card back, which would move it.
        layout.maxHeight = max(120, min(room, visible.height * 0.8))
    }

    private var resizeStart: (mouse: NSPoint, card: NSRect, size: CardLayout.SizeState)?

    /// The side edges set the card's width as a window's do: the grabbed edge follows the
    /// pointer and the opposite one stays put, within the screen and the width limits; the
    /// height follows the content. Corners scale the card, text and all, for reading: the
    /// opposite corner stays put and the dragged one follows the pointer along the card's
    /// diagonal. Nil ends it.
    func resize(_ edges: CardLayout.Edges, to mouse: NSPoint?) {
        guard let layout else { return }
        guard let mouse else {
            resizeStart = nil
            layout.endResize()
            if pinned, let corner = cardTopLeft { CardPin.shared.topLeft = corner }
            fitMaxHeight(layout)
            applySize(animated: false)
            return
        }
        if resizeStart == nil {
            guard let card = cardScreenRect else { return }
            resizeStart = (mouse, card, layout.sizeState)
            layout.beginResize()
            wasMoved = true
        }
        guard let start = resizeStart else { return }
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        let visible = visibleFrame().insetBy(dx: 8, dy: 8)
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
        var minX = start.card.minX, maxX = start.card.maxX, minY = start.card.minY, maxY = start.card.maxY
        if edges.count2 {
            let w = start.card.width, h = start.card.height
            let outX = edges.contains(.right) ? dx : -dx, outY = edges.contains(.bottom) ? -dy : dy
            let applied = layout.scaleCard(from: start.size, by: 1 + (outX * w + outY * h) / (w * w + h * h))
            let newW = layout.width, newH = h * applied
            if edges.contains(.left) { minX = maxX - newW } else { maxX = minX + newW }
            if edges.contains(.top) { maxY = minY + newH } else { minY = maxY - newH }
            anchor.origin.x = minX
            anchor.origin.y = placedBelow ? maxY + 8 : minY - 8 - anchor.height
            fitMaxHeight(layout)
            applySize(animated: false)
            return
        }
        if edges.contains(.right) { maxX = minX + clamp(start.card.width + dx, CardLayout.minWidth, min(CardLayout.maxWidth, visible.maxX - minX)) }
        if edges.contains(.left) { minX = maxX - clamp(start.card.width - dx, CardLayout.minWidth, min(CardLayout.maxWidth, maxX - visible.minX)) }
        layout.width = maxX - minX
        // The card hangs from its anchor (below the selection) or stands on it (above).
        anchor.origin.x = minX
        anchor.origin.y = placedBelow ? maxY + 8 : minY - 8 - anchor.height
        fitMaxHeight(layout)
        applySize(animated: false)
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

    /// Anywhere on the card except its side edges and corners, which resize it.
    private func canMove(from point: NSPoint) -> Bool {
        guard let panel, let layout, layout.kind != .hint else { return false }
        let m = CardChrome<EmptyView>.margin
        let card = NSRect(x: m, y: layout.placedBelow ? panel.frame.height - m - layout.height : m,
                          width: layout.width, height: layout.height)
        // Not from the side edges' resize bands, or the corners.
        var inner = card.insetBy(dx: ResizeHandles.inside, dy: 0)
        inner.size.width -= ResizeHandles.rightInside - ResizeHandles.inside
        guard inner.contains(point) else { return false }
        let c = ResizeHandles.corner - ResizeHandles.outside
        let nearX = point.x < card.minX + c || point.x > card.maxX - c
        let nearY = point.y < card.minY + c || point.y > card.maxY - c
        // The bottom-right corner, the one people reach for, is bigger than the others.
        let b = ResizeHandles.bigCorner - ResizeHandles.outside
        if point.x > card.maxX - b && point.y < card.minY + b { return false }
        return !(nearX && nearY)
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
            if pinned, let corner = cardTopLeft { CardPin.shared.topLeft = corner }
            if let layout { fitMaxHeight(layout); applySize(animated: true) }
            return
        }
        if moveStart == nil { moveStart = (mouse, anchor) }
        wasMoved = true
        guard let start = moveStart else { return }
        anchor = start.anchor.offsetBy(dx: mouse.x - start.mouse.x, dy: mouse.y - start.mouse.y)
        setWindow(panel.frame.size)
    }

    /// Debug: whether the card hangs below its anchor (top edge fixed).
    var isPlacedBelow: Bool { placedBelow }

    /// Debug: the card itself on screen (AppKit coordinates).
    var cardScreenRect: NSRect? {
        guard let panel, let layout else { return nil }
        let m = CardChrome<EmptyView>.margin
        let y = layout.placedBelow ? panel.frame.maxY - m - layout.height : panel.frame.minY + m
        return NSRect(x: panel.frame.minX + m, y: y, width: layout.width, height: layout.height)
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
        if kind != nil && kind != .hint { Speaker.shared.stop() }
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        swapping?.orderOut(nil)
        swapping = nil
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

    /// Debug: whether the card shows a scroll bar that takes width from its content (the
    /// kind macOS uses with a mouse, or with "Show scroll bars: Always").
    var scrollBarTakesWidth: Bool {
        guard let hosting else { return false }
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            if let s = v as? NSScrollView { return [s] }
            return v.subviews.flatMap(scrollViews)
        }
        return scrollViews(hosting).contains { s in
            s.scrollerStyle == .legacy && s.hasVerticalScroller && s.verticalScroller.map { !$0.isHidden } == true
        }
    }

    /// Debug: scrolls the open card's content to `y`.
    func debugScroll(to y: CGFloat) {
        guard let hosting else { return }
        func scrollViews(_ v: NSView) -> [NSScrollView] {
            if let s = v as? NSScrollView { return [s] }
            return v.subviews.flatMap(scrollViews)
        }
        for s in scrollViews(hosting) {
            s.contentView.scroll(to: NSPoint(x: 0, y: y))
            s.reflectScrolledClipView(s.contentView)
        }
    }

    /// Debug: writes the open card's window, as drawn, to a PNG.
    func saveImage(to url: URL) {
        guard let hosting, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
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
        guard let card = cardScreenRect else { return }
        let start = NSPoint(x: card.maxX, y: card.minY)
        for step in 0...10 {
            let t = CGFloat(step) / 10
            resize([.bottom, .right], to: NSPoint(x: start.x + dx * t, y: start.y + dy * t))
        }
        resize([.bottom, .right], to: nil)
    }

    /// Debug: resizes from edges the way a hand would, over about a second at 60 steps a
    /// second. `d` is outward: right/left/down/up for those edges.
    func debugEdgeDrag(_ edges: CardLayout.Edges, by d: CGFloat) {
        guard let card = cardScreenRect else { return }
        let origin = NSPoint(x: edges.contains(.left) ? card.minX : card.maxX, y: edges.contains(.top) ? card.maxY : card.minY)
        let steps = 60
        for step in 0...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) / 60) { [weak self] in
                guard let self else { return }
                let t = CGFloat(step) / CGFloat(steps)
                let e = t * t * (3 - 2 * t)   // ease in and out, like a hand starting and stopping
                let x = edges.contains(.right) ? d * e : edges.contains(.left) ? -d * e : 0
                let y = edges.contains(.top) ? d * e : edges.contains(.bottom) ? -d * e : 0
                self.resize(edges, to: NSPoint(x: origin.x + x, y: origin.y + y))
                if step == steps { self.resize(edges, to: nil) }
            }
        }
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
