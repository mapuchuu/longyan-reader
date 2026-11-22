import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LongyanCore
import PDFKit

/// Screen points use the global CoreGraphics space: origin at the top-left of the
/// primary display, y growing downward (what Accessibility expects).
enum SelectionReader {
    enum Result { case selection(Selection), nothingSelected, unreadable }

    /// Why the last read failed; written to the lookup log.
    static var trace: [String] = []
    /// The focused element's role at the last read; nil when the app named none.
    static var lastFocusedRole: String?

    /// Roles that hold things other than text (files, rows, controls). A drag there selects
    /// those, so an unreadable "selection" in one isn't text worth offering to look up.
    private static let notTextRoles: Set<String> = [
        kAXListRole, kAXOutlineRole, kAXBrowserRole, kAXImageRole, kAXButtonRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXSliderRole, kAXScrollBarRole, kAXSplitterRole, kAXToolbarRole,
        kAXMenuRole, kAXMenuBarRole, kAXMenuItemRole, kAXPopUpButtonRole, kAXTabGroupRole,
        kAXWindowRole, "AXDockItem", kAXColumnRole, kAXRowRole,
    ]
    /// Whether an unreadable selection may still be text, so the eye is worth showing.
    static var unreadableMayBeText: Bool { lastFocusedRole.map { !notTextRoles.contains($0) } ?? true }
    private static func note(_ s: String) { trace.append(s) }

    // MARK: Accessibility (no side effects)

    static func readAccessibility(from target: NSRunningApplication? = nil) -> Result {
        trace = []
        lastFocusedRole = nil
        guard AXIsProcessTrusted() else { note("not trusted"); return .unreadable }
        guard let app = target ?? NSWorkspace.shared.frontmostApplication else { return .unreadable }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        prepare(app)

        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else {
            note("no focused element in \(app.localizedName ?? "?")")
            return .unreadable
        }
        let role: String = attribute(focused, kAXRoleAttribute) ?? "?"
        lastFocusedRole = role
        note("focused \(role) in \(app.localizedName ?? "?")")

        // Web pages first: their text views also answer the plain-text queries, but without context.
        if let s = webSelection(focused, app: app.localizedName) { return checked(s, focused) }
        if let s = nativeSelection(focused, app: app.localizedName) { return checked(s, focused) }
        if app.bundleIdentifier == "com.apple.Preview", let s = pdfSelection(focused, app: app.localizedName) { return checked(s, focused) }
        // Some apps only say what is selected, not where: still better than copying.
        if let selected: String = attribute(focused, kAXSelectedTextAttribute) {
            if selected.isEmpty { return .nothingSelected }
            note("selected text only, no context")
            let passage = Array(selected)
            return .selection(Selection(passage: passage, range: 0..<passage.count, bounds: nil,
                                        source: .accessibility, appName: app.localizedName))
        }
        return .unreadable
    }

    /// Some apps report an empty rectangle at the screen's corner, or one relative to their
    /// window. Such a position is dropped, so the card opens by the pointer instead.
    private static func checked(_ result: Result, _ focused: AXUIElement) -> Result {
        guard case .selection(let s) = result, let b = s.bounds else { return result }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let onScreen = NSRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
        var plausible = b.width >= 1 && b.height >= 1 && NSScreen.screens.contains { $0.frame.intersects(onScreen) }
        if plausible, let window = windowFrame(of: focused), !window.intersects(b) { plausible = false }
        if plausible { return result }
        note("bounds dropped: \(b)")
        return .selection(s.withoutBounds())
    }

