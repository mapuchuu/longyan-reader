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
                self.show(at: upPoint, selection: t)
            case .unreadable:
                // The app won't say what's selected; offer the chip and copy on click.
                if dragged || clickCount >= 2 { self.show(at: upPoint, selection: nil) }
            case .nothingSelected:
                return
            }
        }
    }

    private func show(at point: NSPoint, selection: Selection?) {
        hide()
        pending = selection
        let size: CGFloat = 26
        let panel = NSPanel(contentRect: NSRect(x: point.x + 6, y: point.y + 6, width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let button = ChipButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.target = self
        button.action = #selector(clicked)
        panel.contentView = button
        panel.orderFrontRegardless()
        self.panel = panel

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    @objc private func clicked() {
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

/// Round button with the Longyan eye, tinted for light or dark mode.
final class ChipButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        image = Icons.mark(size: 16)
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        toolTip = "Look up in Longyan"
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
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
