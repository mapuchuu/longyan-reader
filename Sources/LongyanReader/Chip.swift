import AppKit
import SwiftUI

/// The small Longyan button that appears next to a fresh selection.
/// Clicking it opens the lookup; it disappears on the next click, key press or scroll.
@MainActor
final class SelectionChip {
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showChip") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showChip"); if !newValue { hide() } }
    }

    /// Called with the selection when it could be read, or nil when the app hides it
    /// (then the click falls back to copying).
    var onClick: (Selection?, NSRect) -> Void = { _, _ in }
    /// Called when the button appears for a readable selection, so work can start early.
    var onShow: (Selection) -> Void = { _ in }

    private var panel: NSPanel?
    private var pending: Selection?
    private var downPoint: NSPoint = .zero
    private var hideWork: DispatchWorkItem?
    private var monitors: [Any] = []

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.downPoint = NSEvent.mouseLocation
            self?.hide()
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            self?.mouseUp(clickCount: event.clickCount)
        }
        let other = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        monitors = [down, up, other].compactMap { $0 }
    }

    private func mouseUp(clickCount: Int) {
        guard isEnabled else { return }
        let upPoint = NSEvent.mouseLocation
        let dragged = hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) > 4
        guard dragged || clickCount >= 2 else { return }   // a plain click never selects text
        // Give the app a moment to update its selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            switch SelectionReader.readAccessibility() {
            case .selection(let s):
                let t = s.trimmed()
                guard !t.range.isEmpty, t.hasChinese, t.range.count <= 400 else { return }
                // A position far from where the mouse let go isn't where the selection is.
                let near = t.bounds.map { AppDelegate.appKitRect($0).insetBy(dx: -160, dy: -160).contains(upPoint) } ?? false
                let placed = near ? t : t.withoutBounds()
                self.show(at: upPoint, selectionBounds: placed.bounds, selection: placed)
            case .unreadable:
                // The app won't say what's selected; offer the chip and copy on click.
                self.show(at: upPoint, selectionBounds: nil, selection: nil)
            case .nothingSelected:
                return
            }
        }
    }

    /// The window is larger than the button so its hover growth and shadow fit.
    private static let size: CGFloat = 44
    /// The part of the window the button's position is worked out from.
    private static let target: CGFloat = 30

    /// Sits just after the end of a one-line selection; for longer selections,
    /// just above and right of where the mouse was released.
    private func show(at point: NSPoint, selectionBounds: CGRect?, selection: Selection?) {
        hide()
        pending = selection
        LocalModel.warmUp()
        if let selection { onShow(selection) }
        let size = Self.size
        var origin = NSPoint(x: point.x + 6, y: point.y + 6)
        if let b = selectionBounds, b.height > 0, b.height < 40 {
            let r = AppDelegate.appKitRect(b)
            origin = NSPoint(x: r.maxX + 4, y: r.midY - Self.target / 2)
        }
        let inset = (size - Self.target) / 2
        origin = NSPoint(x: origin.x - inset, y: origin.y - inset)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false        // the button draws its own, as the card does
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = FirstMouseHostingView(rootView: ChipButtonView { [weak self] in self?.clicked() })
        panel.appearance = CardAppearance.current
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func clicked() {
        let inset = (Self.size - Self.target) / 2
        let frame = panel?.frame.insetBy(dx: inset, dy: inset) ?? .zero
        let selection = pending
        hide()
        onClick(selection, frame)
    }

    func hide() {
        hideWork?.cancel()
        if let old = panel {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                old.animator().alphaValue = 0
            }, completionHandler: { old.orderOut(nil) })
        }
        panel = nil
    }
}

/// The selection button, in the cards' style: popover material under a clean surface,
/// hairline border, a muted eye that brightens on hover, and a small spring on appear.
struct ChipButtonView: View {
    var action: () -> Void
    @State private var appeared = false
    @State private var hovering = false
    @State private var pressed = false
    @Environment(\.renderingSnapshot) private var snapshot
    @Environment(\.colorScheme) private var colorScheme
    private let diameter: CGFloat = 24

    var body: some View {
        styled
        .scaleEffect(appeared || snapshot ? (pressed ? 0.92 : hovering ? 1.08 : 1) : 0.6)
        .shadow(color: .black.opacity(snapshot ? 0 : 0.18), radius: 5, y: 2)
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false; action() })
        .help("Look up in Longyan")
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { appeared = true } }
    }

    private var eye: some View {
        Group {
            if let mark = Icons.mark(size: 13) {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
        }
    }

    @ViewBuilder private var styled: some View {
        if CardStyle.current == .glass && !snapshot {
            eye
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(glassTint(colorScheme)))
                .clipShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            ZStack {
                if !snapshot { MaterialBackground(radius: diameter / 2) }
                Circle().fill(cardSurface(opaque: snapshot))
                eye
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

/// The Longyan eye from the Chrome extension, as a template image.
enum Icons {
    static func mark(size: CGFloat) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "longyan-mark", withExtension: "png")
                ?? URL(string: "file://" + FileManager.default.currentDirectoryPath + "/Resources/longyan-mark.png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }
}
