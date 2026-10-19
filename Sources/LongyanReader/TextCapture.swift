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
        guard let pointValue = AXValueCreate(.cgPoint, &p),
              let rangeValue = parameterized(element, kAXRangeForPositionParameterizedAttribute, pointValue),
              let hit = cfRange(rangeValue), hit.location >= 0 else { note("ax: element has no range-for-position"); return nil }

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
            note("ax: character at point is not Chinese (\(passage.indices.contains(index) ? String(passage[index]) : "out of range"))")
            return nil
        }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName
        return CapturedText(passage: passage, index: index, appName: app)
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
