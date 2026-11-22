import AppKit
import SwiftUI

/// Size and appearance state for one popup card. The window follows it.
/// Dragging an edge changes the width; dragging a corner scales the text and spacing too.
/// The height always fits the content (scrolling only past the screen limit).
@MainActor
final class CardLayout: ObservableObject {
    enum Kind: String { case word, phrase, hint }

    let kind: Kind
    /// Text size: every font, gap and inset on the card is multiplied by it. One zoom for
    /// every card, so word and phrase cards always have the same text size. Pinch to change.
    @Published var zoom: CGFloat
    /// Card width in points. The trailing edge sets it; the text rewraps at the same size.
    @Published var width: CGFloat
    /// Natural height of the content at the current width and zoom.
    @Published var contentHeight: CGFloat = 0
    @Published var appeared = false

    var maxHeight: CGFloat = 640
    var onChange: (_ animated: Bool) -> Void = { _ in }
    /// The highlighted text, for Copy; nil hides the button (hints).
    var copyText: (() -> String)?
    /// What Listen reads; nil hides the button (hints, or no Chinese voice installed).
    var speech: (() -> SpeechPlan)?
    /// Add to Anki; nil hides the button (Anki isn't open with AnkiConnect, or a hint).
    var anki: AnkiButtonModel?
    /// How many buttons the first line keeps room for: Listen, Copy and Pin, and Anki.
    var actionCount: Int { anki == nil ? 3 : 4 }
    var togglePin: () -> Void = {}
    var closeCard: () -> Void = {}
    /// While an edge is dragged or the card pinched, size changes follow the hand with no animation.
    @Published private(set) var isResizing = false
    /// Whether the card hangs below the selection (top edge fixed) or sits above it.
    @Published var placedBelow = true
    /// Whether the card is scrolled short of the end of its content (the bottom edge fades).
    @Published var moreBelow = false
    /// Whether it's scrolled past the top (the top edge fades, under Copy and Pin).
    @Published var moreAbove = false

    static let defaultWidth: [Kind: CGFloat] = [.word: 360, .phrase: 390, .hint: 260]
    static let scaleRange: ClosedRange<CGFloat> = 0.8...2.2
    static let zoomKey = "card.zoom"
    private var widthKey: String { "card.width.\(kind.rawValue)" }
    static let minWidth: CGFloat = 240, maxWidth: CGFloat = 1000

    var baseWidth: CGFloat { Self.defaultWidth[kind] ?? 360 }
    var scale: CGFloat { kind == .hint ? 1 : zoom }

    init(kind: Kind) {
        self.kind = kind
        let base = Self.defaultWidth[kind] ?? 360
        let saved = UserDefaults.standard.double(forKey: Self.zoomKey)
        let z = kind != .hint && saved > 0 ? min(max(saved, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) : 1
        zoom = z
        let defaults = UserDefaults.standard
        let savedWidth = kind == .hint ? 0 : defaults.double(forKey: "card.width.\(kind.rawValue)")
        width = savedWidth > 0 ? savedWidth : base * z
    }

    /// The card's height: always its content's, growing downward as content arrives, up to
    /// the screen (past that it scrolls). Never set by hand.
    var height: CGFloat { min(contentHeight, maxHeight) }

    func reportContentHeight(_ h: CGFloat) {
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        onChange(appeared && !isResizing)
    }

    // MARK: Resizing from any edge or corner, as a window does

    /// Which edges a resize moves: one for an edge, two for a corner.
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
        /// A corner: one side edge and one of the top and bottom.
        var count2: Bool { !isDisjoint(with: [.left, .right]) && !isDisjoint(with: [.top, .bottom]) }
    }

    /// Set by the popup controller, which owns where the card is: the pointer's position for
    /// each step of a resize, then nil when it's let go.
    var onResize: (_ edges: Edges, _ mouse: NSPoint?) -> Void = { _, _ in }

    func beginResize() { isResizing = true }

    func endResize() {
        isResizing = false
        save()
        onChange(false)
    }

    // MARK: Text size