    /// The focused element's window, in the same space as selection bounds.
    private static func windowFrame(of element: AXUIElement) -> CGRect? {
        guard let window: AXUIElement = attribute(element, kAXWindowAttribute),
              let position: AXValue = attribute(window, kAXPositionAttribute),
              let size: AXValue = attribute(window, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Chromium browsers build their page accessibility tree only when an assistive app
    /// turns on AXEnhancedUserInterface (the VoiceOver switch); Electron apps use
    /// AXManualAccessibility. Pages, Keynote and Numbers need the switch too: without it their
    /// document is a blank canvas to Accessibility, so only ⌘C worked, with no sentence around
    /// the selection. Called when such an app comes to the front, so the tree is ready by the
    /// time text is selected. The app keeps it on until it quits.
    private static var preparedPIDs: Set<pid_t> = []
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
    static let iWork: Set<String> = ["com.apple.Pages", "com.apple.Keynote", "com.apple.Numbers"]
    static func prepare(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted() else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let id = app.bundleIdentifier ?? ""
        // An app still starting up can accept the switch and then reset it (Pages does), so
        // it's read back every time: one quick query.
        if chromiumBrowsers.contains(id) || iWork.contains(id) {
            AXUIElementSetMessagingTimeout(element, 0.3)
            var value: CFTypeRef?
            let on = AXUIElementCopyAttributeValue(element, "AXEnhancedUserInterface" as CFString, &value) == .success
                && (value as? Bool) == true
            if !on { AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
        }
        guard !preparedPIDs.contains(app.processIdentifier) else { return }
        // An app not ready yet (just launched) is tried again next time.
        if AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            preparedPIDs.insert(app.processIdentifier)
        }
    }

    /// Text fields, TextEdit, Notes, Pages, Preview: selection as a character range.
    private static func nativeSelection(_ element: AXUIElement, app: String?) -> Result? {
        guard let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &sel) else { return nil }
        if sel.length == 0 { note("native: empty selection"); return .nothingSelected }
        // kCFNotFound (Int.max) or a negative length from a misbehaving app would trap below.
        guard sel.location >= 0, sel.length > 0, sel.location < Int.max / 4, sel.length < Int.max / 4 else {
            note("native: invalid range"); return nil
        }

        // The selection plus up to 300 characters either side, for context.
        var total = 0
        if let n: Int = attribute(element, kAXNumberOfCharactersAttribute) { total = n }
        let start = max(0, sel.location - 300)
        let end = total > 0 ? min(total, sel.location + sel.length + 300) : sel.location + sel.length
        var window = CFRange(location: start, length: end - start)
        var text: String? = parameterized(element, kAXStringForRangeParameterizedAttribute, AXValueCreate(.cfRange, &window))
        var selStart = sel.location - start
        if text == nil, let selected: String = attribute(element, kAXSelectedTextAttribute) {
            text = selected      // no context available, just the selection
            selStart = 0
        }
        guard let text else { note("native: no text for range"); return nil }

        let utf16 = Array(text.utf16)
        guard selStart >= 0, selStart + sel.length <= utf16.count else { note("native: range outside text"); return nil }
        let prefix = String(utf16CodeUnits: Array(utf16[0..<selStart]), count: selStart)
        let selected = String(utf16CodeUnits: Array(utf16[selStart..<(selStart + sel.length)]), count: sel.length)
        let passage = Array(prefix + selected + String(utf16CodeUnits: Array(utf16[(selStart + sel.length)...]), count: utf16.count - selStart - sel.length))
        let lo = prefix.count
        var bounds: CGRect?
        var selCopy = sel
        if let b: AXValue = parameterized(element, kAXBoundsForRangeParameterizedAttribute, AXValueCreate(.cfRange, &selCopy)) {
            var r = CGRect.zero
            if AXValueGetValue(b, .cgRect, &r) { bounds = r }
        }
        note("native: \(selected.count) chars selected")
        return .selection(Selection(passage: passage, range: lo..<(lo + selected.count), bounds: bounds,
                                    source: .accessibility, appName: app))
    }

    /// Web pages (Safari, Chrome): selection as a text-marker range.
    private static func webSelection(_ focused: AXUIElement, app: String?) -> Result? {
        // The selection lives on the web area; walk up from the focused element to find it.
        var element: AXUIElement? = focused
        var markerRange: CFTypeRef?
        var depth = 0   // a buggy app's parent chain can loop
        while let e = element, markerRange == nil, depth < 64 {
            markerRange = attribute(e, "AXSelectedTextMarkerRange")
            if markerRange == nil { element = attribute(e, kAXParentAttribute) }
            depth += 1
        }
        guard let e = element, let range = markerRange, CFGetTypeID(range) == AXTextMarkerRangeGetTypeID() else {
            note("web: no text-marker selection")
            return nil
        }
        guard let selected: String = parameterized(e, "AXStringForTextMarkerRange", range), !selected.isEmpty else {
            note("web: empty selection")
            return .nothingSelected
        }

        // Context: the paragraph (else the line) containing the selection's start.
        var passageText = selected
        var lo = 0
        let start = AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange)
        for attr in ["AXParagraphTextMarkerRangeForTextMarker", "AXLineTextMarkerRangeForTextMarker"] {
            guard let around: CFTypeRef = parameterized(e, attr, start), CFGetTypeID(around) == AXTextMarkerRangeGetTypeID(),
                  let text: String = parameterized(e, "AXStringForTextMarkerRange", around) else { continue }
            // The text from the paragraph's start to the selection's says which copy was
            // selected when the same words appear twice (打 in two sentences).
            let paragraphStart = AXTextMarkerRangeCopyStartMarker(around as! AXTextMarkerRange)
            let before = AXTextMarkerRangeCreate(kCFAllocatorDefault, paragraphStart, start)
            let prefix: String? = parameterized(e, "AXStringForTextMarkerRange", before)
            if let found = nearest(selected, in: Array(text), to: prefix?.count) {
                passageText = text
                lo = found
                break
            }
        }
        var bounds: CGRect?
        if let b: AXValue = parameterized(e, "AXBoundsForTextMarkerRange", range) {
            var r = CGRect.zero
            if AXValueGetValue(b, .cgRect, &r) { bounds = r }
        }
        note("web: \(selected.count) chars selected, context \(passageText.count)")
        return .selection(Selection(passage: Array(passageText), range: lo..<(lo + selected.count), bounds: bounds,
                                    source: .accessibility, appName: app))
    }

