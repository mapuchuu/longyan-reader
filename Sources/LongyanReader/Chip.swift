import AppKit

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

    private static let size: CGFloat = 20

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
        let chip = ChipView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        chip.onClick = { [weak self] in self?.clicked() }
        panel.contentView = chip
        panel.alphaValue = 0
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
        let frame = panel?.frame ?? .zero
        let selection = pending
        hide()
        onClick(selection, frame)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A small translucent circle with the Longyan eye: quiet until hovered.
final class ChipView: NSView {
    var onClick: () -> Void = {}
    private let background = NSVisualEffectView()
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.frame = bounds
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = frame.height / 2
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(background)

        let inset = (frame.width - 12) / 2
        icon.frame = bounds.insetBy(dx: inset, dy: inset)
        icon.image = Icons.mark(size: 12)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        toolTip = "Look up in Longyan"
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { icon.contentTintColor = .labelColor }
    override func mouseExited(with event: NSEvent) { icon.contentTintColor = .secondaryLabelColor }
    override func mouseDown(with event: NSEvent) { onClick() }
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