    typealias SizeState = (zoom: CGFloat, width: CGFloat)
    var sizeState: SizeState { (zoom, width) }
    private var pinchStart: SizeState?

    /// Pinching zooms the text, and the card with it, so it keeps its shape.
    func magnify(by m: CGFloat) {
        if pinchStart == nil { pinchStart = sizeState; isResizing = true }
        guard let start = pinchStart else { return }
        setZoom(start.zoom * m, from: start)
    }

    func endMagnify() {
        pinchStart = nil
        isResizing = false
        save()
        onChange(false)
    }

    /// Bigger or Smaller Text from the menu: a step of about 10%.
    func stepZoom(_ steps: Int) {
        setZoom(zoom * pow(1.1, CGFloat(steps)), from: sizeState)
        save()
        onChange(true)
    }

    /// Scales the text and the card together from `start`, as dragging a corner does.
    /// Returns the factor actually applied, after the zoom limits.
    @discardableResult
    func scaleCard(from start: SizeState, by f: CGFloat) -> CGFloat {
        let z = min(max(start.zoom * f, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let applied = z / start.zoom
        zoom = z
        width = min(max(start.width * applied, Self.minWidth), Self.maxWidth)
        return applied
    }

    private func setZoom(_ z: CGFloat, from start: SizeState) {
        zoom = min(max(z, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let f = zoom / start.zoom
        width = min(max(start.width * f, Self.minWidth), Self.maxWidth)
        if pinchStart != nil { onChange(false) }
    }

    /// Double-click on a side edge: the default width; on a corner (which scales): actual
    /// size. Actual Size from the menu too.
    func resetSize(_ edges: Edges = [.right, .bottom], zoomToo: Bool = false) {
        if zoomToo { zoom = 1 }
        width = baseWidth * zoom
        save()
        onChange(true)
    }

    private func save() {
        guard kind != .hint else { return }
        let d = UserDefaults.standard
        // The zoom is shared: the other kind of card keeps its shape at the new text size.
        let oldZoom = d.double(forKey: Self.zoomKey)
        let ratio = oldZoom > 0 ? zoom / oldZoom : zoom
        if abs(ratio - 1) > 0.001 {
            for other in [Kind.word, .phrase] where other != kind {
                let key = "card.width.\(other.rawValue)"
                let v = d.double(forKey: key)
                if v > 0 { d.set(v * ratio, forKey: key) }
            }
        }
        d.set(Double(zoom), forKey: Self.zoomKey)
        d.set(Double(width), forKey: widthKey)
    }
}

/// Whether cards stay put: a pinned card opens where it was left (drag it anywhere, the
/// spot is remembered), new lookups replace its content in place, and only its close
/// button or Esc on the card closes it.
@MainActor
final class CardPin: ObservableObject {
    static let shared = CardPin()
    private static let onKey = "card.pinned", spotKey = "card.pinnedTopLeft"

    @Published var isOn: Bool { didSet { UserDefaults.standard.set(isOn, forKey: Self.onKey) } }
    /// The card's top-left corner on screen (AppKit coordinates).
    var topLeft: NSPoint? {
        didSet {
            if let p = topLeft { UserDefaults.standard.set(NSStringFromPoint(p), forKey: Self.spotKey) }
        }
    }

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
        topLeft = UserDefaults.standard.string(forKey: Self.spotKey).map(NSPointFromString)
    }
}

/// Every change inside a card uses this, so the content and the card's edge move together:
/// a critically damped spring, the feel of system popovers and disclosure rows.
let cardMotion = Animation.spring(response: 0.34, dampingFraction: 1)

/// The cards' spacing scale (points at 1× zoom): every gap and inset is one of these.
enum Space {
    static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 20
}

/// Text sizes, after macOS's own text styles (body 13, callout 12, footnote 10, title3 15,
/// title2 17), with the headword and translation a step larger.
enum TextSize {
    static let headword: CGFloat = 34, headline: CGFloat = 19, translation: CGFloat = 16
    static let rowWord: CGFloat = 18, title3: CGFloat = 15, body: CGFloat = 13, callout: CGFloat = 12
    static let subheadline: CGFloat = 11, footnote: CGFloat = 10
}

/// How much the card is zoomed; every card font and fixed size multiplies by it.
private struct CardScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var cardScale: CGFloat {
        get { self[CardScaleKey.self] }
        set { self[CardScaleKey.self] = newValue }
    }
}

/// A system font sized for the card's zoom.
struct CardFont: ViewModifier {
    @Environment(\.cardScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let monospacedDigit: Bool
    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    func cardFont(_ size: CGFloat, _ weight: Font.Weight = .regular, monospacedDigit: Bool = false) -> some View {
        modifier(CardFont(size: size, weight: weight, monospacedDigit: monospacedDigit))
    }
}

/// Classic (material with a clean surface) or Liquid Glass, chosen in the menu.
enum CardStyle: String {
    case classic, glass
    /// Liquid Glass needs macOS 26; below that cards are always classic.
    static var current: CardStyle {
        guard isGlassAvailable else { return .classic }
        return CardStyle(rawValue: UserDefaults.standard.string(forKey: "cardStyle") ?? "") ?? .classic
    }
    static var isGlassAvailable: Bool { if #available(macOS 26, *) { true } else { false } }
}

extension View {
    /// The glass effect where there is one (macOS 26); CardStyle never asks for it below that.
    @ViewBuilder func liquidGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
        }
    }
}

/// The light/dark choice from the menu: nil follows the system.
enum CardAppearance {
    static var current: NSAppearance? {
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }
}

/// The card's surface over the material: near-white in light mode, near-black in dark.
func cardSurface(opaque: Bool) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: opaque ? 1 : 0.78)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: opaque ? 1 : 0.80)
    })
}

