import AppKit
import ApplicationServices

/// Text around a screen point, and which character the point is on.
/// Used when ⌃⌥L is pressed with nothing selected.
struct CapturedText {
    let passage: [Character]
    let index: Int
    let appName: String?
}

/// Screen points here use the global CoreGraphics space: origin at the top-left
/// of the primary display, y growing downward (what Accessibility expects).
enum TextCapture {
    /// Why the last capture failed, step by step; written to the lookup log.
    static var trace: [String] = []
    private static func note(_ s: String) { trace.append(s) }

    static func at(_ point: CGPoint) -> CapturedText? {
        trace = []
        return accessibility(at: point)
    }

    /// A spreadsheet cell under the point (Numbers), which gives its text but not where each
    /// character is: the whole cell is looked up instead of one word.
    static func cell(at point: CGPoint) -> (text: String, frame: CGRect, appName: String?)? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else { return nil }
        var role: CFTypeRef?, frameRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard (role as? String) == kAXCellRole else { return nil }
        // Numbers puts a cell's text in its title.
        var text: String?
        for attr in [kAXValueAttribute, kAXTitleAttribute] where text == nil {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr as CFString, &v)
            if let s = v as? String, s.contains(where: isCJK) { text = s }
        }
        // A header cell's title ends with a label for VoiceOver: "句子, Column header cell".
        if let t = text, let r = t.range(of: #", [A-Za-z ]*(header|footer) cell$"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(t[..<r.lowerBound])
        }
        guard let text else { return nil }
        var frame = CGRect.zero
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success, let frameRef,
           CFGetTypeID(frameRef) == AXValueGetTypeID() { AXValueGetValue(frameRef as! AXValue, .cgRect, &frame) }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        note("ax: whole cell")
        return (text, frame, NSRunningApplication(processIdentifier: pid)?.localizedName)
    }

    // MARK: Accessibility: exact text when the app exposes it.

    static func accessibility(at point: CGPoint) -> CapturedText? {
        guard AXIsProcessTrusted() else { note("ax: not trusted"); return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else { note("ax: no element at point"); return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        note("ax: element \((roleRef as? String) ?? "?")")

        var p = point
        let hit: CFRange
        if let pointValue = AXValueCreate(.cgPoint, &p),
           let rangeValue = parameterized(element, kAXRangeForPositionParameterizedAttribute, pointValue),
           let r = cfRange(rangeValue), r.location >= 0 {
            hit = r
        } else if let index = indexByBounds(at: point, in: element) {
            hit = CFRange(location: index, length: 1)
        } else { note("ax: element has no range-for-position"); return nil }

        // The hit must actually be under the cursor; apps return the nearest
        // character even when the point is past the end of a line.
        var one = CFRange(location: hit.location, length: 1)
        if let oneValue = AXValueCreate(.cfRange, &one),
           let boundsValue = parameterized(element, kAXBoundsForRangeParameterizedAttribute, oneValue) {
            var rect = CGRect.zero
            if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
               rect.width > 0, !rect.insetBy(dx: -3, dy: -3).contains(point) {
                note("ax: hit character \(hit.location) is not under the cursor")
                return nil
            }
        }

        var total = 0
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let n = countRef as? Int { total = n }
        guard hit.location < Int.max / 4 else { note("ax: invalid hit location"); return nil }   // kCFNotFound
        let start = max(0, hit.location - 400)
        let end = total > 0 ? min(total, hit.location + 400) : hit.location + 400
        var window = CFRange(location: start, length: end - start)
        guard let windowValue = AXValueCreate(.cfRange, &window),
              let textRef = parameterized(element, kAXStringForRangeParameterizedAttribute, windowValue),
              let text = textRef as? String else { note("ax: no string for range"); return nil }

        // AX offsets are UTF-16; convert to a Character index.
        let utf16Offset = hit.location - start
        guard utf16Offset >= 0, utf16Offset < text.utf16.count,
              let stringIndex = String.Index(utf16Offset: utf16Offset, in: text).samePosition(in: text) else { return nil }
        let passage = Array(text)
        let index = text.distance(from: text.startIndex, to: stringIndex)
        guard passage.indices.contains(index), isCJK(passage[index]) else {
            note("ax: character at point is not Chinese")
            return nil
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName
        return CapturedText(passage: passage, index: index, appName: app)
    }

    /// Pages has no range-for-position, but it does give each line's range and each range's
    /// bounds: find the visible line under the point, then the character in it.
    private static func indexByBounds(at point: CGPoint, in element: AXUIElement) -> Int? {
        var visibleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &visibleRef) == .success,
              let visibleRef, let visible = cfRange(visibleRef), visible.length > 0, visible.location >= 0,
              visible.location < Int.max / 4, visible.length < 100_000 else { return nil }
        func bounds(_ range: CFRange) -> CGRect? {
            var r = range
            guard let value = AXValueCreate(.cfRange, &r),
                  let b = parameterized(element, kAXBoundsForRangeParameterizedAttribute, value) else { return nil }
            var rect = CGRect.zero
            return AXValueGetValue(b as! AXValue, .cgRect, &rect) && rect.width > 0 ? rect : nil
        }
        func lineRange(_ index: Int) -> CFRange? {
            guard let lineRef = parameterized(element, kAXLineForIndexParameterizedAttribute, index as CFNumber),
                  let line = lineRef as? Int,
                  let rangeRef = parameterized(element, kAXRangeForLineParameterizedAttribute, line as CFNumber) else { return nil }
            return cfRange(rangeRef)
        }
        // Line by line through what's on screen; a few dozen lines, each two quick queries.
        var i = visible.location
        let end = visible.location + visible.length
        var lines = 0
        while i < end, lines < 200 {
            guard let line = lineRange(i), line.length > 0, line.location + line.length > i else { return nil }
            lines += 1
            if let lb = bounds(line), lb.minY - 2 <= point.y, point.y <= lb.maxY + 2 {
                for c in line.location..<min(line.location + line.length, line.location + 300) {
                    if let cb = bounds(CFRange(location: c, length: 1)), cb.minX <= point.x, point.x < cb.maxX { return c }
                }
                return nil
            }
            i = line.location + line.length
        }
        note("ax: no line under the point")
        return nil
    }

    private static func parameterized(_ element: AXUIElement, _ attribute: String, _ param: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, param, &out) == .success else { return nil }
        return out
    }

    private static func cfRange(_ value: CFTypeRef) -> CFRange? {
        var r = CFRange()
        guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &r) else { return nil }
        return r
    }
}
