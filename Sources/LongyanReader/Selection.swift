import AppKit
import ApplicationServices
import Carbon.HIToolbox
import PDFKit

/// Text the user highlighted, with the text around it when the app exposes it.
struct Selection {
    enum Source: String { case accessibility, clipboard }
    let passage: [Character]
    let range: Range<Int>          // the selection, as character offsets into passage
    let bounds: CGRect?            // selection on screen, CoreGraphics space (top-left origin)
    let source: Source
    let appName: String?

    var text: String { String(passage[range]) }

    func withoutBounds() -> Selection {
        Selection(passage: passage, range: range, bounds: nil, source: source, appName: appName)
    }
    var hasChinese: Bool { passage[range].contains(where: isCJK) }

    /// Trims surrounding whitespace and punctuation so "，研究生。" looks up 研究生.
    func trimmed() -> Selection {
        let s = unwrapped()
        var lo = s.range.lowerBound, hi = s.range.upperBound
        while lo < hi, !isCJK(s.passage[lo]), !s.passage[lo].isLetter { lo += 1 }
        while hi > lo, !isCJK(s.passage[hi - 1]), !s.passage[hi - 1].isLetter { hi -= 1 }
        return Selection(passage: s.passage, range: lo..<hi, bounds: bounds, source: source, appName: appName)
    }

    /// Text in PDFs and narrow columns wraps mid-word (跟着师⏎父), which splits words and makes
    /// translators treat each line as its own sentence. Removes single line breaks next to
    /// Chinese text, and the spaces around them; a blank line is a real break and stays.
    private func unwrapped() -> Selection {
        var out: [Character] = []
        var lo = 0, hi = 0
        var i = 0
        while i <= passage.count {
            if i == range.lowerBound { lo = out.count }
            if i == range.upperBound { hi = out.count }
            guard i < passage.count else { break }
            guard passage[i].isNewline else { out.append(passage[i]); i += 1; continue }
            // The whole run of whitespace around this line break.
            var end = i
            var breaks = 0
            while end < passage.count, passage[end].isWhitespace {
                if passage[end].isNewline { breaks += 1 }
                end += 1
            }
            var kept = out.count
            while kept > 0, out[kept - 1].isWhitespace { kept -= 1 }
            let prev = kept > 0 ? out[kept - 1] : nil, next = end < passage.count ? passage[end] : nil
            guard breaks == 1, let prev, let next, !prev.isASCII || !next.isASCII else {
                out.append(contentsOf: passage[i..<end])
                for j in i...end where j == range.lowerBound || j == range.upperBound {
                    if j == range.lowerBound { lo = out.count }
                    if j == range.upperBound { hi = out.count }
                }
                i = end
                continue
            }
            out.removeSubrange(kept...)
            if range.lowerBound >= kept, range.lowerBound <= end { lo = min(lo, kept) }
            if range.upperBound >= kept, range.upperBound <= end { hi = min(hi, kept) }
            i = end
        }
        return Selection(passage: out, range: lo..<max(lo, hi), bounds: bounds, source: source, appName: appName)
    }
}

/// Screen points use the global CoreGraphics space: origin at the top-left of the
/// primary display, y growing downward (what Accessibility expects).
enum SelectionReader {
    enum Result { case selection(Selection), nothingSelected, unreadable }

    /// Why the last read failed; written to the lookup log.
    static var trace: [String] = []
    private static func note(_ s: String) { trace.append(s) }

    // MARK: Accessibility (no side effects)

    static func readAccessibility(from target: NSRunningApplication? = nil) -> Result {
        trace = []
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
    /// AXManualAccessibility. Called when such an app comes to the front, so the tree is
    /// ready by the time text is selected. Chrome keeps it on until it quits.
    private static var preparedPIDs: Set<pid_t> = []
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]
    static func prepare(_ app: NSRunningApplication) {
        guard AXIsProcessTrusted(), !preparedPIDs.contains(app.processIdentifier) else { return }
        preparedPIDs.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBrowsers.contains(app.bundleIdentifier ?? "") {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// Text fields, TextEdit, Notes, Pages, Preview: selection as a character range.
    private static func nativeSelection(_ element: AXUIElement, app: String?) -> Result? {
        guard let rangeValue: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var sel = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &sel) else { return nil }
        if sel.length == 0 { note("native: empty selection"); return .nothingSelected }

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
        while let e = element, markerRange == nil {
            markerRange = attribute(e, "AXSelectedTextMarkerRange")
            if markerRange == nil { element = attribute(e, kAXParentAttribute) }
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
            if let around: CFTypeRef = parameterized(e, attr, start),
               let text: String = parameterized(e, "AXStringForTextMarkerRange", around),
               let r = text.range(of: selected) {
                passageText = text
                lo = text.distance(from: text.startIndex, to: r.lowerBound)
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
            guard let d = PDFDocument(url: url) else { note("pdf: couldn't open \(url.lastPathComponent)"); return nil }
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
    static func readByCopying() async -> Selection? {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
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
        guard pasteboard.changeCount != before else { note("copy: nothing was copied"); return nil }
        let copied = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        let restored = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }

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