/// Set when drawing a card to a PNG: the translucent material doesn't render offscreen.
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var renderingSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// The translucent popover material, masked to a continuous rounded rectangle so the
/// window shadow follows the corners.
struct MaterialBackground: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.mask(radius: radius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    static func mask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The frame every card sits in: background (classic material or Liquid Glass), scrolling
/// when the card is smaller than its content, the corner grip, a shadow drawn with the
/// card's own shape, and the spring-in on appear.
///
/// Size changes animate here, in SwiftUI, never by animating the window: the window is
/// a transparent frame with room for the shadow, resized instantly around the card
/// (growing before an expansion, shrinking after a contraction), so no rectangular
/// window edge or stale window shadow can flash during a change.
struct CardChrome<Content: View>: View {
    @ObservedObject var layout: CardLayout
    @Environment(\.renderingSnapshot) private var snapshot
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    /// Where the content's first line keeps room for Copy and Pin (its centre, from the top
    /// of the content), so they line up with that line however the card is zoomed.
    @State private var actionsY: CGFloat?
    let content: Content
    static var radius: CGFloat { 16 }
    /// Transparent space around the card for its shadow.
    static var margin: CGFloat { 28 }
    static var sizeAnimation: Animation { cardMotion }

    init(layout: CardLayout, @ViewBuilder content: () -> Content) {
        self.layout = layout
        self.content = content()
    }

    private var glassStyle: Bool { CardStyle.current == .glass && !snapshot }
    private var shapeRadius: CGFloat { glassStyle ? Self.radius + 4 : Self.radius }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: shapeRadius, style: .continuous)
    }

    var body: some View {
        if snapshot {
            card(padded)
        } else {
            card(scrolling)
                .frame(width: layout.width, height: max(layout.height, 1), alignment: .top)
                // Not until it's shown, or the card would grow from nothing as it appears.
                .animation(layout.appeared && !layout.isResizing ? Self.sizeAnimation : nil, value: layout.height)
                .onHover { hovering = $0 }
                // Pinch to zoom the text, as in Safari and Preview.
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { layout.magnify(by: $0.magnification) }
                        .onEnded { _ in layout.endMagnify() },
                    including: layout.kind == .hint ? .subviews : .all
                )
                // The side edges set the width and the corners scale the card, from bands
                // straddling the edge, as on a window.
                .overlay { if layout.kind != .hint { ResizeHandles(layout: layout) } }
                .overlay(alignment: .topLeading) {
                    if layout.kind != .hint { CloseBadge(layout: layout, cardHovered: hovering) }
                }
                .background(CardShadow(radius: shapeRadius))
                .scaleEffect(layout.appeared ? 1 : 0.96, anchor: layout.placedBelow ? .top : .bottom)
                .offset(y: layout.appeared ? 0 : (layout.placedBelow ? -4 : 4))
                .padding(Self.margin)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: layout.placedBelow ? .topLeading : .bottomLeading)
        }
    }

    private var padded: some View {
        content
            .environment(\.cardScale, layout.scale)
            .environment(\.toneRevision, ToneColors.revision)
            .environment(\.cardActionCount, layout.actionCount)
            .padding(.horizontal, Space.l * layout.scale)
            .padding(.top, Space.l * layout.scale)
            .padding(.bottom, Space.m * layout.scale)
            .frame(width: layout.width, alignment: .leading)
            .coordinateSpace(.named(ActionSlot.space))
            .onPreferenceChange(ActionSlotKey.self) { y in MainActor.assumeIsolated { actionsY = y } }
    }

    /// Top of the Copy and Pin buttons, from the top of the card.
    private var actionsTop: CGFloat? {
        actionsY.map { $0 - ActionSlot.height / 2 }
    }

    /// Copy and Pin, fixed in the top-right corner over the room the first line keeps for
    /// them, so they stay put when the card scrolls; the content fades out beneath them.
    @ViewBuilder private var actions: some View {
        if layout.kind != .hint, let top = actionsTop {
            CardActions(layout: layout, cardHovered: hovering)
                .padding(.top, top)
                // The last symbol's right edge on the content's right edge.
                .padding(.trailing, Space.l * layout.scale - ActionSlot.glyphInset)
        }
    }

    private var scrolling: some View {
        ScrollView(.vertical) {
            padded.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        // Never a scroll bar: with a mouse attached (or "Show scroll bars: Always") it takes
        // width from the content, shoving the card's contents left the moment a row opens
        // past the bottom. The card still scrolls, and its bottom edge fades out while
        // there's more below.
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentSize.height - g.visibleRect.maxY > 2
        } action: { _, more in
            layout.moreBelow = more
        }
        .onScrollGeometryChange(for: Bool.self) { g in
            g.contentOffset.y + g.contentInsets.top > 1
        } action: { _, scrolled in
            layout.moreAbove = scrolled
        }
        .mask {
            // Scrolled down, the content clears the band under Copy and Pin and fades in
            // below it, as content does under a toolbar; it fades out at the bottom while
            // there's more below.
            let band = layout.moreAbove ? (actionsTop.map { $0 + ActionSlot.height } ?? 0) : 0
            VStack(spacing: 0) {
                Color.clear.frame(height: band)
                LinearGradient(colors: [.black.opacity(layout.moreAbove ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14 * layout.scale)
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(layout.moreBelow ? 0 : 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 36 * layout.scale)
            }
            .animation(.easeOut(duration: 0.2), value: layout.moreBelow)
            .animation(.easeOut(duration: 0.2), value: layout.moreAbove)
        }
        .onPreferenceChange(HeightKey.self) { h in
            MainActor.assumeIsolated { layout.reportContentHeight(h) }
        }
    }

    /// Background, clipping and grip. Everything is clipped to the rounded shape, so no
    /// row highlight or scrolling content can show past the corners mid-animation.
    @ViewBuilder private func card(_ view: some View) -> some View {
        if glassStyle {
            // The tint is a fill layer of the card itself, resolved for the current light or
            // dark mode: as a tint on the glass effect it dropped out when a selection
            // re-rendered the card.
            view
                .background(shape.fill(glassTint(colorScheme)))
                .clipShape(shape)
                .liquidGlass(in: shape)
                .overlay(alignment: .topTrailing) { actions }
                .overlay(alignment: .bottomTrailing) { grip.padding(5) }
                .overlay(alignment: .trailing) { edgeGrabber }
        } else {
            view
                .background {
                    if snapshot {
                        shape.fill(cardSurface(opaque: true))
                    } else {
                        // The popover material alone reads grey; a soft white (near-black in
                        // dark mode) wash over it keeps a little translucency but looks clean.
                        ZStack {
                            MaterialBackground(radius: Self.radius)
                            shape.fill(cardSurface(opaque: false))
                        }
                    }
                }
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) { actions }
                .overlay(alignment: .bottomTrailing) { grip.padding(3) }
                .overlay(alignment: .trailing) { edgeGrabber }
                .clipShape(shape)
        }
    }

    /// The bottom-right corner's grip, while the pointer is on the card: a hint that the card
    /// resizes. Every edge and corner does (see `ResizeHandles`).
    @ViewBuilder private var grip: some View {
        if layout.kind != .hint {
            ResizeGrip(hovering: layout.isResizing)
                .opacity(hovering || layout.isResizing ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .allowsHitTesting(false)
        }
    }

    /// A short bar at the middle of the right edge, while the pointer is on the card: that
    /// edge drags the card wider or narrower.
    @ViewBuilder private var edgeGrabber: some View {
        if layout.kind != .hint && layout.height > 60 {
            Capsule()
                .fill(Color.primary.opacity(layout.isResizing ? 0.4 : 0.2))
                .frame(width: 3, height: min(22, layout.height * 0.3))
                .padding(.trailing, 3)
                .opacity(hovering || layout.isResizing ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .allowsHitTesting(false)
        }
    }
}

/// The card's shadow, drawn from its outline alone so its text isn't re-blurred on every
/// frame of a resize. Cut out under the card, where it would show through the translucency.
struct CardShadow: View {
    let radius: CGFloat

    private struct Outside: Shape {
        let radius: CGFloat
        func path(in rect: CGRect) -> Path {
            var path = Path(rect.insetBy(dx: -CardChrome<EmptyView>.margin, dy: -CardChrome<EmptyView>.margin))
            path.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect))
            return path
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.black)
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)
            .mask(Outside(radius: radius).fill(style: FillStyle(eoFill: true)))
            .allowsHitTesting(false)
    }
}

