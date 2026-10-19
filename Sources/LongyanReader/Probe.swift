import AppKit
import ApplicationServices

/// Debug aid: describes what an app exposes through Accessibility around its focused
/// element (roles, attribute names, text lengths; not the text itself), so selection
/// reading can be fixed per app. Trigger from a terminal:
///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.mapuchuu.longyanreader.probe"), object: "com.apple.Preview", userInfo: nil, deliverImmediately: true)'
enum Probe {
    static func run(bundleID raw: String) -> String {
        // "bundle.id|enhanced" turns on the VoiceOver-style accessibility switch first.
        let parts = raw.split(separator: "|").map(String.init)
        let bundleID = parts.first ?? raw
        if parts.count > 1, parts[1] == "enhanced",
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            Thread.sleep(forTimeInterval: 1.5)
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return "\(bundleID) is not running"
        }
        var out = ["app \(bundleID) pid \(app.processIdentifier) frontmost=\(app.isActive)"]
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1)
        for attr in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var value: CFTypeRef?
            let r = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
            out.append("\(attr): read \(r.rawValue) value \(value.map { "\($0)" } ?? "nil")")
        }
        out.append("app attributes: \(names(element))")

        var focused: CFTypeRef?
        let fr = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused)
        out.append("focused element: result \(fr.rawValue)")
        var current = focused.map { $0 as! AXUIElement }
        if current == nil {
            // Fall back to the focused window's tree.
            var window: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window)
            out.append("focused window: \(window == nil ? "none" : "found")")
            current = window.map { $0 as! AXUIElement }
        }
        if let f = current {
            out.append("=== children of the focused element")
            dumpChildren(f, depth: 0, into: &out)
        }
        var depth = 0
        while let e = current, depth < 8 {
            out.append("--- level \(depth): " + describe(e))
            var parent: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent)
            current = parent.map { $0 as! AXUIElement }
            depth += 1
        }
        return out.joined(separator: "\n")
    }

    private static func names(_ e: AXUIElement) -> String {
        var names: CFArray?
        AXUIElementCopyAttributeNames(e, &names)
        return ((names as? [String]) ?? []).joined(separator: ", ")
    }

    private static func describe(_ e: AXUIElement) -> String {
        var lines: [String] = []
        func value(_ attr: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? v : nil
        }
        lines.append("role \(value(kAXRoleAttribute) as? String ?? "?") subrole \(value(kAXSubroleAttribute) as? String ?? "-")")
        lines.append("  attributes: \(names(e))")
        var params: CFArray?
        AXUIElementCopyParameterizedAttributeNames(e, &params)
        lines.append("  parameterized: \(((params as? [String]) ?? []).joined(separator: ", "))")
        if let s = value(kAXSelectedTextAttribute) as? String { lines.append("  AXSelectedText length \(s.count)") }
        if let v = value(kAXSelectedTextRangeAttribute) {
            var r = CFRange()
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetValue(v as! AXValue, .cfRange, &r) {
                lines.append("  AXSelectedTextRange \(r.location),\(r.length)")
            }
        }
        if let v = value(kAXValueAttribute) as? String { lines.append("  AXValue length \(v.count)") }
        if let n = value(kAXNumberOfCharactersAttribute) as? Int { lines.append("  AXNumberOfCharacters \(n)") }
        if let m = value("AXSelectedTextMarkerRange") { lines.append("  AXSelectedTextMarkerRange present (type \(CFGetTypeID(m) == AXTextMarkerRangeGetTypeID() ? "marker range" : "other"))") }
        if let ranges = value("AXSelectedTextRanges") as? [AnyObject] { lines.append("  AXSelectedTextRanges count \(ranges.count)") }
        return lines.joined(separator: "\n")
    }

    private static func dumpChildren(_ e: AXUIElement, depth: Int, into out: inout [String]) {
        guard depth < 4 else { return }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children)
        let list = (children as? [AXUIElement]) ?? []
        for (i, child) in list.prefix(4).enumerated() {
            let pad = String(repeating: "  ", count: depth + 1)
            out.append(pad + "[\(i)/\(list.count)] " + describe(child).replacingOccurrences(of: "\n", with: "\n" + pad))
            dumpChildren(child, depth: depth + 1, into: &out)
        }
    }
}
