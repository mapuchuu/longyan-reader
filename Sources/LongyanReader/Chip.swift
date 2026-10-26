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
                self.show(at: upPoint, selectionBounds: s.bounds, selection: t)
            case .unreadable:
                // The app won't say what's selected; offer the chip and copy on click.
                self.show(at: upPoint, selectionBounds: nil, selection: nil)
            case .nothingSelected:
                return
            }
        }
    }

    /// The window is a little larger than the button so its hover growth and shadow fit.
    private static let size: CGFloat = 30

    /// Sits just after the end of a one-line selection; for longer selections,
    /// just above and right of where the mouse was released.
    private func show(at point: NSPoint, selectionBounds: CGRect?, selection: Selection?) {
        hide()
        pending = selection
        let size = Self.size
        var origin = NSPoint(x: point.x + 6, y: point.y + 6)
        if let b = selectionBounds, b.height > 0, b.height < 40 {
            let r = AppDelegate.appKitRect(b)
            origin = NSPoint(x: r.maxX + 4, y: r.midY - size / 2)
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = FirstMouseHostingView(rootView: ChipButtonView { [weak self] in self?.clicked() })
        panel.appearance = CardAppearance.current
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func clicked() {
        let frame = panel?.frame ?? .zero
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
    private let diameter: CGFloat = 24

    var body: some View {
        ZStack {
            if !snapshot { MaterialBackground(radius: diameter / 2) }
            Circle().fill(cardSurface(opaque: snapshot))
            if let mark = Icons.mark(size: 13) {
                Image(nsImage: mark)
                    .renderingMode(.template)
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .scaleEffect(appeared || snapshot ? (pressed ? 0.92 : hovering ? 1.08 : 1) : 0.6)
        .opacity(appeared || snapshot ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false; action() })
        .help("Look up in Longyan")
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: pressed)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.68)) { appeared = true } }
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