/// A light tint behind the glass, so it stays readable over busy pages:
/// frosted white in light mode, smoky dark in dark mode. Plain colours, resolved per mode.
func glassTint(_ scheme: ColorScheme) -> Color {
    scheme == .dark
        ? Color(.sRGB, red: 0.08, green: 0.08, blue: 0.09, opacity: 0.38)
        : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.55)
}

/// Three short diagonal strokes in the bottom-right corner.
struct ResizeGrip: View {
    let hovering: Bool
    var body: some View {
        Canvas { ctx, size in
            for i in 0..<3 {
                let inset = CGFloat(i) * 3.5 + 2
                var line = Path()
                line.move(to: CGPoint(x: size.width - 2, y: inset))
                line.addLine(to: CGPoint(x: inset, y: size.height - 2))
                ctx.stroke(line, with: .color(.primary.opacity(hovering ? 0.45 : 0.22)), lineWidth: 1)
            }
        }
        .frame(width: 13, height: 13)
    }
}

/// The places to grab the card: the side edges set its width, and the four corners scale it,
/// text and all. The top and bottom have none, since the card's height is always its
/// content's. Each is a band straddling the card's edge (half outside it, in the window's
/// shadow margin), so they're as easy to find as a window's.
struct ResizeHandles: View {
    @ObservedObject var layout: CardLayout
    static let outside: CGFloat = 4, inside: CGFloat = 4, corner: CGFloat = 14
    /// The right edge, the one that widens the card, reaches further in.
    static let rightInside: CGFloat = 8
    /// The bottom-right corner, the one people reach for: bigger, and easy to hit.
    static let bigCorner: CGFloat = 26

