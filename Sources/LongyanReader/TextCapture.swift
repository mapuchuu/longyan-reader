import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Text around a screen point, and which character the point is on.
struct CapturedText {
    enum Source: String { case accessibility, ocr }
    let passage: [Character]
    let index: Int
    let source: Source
    let appName: String?
}

/// Screen points here use the global CoreGraphics space: origin at the top-left
/// of the primary display, y growing downward (what Accessibility expects).
enum TextCapture {
    static func at(_ point: CGPoint) async -> CapturedText? {
        if let ax = accessibility(at: point) { return ax }
        return await ocr(at: point)
    }

    // MARK: Accessibility: exact text when the app exposes it.

    static func accessibility(at point: CGPoint) -> CapturedText? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &elementRef) == .success,
              let element = elementRef else { return nil }

        var p = point
        guard let pointValue = AXValueCreate(.cgPoint, &p),
              let rangeValue = parameterized(element, kAXRangeForPositionParameterizedAttribute, pointValue),
              let hit = cfRange(rangeValue), hit.location >= 0 else { return nil }

        // The hit must actually be under the cursor; apps return the nearest
        // character even when the point is past the end of a line.
        var one = CFRange(location: hit.location, length: 1)
        if let oneValue = AXValueCreate(.cfRange, &one),
           let boundsValue = parameterized(element, kAXBoundsForRangeParameterizedAttribute, oneValue) {
            var rect = CGRect.zero
            if AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
               rect.width > 0, !rect.insetBy(dx: -3, dy: -3).contains(point) {
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
              let text = textRef as? String else { return nil }

        // AX offsets are UTF-16; convert to a Character index.
        let utf16Offset = hit.location - start
        guard utf16Offset >= 0, utf16Offset < text.utf16.count,
              let stringIndex = String.Index(utf16Offset: utf16Offset, in: text).samePosition(in: text) else { return nil }
        let passage = Array(text)
        let index = text.distance(from: text.startIndex, to: stringIndex)
        guard passage.indices.contains(index), isCJK(passage[index]) else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName
        return CapturedText(passage: passage, index: index, source: .accessibility, appName: app)
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

    // MARK: OCR: works on anything visible (PDF scans, images, uncooperative apps).

    static func ocr(at point: CGPoint) async -> CapturedText? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 else { return nil }
        let rect = CGRect(x: point.x - 460, y: point.y - 130, width: 920, height: 260)
            .intersection(CGDisplayBounds(displayID))
        guard !rect.isNull, let image = try? await SCScreenshotManager.captureImage(in: rect) else { return nil }
        // Cursor position inside the image, normalised with a bottom-left origin (Vision's space).
        let cursor = CGPoint(x: (point.x - rect.minX) / rect.width, y: 1 - (point.y - rect.minY) / rect.height)
        guard var captured = locate(cursor, in: image) else { return nil }
        captured = CapturedText(passage: captured.passage, index: captured.index, source: .ocr,
                                appName: NSWorkspace.shared.frontmostApplication?.localizedName)
        return captured
    }

    /// Recognises text in `image` and finds the character at `cursor`
    /// (normalised, bottom-left origin). Separate from capture so it can be tested on files.
    static func locate(_ cursor: CGPoint, in image: CGImage) -> CapturedText? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { obs -> (box: CGRect, candidate: VNRecognizedText)? in
            guard let c = obs.topCandidates(1).first else { return nil }
            return (obs.boundingBox, c)
        }
        guard !lines.isEmpty else { return nil }

        // The line under the cursor, else the vertically nearest one that spans it horizontally.
        let slackY = 0.01
        let hitLine = lines.first { $0.box.insetBy(dx: 0, dy: -slackY).contains(cursor) }
            ?? lines.filter { $0.box.minX <= cursor.x && cursor.x <= $0.box.maxX }
                    .min { abs($0.box.midY - cursor.y) < abs($1.box.midY - cursor.y) }
        guard let line = hitLine, abs(line.box.midY - cursor.y) < line.box.height * 1.5 else { return nil }

        // Nearest character in that line by horizontal distance.
        let string = line.candidate.string
        var best: (offset: Int, distance: CGFloat)?
        for (offset, idx) in string.indices.enumerated() where isCJK(string[idx]) {
            let r = idx..<string.index(after: idx)
            guard let box = try? line.candidate.boundingBox(for: r)?.boundingBox else { continue }
            let d = box.minX <= cursor.x && cursor.x <= box.maxX ? 0 : min(abs(box.minX - cursor.x), abs(box.maxX - cursor.x))
            if best == nil || d < best!.distance { best = (offset, d) }
        }
        guard let hit = best else { return nil }

        // Reading order: top to bottom, then left to right. Wrapped Chinese lines join without spaces.
        let ordered = lines.sorted { abs($0.box.midY - $1.box.midY) > 0.02 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
        var passage: [Character] = []
        var index = 0
        for l in ordered {
            let chars = Array(l.candidate.string)
            if let last = passage.last, let first = chars.first, !(isCJK(last) || isCJK(first)) { passage.append(" ") }
            if l.box == line.box && l.candidate.string == string { index = passage.count + hit.offset }
            passage += chars
        }
        return CapturedText(passage: passage, index: index, source: .ocr, appName: nil)
    }
}