    /// Where `needle` appears in `hay`, the copy nearest `offset` when it appears more than once
    /// (a browser's count can be off by a character or two around line breaks).
    static func nearest(_ needle: String, in hay: [Character], to offset: Int?) -> Int? {
        let n = Array(needle)
        guard !n.isEmpty, hay.count >= n.count else { return nil }
        var best: Int?
        for i in 0...(hay.count - n.count) where hay[i] == n[0] && Array(hay[i..<(i + n.count)]) == n {
            guard let offset else { return i }
            if best.map({ abs(i - offset) < abs($0 - offset) }) ?? true { best = i }
        }
        return best
    }

    // MARK: Preview PDFs

    /// Preview reports the selected text but not where it is. It does report the open
    /// file and which page holds the selection, so read the surrounding text from the
    /// PDF itself with PDFKit.
    private static var cachedPDF: (url: URL, doc: PDFDocument)?
    private static func pdfSelection(_ container: AXUIElement, app: String?) -> Result? {
        guard let selected: String = attribute(container, kAXSelectedTextAttribute) else { return nil }
        if selected.isEmpty { return .nothingSelected }
        guard let window: AXUIElement = attribute(container, kAXWindowAttribute),
              let path: String = attribute(window, kAXDocumentAttribute),
              let url = URL(string: path), url.isFileURL else { note("pdf: no document path"); return nil }

        // The page holding the selection (visible pages first).
        let visible: [AXUIElement] = attribute(container, kAXVisibleChildrenAttribute) ?? []
        let all: [AXUIElement] = visible.isEmpty ? (attribute(container, kAXChildrenAttribute) ?? []) : visible
        let page = all.first { (attribute($0, kAXSelectedTextAttribute) as String?).map { !$0.isEmpty } ?? false }
        guard let page, let index: Int = attribute(page, "AXPageIndex") else { note("pdf: no page with the selection"); return nil }

        let doc: PDFDocument
        if let cached = cachedPDF, cached.url == url { doc = cached.doc }
        else {
            guard let d = PDFDocument(url: url) else { note("pdf: couldn't open the file"); return nil }
            doc = d
            cachedPDF = (url, d)
        }
        guard let pageText = doc.page(at: index)?.string else { note("pdf: page \(index) has no text"); return nil }
        let text = joinLines(pageText)
        guard let found = find(selected, in: Array(text)) else { note("pdf: selection not found on page \(index)"); return nil }

        // Keep up to 300 characters either side.
        let chars = Array(text)
        let lo = max(0, found.lowerBound - 300), hi = min(chars.count, found.upperBound + 300)
        note("pdf: page \(index), \(found.count) chars selected")
        return .selection(Selection(passage: Array(chars[lo..<hi]), range: (found.lowerBound - lo)..<(found.upperBound - lo),
                                    bounds: nil, source: .accessibility, appName: app))
    }