    var body: some View {
        let band = Self.outside + Self.inside
        let c = Self.corner
        ZStack {
            handle([.left]).frame(width: band).padding(.vertical, c).frame(maxWidth: .infinity, alignment: .leading)
            handle([.right]).frame(width: Self.outside + Self.rightInside).padding(.vertical, c).frame(maxWidth: .infinity, alignment: .trailing)
            handle([.top, .left]).frame(width: c, height: c).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            handle([.top, .right]).frame(width: c, height: c).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            handle([.bottom, .left]).frame(width: c, height: c).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            handle([.bottom, .right]).frame(width: Self.bigCorner, height: Self.bigCorner).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .padding(-Self.outside)
    }

    private func handle(_ edges: CardLayout.Edges) -> some View {
        ResizeHandle(layout: layout, edges: edges)
    }
}

/// One side edge or corner: an edge sets the card's width, a corner scales it, text and all.
/// The resize pointer shows while the pointer is over it and stays for the whole drag, even
/// when the pointer runs ahead of the edge. Double-click resets the width (a corner: actual size).
struct ResizeHandle: View {
    @ObservedObject var layout: CardLayout
    let edges: CardLayout.Edges
    @State private var hovering = false
    @State private var dragging = false
    @State private var cursorPushed = false

    var body: some View {
        // Not quite clear: a fully transparent area of the window would let clicks through.
        Color.black.opacity(0.01)
            .contentShape(Rectangle())
            .onHover { hovering = $0; updateCursor() }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { _ in
                        if !dragging { dragging = true; updateCursor() }
                        layout.onResize(edges, NSEvent.mouseLocation)
                    }
                    .onEnded { _ in
                        dragging = false
                        layout.onResize(edges, nil)
                        updateCursor()
                    }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { layout.resetSize(edges, zoomToo: isCorner) })
            .help(isCorner ? "Drag to resize · double-click for actual size" : "")
            .onDisappear { if cursorPushed { NSCursor.pop(); cursorPushed = false } }
    }

