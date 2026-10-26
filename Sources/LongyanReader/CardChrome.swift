import AppKit
import SwiftUI

/// Size and appearance state for one popup card. The window follows it.
/// Dragging the corner zooms the card: width sets the scale of the text and spacing,
/// and the height always fits the content (scrolling only past the screen limit).
@MainActor
final class CardLayout: ObservableObject {
    enum Kind: String { case word, phrase, hint }

    let kind: Kind
    /// Card width; the zoom is this over the default width (persisted per kind).
    @Published var width: CGFloat
    /// Natural height of the content at the current width and zoom.
    @Published var contentHeight: CGFloat = 0
    @Published var appeared = false

    var maxHeight: CGFloat = 640
    var onChange: (_ animated: Bool) -> Void = { _ in }
    private(set) var isResizing = false

    static let defaultWidth: [Kind: CGFloat] = [.word: 360, .phrase: 390, .hint: 260]
    static let scaleRange: ClosedRange<CGFloat> = 0.8...2.2

    var baseWidth: CGFloat { Self.defaultWidth[kind] ?? 360 }
    var scale: CGFloat { kind == .hint ? 1 : width / baseWidth }

    init(kind: Kind) {
        self.kind = kind
        let base = Self.defaultWidth[kind] ?? 360
        let saved = UserDefaults.standard.double(forKey: "card.\(kind.rawValue).width")
        width = saved > 0 ? min(max(saved, base * Self.scaleRange.lowerBound), base * Self.scaleRange.upperBound) : base
    }

    var height: CGFloat { min(contentHeight, maxHeight) }

    func reportContentHeight(_ h: CGFloat) {
        guard abs(h - contentHeight) > 0.5 else { return }
        contentHeight = h
        onChange(appeared && !isResizing)
    }

    // MARK: Zooming from the corner grip

    private var dragStart: (mouse: NSPoint, width: CGFloat, height: CGFloat)?

    func resize(to mouse: NSPoint) {
        if dragStart == nil {
            dragStart = (mouse, width, max(height, 1))
            isResizing = true
        }
        guard let start = dragStart else { return }
        // Right or down both zoom in. Screen y grows upward, so down is negative.
        let dx = mouse.x - start.mouse.x
        let dy = -(mouse.y - start.mouse.y) * (start.width / start.height)
        let proposed = start.width + (dx + dy) / 2
        width = min(max(proposed, baseWidth * Self.scaleRange.lowerBound), baseWidth * Self.scaleRange.upperBound)
        onChange(false)
    }

    func endResize() {
        dragStart = nil
        isResizing = false
        UserDefaults.standard.set(Double(width), forKey: "card.\(kind.rawValue).width")
        onChange(false)
    }

    /// Double-click on the grip: back to 1×.
    func resetSize() {
        width = baseWidth
        UserDefaults.standard.removeObject(forKey: "card.\(kind.rawValue).width")
        onChange(true)
    }
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
    static var current: CardStyle { CardStyle(rawValue: UserDefaults.standard.string(forKey: "cardStyle") ?? "") ?? .classic }
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

/// The frame every card sits in: material, hairline border, scrolling when the card is
/// smaller than its content, the corner grip, and the spring-in on appear.
struct CardChrome<Content: View>: View {
    @ObservedObject var layout: CardLayout
    @Environment(\.renderingSnapshot) private var snapshot
    let content: Content
    static var radius: CGFloat { 14 }

    init(layout: CardLayout, @ViewBuilder content: () -> Content) {
        self.layout = layout
        self.content = content()
    }

    var body: some View {
        body(for: padded)
    }

    private var padded: some View {
        content
            .environment(\.cardScale, layout.scale)
            .padding(16 * layout.scale)
            .frame(width: layout.width, alignment: .leading)
    }

    @ViewBuilder private func body(for inner: some View) -> some View {
        if snapshot {
            decorate(inner)
        } else {
            decorate(
                ScrollView(.vertical) {
                    inner.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                }
                .scrollIndicators(layout.contentHeight > layout.maxHeight ? .automatic : .never)
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(HeightKey.self) { h in
                    MainActor.assumeIsolated { layout.reportContentHeight(h) }
                }
                .frame(width: layout.width, height: max(layout.height, 1))
            )
        }
    }

    @ViewBuilder private func decorate(_ view: some View) -> some View {
        if CardStyle.current == .glass && !snapshot {
            glass(view)
        } else {
            classic(view)
        }
    }

    /// Liquid Glass: the system glass, a little rounder, no hairline (the glass draws its own edge).
    private func glass(_ view: some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius + 4, style: .continuous)
        return view
            .glassEffect(.regular, in: shape)
            .overlay(alignment: .bottomTrailing) {
                if layout.kind != .hint { ResizeGrip(layout: layout).padding(5) }
            }
            .scaleEffect(layout.appeared ? 1 : 0.96, anchor: .top)
            .opacity(layout.appeared ? 1 : 0)
            .offset(y: layout.appeared ? 0 : -4)
    }

    private func classic(_ view: some View) -> some View {
        view
        .background {
            if snapshot {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(cardSurface(opaque: true))
            } else {
                // The popover material alone reads grey; a soft white (near-black in dark
                // mode) wash over it keeps a little translucency but looks clean.
                ZStack {
                    MaterialBackground(radius: Self.radius)
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous).fill(cardSurface(opaque: false))
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            if layout.kind != .hint { ResizeGrip(layout: layout).padding(3) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .scaleEffect(layout.appeared || snapshot ? 1 : 0.96, anchor: .top)
        .opacity(layout.appeared || snapshot ? 1 : 0)
        .offset(y: layout.appeared || snapshot ? 0 : -4)
    }
}

/// The corner handle: drag to resize, double-click to reset.
struct ResizeGrip: View {
    @ObservedObject var layout: CardLayout
    @State private var hovering = false

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
        .contentShape(Rectangle().inset(by: -4))
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.frameResize(position: .bottomRight, directions: .all).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in layout.resize(to: NSEvent.mouseLocation) }
                .onEnded { _ in layout.endResize() }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { layout.resetSize() })
        .help("Drag to zoom the card · double-click to reset")
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A full-width row that highlights on hover and press, the way macOS lists do.
struct CardRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false
        @Environment(\.cardScale) private var scale

        var body: some View {
            configuration.label
                .padding(.vertical, 5 * scale).padding(.horizontal, 8 * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.16)
                              : Color.primary.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0))
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// A small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .cardFont(10, .semibold).tracking(0.5)
            .foregroundStyle(.secondary)
    }
}
