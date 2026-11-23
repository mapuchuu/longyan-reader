import AppKit
import QuartzCore
import SwiftUI

/// Dev only: `--show … --trace FILE` (CardShow.swift) writes, for every frame the display shows
/// while anything on the card moves, one JSON line of what is on screen: the window's opacity
/// and frame (points from the main screen's top-left, as --show's x and y), the card's reveal
/// scale, offset and height, and each part that animates by name (row1-hover,
/// row1-checkmark, phrase-row1-chevron, showall-chevron, back-to, note-box, detail, pin-badge,
/// copy-press…). Windows writes the same lines (windows/LongyanReader/CardWindow.Script.cs).
///
/// The values are SwiftUI's own, frame by frame: each probe is an Animatable modifier set
/// beside the modifier it reads, with the same value, so the same animation drives it and
/// SwiftUI hands it every in-between value as it draws. A line is written only when something
/// differs from the last one. A part that has left keeps its last value (a removal ends at 0).
enum CardTrace {
    /// Set by --trace, before the first card: the probes go in only then.
    nonisolated(unsafe) static var enabled = false
    /// Each part's values, as last drawn.
    nonisolated(unsafe) static var values: [String: [String: Double]] = [:]

    static func record(_ name: String, _ key: String, _ value: Double) {
        values[name, default: [:]][key] = value
    }
}

private struct TraceProbe: ViewModifier, Animatable {
    let name: String
    let key: String
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    func body(content: Content) -> some View {
        CardTrace.record(name, key, value)
        // Not `content` alone: SwiftUI skips the body of a modifier that is only its content.
        return content.opacity(1)
    }
}

/// An insertion or removal, as its progress (1 when in) and the offset it slides by.
private struct TraceTransition: ViewModifier, Animatable {
    let name: String
    let slide: Double
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        CardTrace.record(name, "opacity", progress)
        if slide != 0 { CardTrace.record(name, "dy", (1 - progress) * slide) }
        return content.opacity(1)
    }
}

extension View {
    /// Reports `value` under `name`'s `key` each frame it's drawn, when tracing (CardTrace).
    @ViewBuilder func traceProbe(_ name: String?, _ key: String, _ value: Double) -> some View {
        if CardTrace.enabled, let name, !name.isEmpty { modifier(TraceProbe(name: name, key: key, value: value)) } else { self }
    }
}

extension AnyTransition {
    /// This transition, reported under `name` as it runs, when tracing (CardTrace).
    func traced(_ name: String, slide: Double = 0) -> AnyTransition {
        guard CardTrace.enabled else { return self }
        return combined(with: .modifier(active: TraceTransition(name: name, slide: slide, progress: 0),
                                        identity: TraceTransition(name: name, slide: slide, progress: 1)))
    }
}

/// Samples the probes and the window on the display's own clock and writes the lines.
@MainActor
final class CardTracer: NSObject {
    private let out: FileHandle
    private var link: CADisplayLink?
    private var last = ""
    /// The last card's window, still fading out once the controller has let it go.
    private weak var lastWindow: NSWindow?
    /// The window the card is in, and which card it is (one more each time it opens).
    var window: () -> NSWindow? = { nil }
    var card = 0

    init?(path: String) {
        guard FileManager.default.createFile(atPath: path, contents: nil), let out = FileHandle(forWritingAtPath: path) else { return nil }
        self.out = out
        super.init()
        CardTrace.enabled = true
    }

    func start() {
        guard let screen = NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let line = describe() else { return }
        guard line != last else { return }
        last = line
        out.write(Data((String(format: "{\"mono\":%.3f,", link.timestamp * 1000) + line + "}\n").utf8))
    }

    private static func n(_ v: Double) -> String {
        let r = (v * 10000).rounded() / 10000
        return r == r.rounded() ? String(Int(r)) : String(format: "%.4f", r).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    private func describe() -> String? {
        if let w = window() { lastWindow = w }
        guard let w = lastWindow, w.isVisible else { return nil }
        let n = Self.n
        let mainHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let f = w.frame
        var values = CardTrace.values
        let card = values.removeValue(forKey: "card") ?? [:]
        let parts = values.keys.sorted().map { name in
            let v = values[name]!
            return "\"\(name)\":{" + v.keys.sorted().map { "\"\($0)\":\(n(v[$0]!))" }.joined(separator: ",") + "}"
        }
        return "\"card\":\(self.card),\"alpha\":\(n(Double(w.alphaValue))),\"scale\":\(n(card["scale"] ?? 1)),\"dy\":\(n(card["dy"] ?? 0)),"
            + "\"height\":\(n(card["height"] ?? 0)),\"frame\":[\(n(f.minX)),\(n(mainHeight - f.maxY)),\(n(f.width)),\(n(f.height))],"
            + "\"elements\":{" + parts.joined(separator: ",") + "}"
    }
}