    private var isCorner: Bool { edges.count2 }

    private var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.top]: position = .top
        case [.bottom]: position = .bottom
        case [.left]: position = .left
        case [.right]: position = .right
        case [.top, .left]: position = .topLeft
        case [.top, .right]: position = .topRight
        case [.bottom, .left]: position = .bottomLeft
        default: position = .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }

    private func updateCursor() {
        let wanted = hovering || dragging
        if wanted, !cursorPushed { cursor.push(); cursorPushed = true }
        else if !wanted, cursorPushed { NSCursor.pop(); cursorPushed = false }
    }
}

/// A full-width row that highlights on hover and press, the way macOS lists do. It reaches
/// `bleed` past the content's edges, so row text stays on the card's leading edge while the
/// highlight has room around it.
struct CardRowStyle: ButtonStyle {
    var bleed: CGFloat = Space.s
    var vertical: CGFloat = Space.xs + 1

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, bleed: bleed, vertical: vertical)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let bleed: CGFloat
        let vertical: CGFloat
        @State private var hovering = false
        @Environment(\.cardScale) private var scale

        var body: some View {
            configuration.label
                .padding(.vertical, vertical * scale).padding(.horizontal, bleed * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : hovering ? 0.05 : 0))
                )
                .contentShape(Rectangle())
                .padding(.horizontal, -bleed * scale)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: hovering ? 0.08 : 0.2), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// A section's title, in sentence case like the system's grouped lists.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .cardFont(TextSize.subheadline, .semibold)
            .foregroundStyle(.secondary)
    }
}

/// A hairline between a card's sections.
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }
}

/// The chosen option's checkmark, at the row's trailing edge as in the system's selection
/// lists, so every option's text keeps the same leading edge. It holds its width either way.
struct ChoiceMark: View {
    let chosen: Bool
    @Environment(\.cardScale) private var scale
    var body: some View {
        Image(systemName: "checkmark")
            .cardFont(TextSize.callout, .semibold)
            .foregroundStyle(Color.accentColor)
            .opacity(chosen ? 1 : 0)
            .scaleEffect(chosen ? 1 : 0.6)
            .frame(width: 14 * scale, alignment: .trailing)
    }
}