    /// PDF text breaks lines mid-sentence. Join lines between Chinese characters without
    /// a space, and with one space otherwise.
    static func joinLines(_ text: String) -> String {
        var out: [Character] = []
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            guard c.isNewline else { out.append(c); continue }
            let prev = out.last, next = chars[safe: i + 1]
            if let p = prev, let n = next, isCJK(p) || isCJK(n) || !p.isLetter { continue }
            if prev != " " { out.append(" ") }
        }
        return String(out)
    }

    /// Finds `needle` in `hay`, ignoring whitespace on both sides. Returns the range in `hay`.
    static func find(_ needle: String, in hay: [Character]) -> Range<Int>? {
        let n = Array(needle.filter { !$0.isWhitespace })
        guard !n.isEmpty else { return nil }
        var kept: [Int] = []          // positions in hay of non-whitespace characters
        for (i, c) in hay.enumerated() where !c.isWhitespace { kept.append(i) }
        guard kept.count >= n.count else { return nil }
        outer: for start in 0...(kept.count - n.count) {
            for k in 0..<n.count where hay[kept[start + k]] != n[k] { continue outer }
            return kept[start]..<(kept[start + n.count - 1] + 1)
        }
        return nil
    }

    // MARK: Copy fallback (only on an explicit click or hotkey)

    /// Sends ⌘C to the front app, reads the copied text, then puts the previous
    /// clipboard back. Works almost everywhere but gives no surrounding context.
    @MainActor private static var copying = false
    @MainActor private static var lateRestore: Task<Void, Never>?

    @MainActor
    static func readByCopying() async -> Selection? {
        // One at a time: two would each save and restore the other's ⌘C. And a newer read ends
        // the last one's wait for a late copy, which would otherwise restore over this one.
        guard !copying else { return nil }
        copying = true
        defer { copying = false }
        lateRestore?.cancel(); lateRestore = nil
        let pasteboard = NSPasteboard.general
        // A password manager marks what it copies as concealed and clears it later by its
        // change count; putting it back would leave the password on the clipboard for good.
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? [])
            .filter { !$0.types.contains(concealed) }
            .map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        func restore() {
            pasteboard.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        // Held ⌃⌥ (from the hotkey) would turn ⌘C into a different shortcut.
        for _ in 0..<30 where !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let before = pasteboard.changeCount
        postCommandC()
        for _ in 0..<20 where pasteboard.changeCount == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard pasteboard.changeCount != before else {
            note("copy: nothing was copied")
            // A slow app may still copy after we stop waiting: put the clipboard back if it does.
            // Only that one copy: more changes mean someone else copied too, so theirs stays.
            lateRestore = Task { @MainActor in
                for _ in 0..<80 {
                    try? await Task.sleep(for: .milliseconds(20))
                    if Task.isCancelled { return }
                    if pasteboard.changeCount == before + 1 { restore(); return }
                    if pasteboard.changeCount != before { return }
                }
            }
            return nil
        }
        let copied = pasteboard.string(forType: .string)
        restore()

        guard let copied, !copied.isEmpty else { return nil }
        let passage = Array(copied)
        return Selection(passage: passage, range: 0..<passage.count, bounds: nil, source: .clipboard,
                         appName: NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: AX helpers

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success, let out else { return nil }
        return out as? T
    }

    static func parameterized<T>(_ element: AXUIElement, _ name: String, _ param: CFTypeRef?) -> T? {
        guard let param else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, param, &out) == .success, let out else { return nil }
        return out as? T
    }
}
