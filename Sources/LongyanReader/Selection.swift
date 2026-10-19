import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Text the user highlighted, with the text around it when the app exposes it.
struct Selection {
    enum Source: String { case accessibility, clipboard }
    let passage: [Character]
    let range: Range<Int>          // the selection, as character offsets into passage
    let bounds: CGRect?            // selection on screen, CoreGraphics space (top-left origin)
    let source: Source
    let appName: String?

    var text: String { String(passage[range]) }
    var hasChinese: Bool { passage[range].contains(where: isCJK) }

    /// Trims surrounding whitespace and punctuation so "，研究生。" looks up 研究生.
    func trimmed() -> Selection {
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi, !isCJK(passage[lo]), !passage[lo].isLetter { lo += 1 }
        while hi > lo, !isCJK(passage[hi - 1]), !passage[hi - 1].isLetter { hi -= 1 }
        return Selection(passage: passage, range: lo..<hi, bounds: bounds, source: source, appName: appName)
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

    static func readAccessibility() -> Result {
        trace = []
        guard AXIsProcessTrusted() else { note("not trusted"); return .unreadable }
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unreadable }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        enableAccessibilityTree(appElement, pid: app.processIdentifier)

        guard let focused: AXUIElement = attribute(appElement, kAXFocusedUIElementAttribute) else {
            note("no focused element in \(app.localizedName ?? "?")")
            return .unreadable
        }
        note("focused \(attribute(focused, kAXRoleAttribute) as String? ?? "?") in \(app.localizedName ?? "?")")

        if let s = nativeSelection(focused, app: app.localizedName) { return s }
        if let s = webSelection(focused, app: app.localizedName) { return s }
        return .unreadable
    }

    /// Chrome, Electron and other Chromium apps keep their accessibility tree off
    /// until an assistive app asks for it. Ask once per process.
    private static var enabledPIDs: Set<pid_t> = []
    private static func enableAccessibilityTree(_ appElement: AXUIElement, pid: pid_t) {
        guard !enabledPIDs.contains(pid) else { return }
        enabledPIDs.insert(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
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

    // MARK: Copy fallback (only on an explicit click or hotkey)

    /// Sends ⌘C to the front app, reads the copied text, then puts the previous
    /// clipboard back. Works almost everywhere but gives no surrounding context.
    static func readByCopying() async -> Selection? {
        let pasteboard = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
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