/// One meaning in a word's list: its number (meanings are different senses, not synonyms;
/// numbered from the whole list, so a short list shows where some were left out), the part of
/// speech when the definition makes it clear, and the definition. Always one row: a word with
/// several readings lists its meanings under a `ReadingHeader` for each.
struct SenseLine: View {
    let number: Int
    let total: Int
    let gloss: String
    let partOfSpeech: PartOfSpeech?
    let size: CGFloat
    let chosen: Bool
    let dimmed: Bool
    @Environment(\.cardScale) private var scale

    var body: some View {
        let column = (total >= 10 ? 15 : 9) * scale
        let gap = 6 * scale
        HStack(alignment: .firstTextBaseline, spacing: gap) {
            Text("\(number)")
                .cardFont(size - 1, .medium, monospacedDigit: true)
                .foregroundStyle(.tertiary)
                .frame(width: column, alignment: .trailing)
            definition
                .cardFont(size, chosen ? .semibold : .regular)
                .foregroundStyle(dimmed ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var definition: Text {
        guard let partOfSpeech else { return Text(gloss) }
        return Text(partOfSpeech.label).italic().fontWeight(.regular).foregroundColor(.secondary)
            + Text(" ") + Text(gloss)
    }

    /// Whether the meaning at `position` in a shown list starts a new reading (好 hǎo, then hào).
    static func startsReading(_ shown: [(offset: Int, element: Sense)], at position: Int) -> Bool {
        position == 0 || shown[position - 1].element.pinyin != shown[position].element.pinyin
    }
}

/// A reading over the meanings that have it, as dictionaries print it: once, not on every row.
struct ReadingHeader: View {
    let pinyin: String
    let first: Bool
    @Environment(\.cardScale) private var scale
    var body: some View {
        Text(Pinyin.marked(pinyin))
            .cardFont(TextSize.subheadline, .semibold)
            .foregroundStyle(.secondary)
            .padding(.top, (first ? 0 : Space.s) * scale)
            .padding(.bottom, 1 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// The room a card's first line keeps at its trailing end for its buttons (Listen, Copy, Anki
/// and Pin), which the card draws there (fixed, so they stay put when the card scrolls).
/// `centerAboveBaseline` puts the buttons' centre on the line's visual middle: about half the
/// cap height of its text.
struct ActionSlot: View {
    static let space = "cardContent"
    static let height: CGFloat = 22
    /// Space between a button's edge and its symbol's.
    static let glyphInset: CGFloat = 6
    let centerAboveBaseline: CGFloat
    @Environment(\.cardActionCount) private var count

    /// Buttons 26 wide with 2 between them, the last symbol on the content's edge.
    private var width: CGFloat { CGFloat(count) * 26 + CGFloat(count - 1) * 2 - Self.glyphInset }

    var body: some View {
        Color.clear
            .frame(width: width, height: Self.height)
            .background(GeometryReader { g in
                Color.clear.preference(key: ActionSlotKey.self, value: g.frame(in: .named(Self.space)).midY)
            })
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + centerAboveBaseline }
    }
}

/// How many buttons the card's first line holds; set by `CardChrome` from its layout.
private struct CardActionCountKey: EnvironmentKey { static let defaultValue = 3 }
extension EnvironmentValues {
    var cardActionCount: Int {
        get { self[CardActionCountKey.self] }
        set { self[CardActionCountKey.self] = newValue }
    }
}

struct ActionSlotKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = value ?? nextValue() }
}

/// Listen, Copy, Anki and Pin: plain symbols in the tertiary label colour, a step brighter
/// while the pointer is on the card, with a soft rounded highlight under the one pointed at.
struct CardActions: View {
    @ObservedObject var layout: CardLayout
    let cardHovered: Bool
    @ObservedObject private var pin = CardPin.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var copied = false
    @State private var resetCopied: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 2) {
            if let speech = layout.speech {
                let plan = speech()
                let playing = speaker.speaking != nil && speaker.speaking == plan.text
                FooterButton(help: playing ? "Stop" : plan.help, cardHovered: cardHovered,
                             tint: playing ? Color.accentColor : nil,
                             action: { let now = speech(); if !now.text.isEmpty { speaker.toggle(now.text) } }) {
                    Image(systemName: "speaker.wave.2")
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: playing)
                }
            }
            if layout.copyText != nil {
                FooterButton(help: copied ? "Copied" : copyHelp, cardHovered: cardHovered,
                             tint: copied ? Color.accentColor : nil, action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace.downUp))
                }
            }
            if let anki = layout.anki {
                AnkiButton(model: anki, word: copyWord, cardHovered: cardHovered)
            }
            FooterButton(help: pin.isOn ? "Unpin: close when you click elsewhere" : "Pin: keep the card here for every lookup",
                         cardHovered: cardHovered, tint: pin.isOn ? Color.accentColor : nil,
                         action: { layout.togglePin() }) {
                Image(systemName: pin.isOn ? "pin.fill" : "pin")
                    .contentTransition(.symbolEffect(.replace.downUp))
                    .symbolEffect(.bounce.down, value: pin.isOn)
                    // The pin's weight is in its head, so centred by its box it looks high
                    // beside the others: lower it a point, between its box and its weight, so it sits level.
                    .offset(y: 1)
            }
        }
    }

    /// Copy “一直”, with a long selection shortened.
    private var copyHelp: String { "Copy “\(copyWord)”" }

    /// The highlighted text, shortened when long, for the buttons' help.
    private var copyWord: String {
        let text = layout.copyText?() ?? ""
        return text.count > 14 ? text.prefix(13) + "…" : text
    }

    private func copy() {
        guard let text = layout.copyText?() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        resetCopied?.cancel()
        let work = DispatchWorkItem { copied = false }
        resetCopied = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}

/// Adds the card to Anki. After that it says so in the accent colour, and a click shows the
/// note in Anki; when Anki doesn't answer, a warning for a moment, with why in its help.
private struct AnkiButton: View {
    @ObservedObject var model: AnkiButtonModel
    let word: String
    let cardHovered: Bool

    var body: some View {
        FooterButton(help: help, cardHovered: cardHovered, tint: tint, action: model.click) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace.downUp))
                .opacity(model.state == .adding ? 0.4 : 1)
        }
    }

    private var symbol: String {
        switch model.state {
        case .ready, .adding: "rectangle.stack.badge.plus"
        case .added: "checkmark.rectangle.stack"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var tint: Color? {
        if case .added = model.state { return .accentColor }
        return nil
    }

    private var help: String {
        switch model.state {
        case .ready: "Add “\(word)” to Anki"
        case .adding: "Adding to Anki…"
        case .added: "In Anki · click to show it there"
        case .failed(let why): why
        }
    }
}

/// A borderless symbol button for the footer.
private struct FooterButton<Label: View>: View {
    let help: String
    let cardHovered: Bool
    var tint: Color?
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.map { AnyShapeStyle($0) }
                                 ?? AnyShapeStyle(hovering ? .primary : (cardHovered ? .secondary : .tertiary)))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(FooterButtonStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: cardHovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Closes a pinned card: the round button Notification Center hangs on a banner's corner,
/// shown while the pointer is on the card. Unpinned cards close by clicking elsewhere.
struct CloseBadge: View {
    @ObservedObject var layout: CardLayout
    let cardHovered: Bool
    @ObservedObject private var pin = CardPin.shared
    @State private var hovering = false

    var body: some View {
        let shown = pin.isOn && (cardHovered || hovering)
        Button { layout.closeCard() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(FooterButtonStyle())
        .onHover { hovering = $0 }
        .help("Close")
        .accessibilityLabel("Close")
        .accessibilityHidden(!shown)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown ? 1 : 0.7)
        .allowsHitTesting(shown)
        .animation(.spring(response: 0.25, dampingFraction: 0.9), value: shown)
        .offset(x: -7, y: -7)
    }
}
