import AppKit
import SwiftUI

/// How characters and pinyin are coloured by tone, chosen under Appearance ▸ Tone Colors.
enum ToneScheme: String, CaseIterable {
    /// Red, green, blue, purple: the order Pleco uses. The default.
    case standard
    /// Red, orange, green, blue: Nathan Dummitt's order, used by MDBG.
    case dummitt
    /// One colour per tone, picked in the Tone Colors window.
    case custom
    case off

    /// The menu's names: the swatch beside each shows its colours.
    var label: String {
        switch self {
        case .standard: "Standard"
        case .dummitt: "Dummitt"
        case .custom: "Custom"
        case .off: "Off"
        }
    }

    /// The colours in words, for the menu's help and VoiceOver.
    var colorNames: String? {
        switch self {
        case .standard: "Red, green, blue, purple"
        case .dummitt: "Red, orange, green, blue: Nathan Dummitt's colors, used by MDBG"
        case .custom, .off: nil
        }
    }
}

/// Tone colours, muted so they sit quietly on the card: soft in light mode, pastel in dark.
/// The neutral tone always uses the secondary label colour.
enum ToneColors {
    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

    private static let schemeKey = "toneScheme", customKey = "toneCustom"
    /// Posted after any change, so open cards and the menu's swatches follow.
    static let changed = Notification.Name("ToneColorsChanged")
    /// Goes up with every change. Cards read it from the environment, so they redraw.
    nonisolated(unsafe) private(set) static var revision = 0

    static var scheme: ToneScheme {
        get {
            let d = UserDefaults.standard
            if let s = d.string(forKey: schemeKey).flatMap(ToneScheme.init) { return s }
            // Before 1.0.1 this was an on/off switch.
            return d.object(forKey: "toneColors") as? Bool == false ? .off : .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: schemeKey)
            didChange()
        }
    }
    static var enabled: Bool { scheme != .off }

    /// Light and dark versions of tones 1 to 4. Each light colour has a contrast of at least
    /// 4.2 on the light card, and each dark one at least 7.5 on the dark card.
    static let standard: [(light: RGB, dark: RGB)] = [
        ((0.66, 0.33, 0.30), (0.89, 0.62, 0.58)),   // brick
        ((0.29, 0.53, 0.38), (0.62, 0.80, 0.66)),   // sage
        ((0.29, 0.45, 0.65), (0.63, 0.74, 0.89)),   // slate
        ((0.50, 0.38, 0.64), (0.76, 0.67, 0.88)),   // violet
    ]
    static let dummitt: [(light: RGB, dark: RGB)] = [
        standard[0],
        ((0.60, 0.43, 0.10), (0.92, 0.79, 0.48)),   // amber
        standard[1],
        standard[2],
    ]

    /// The custom colours, one per tone, as picked. Until some are, the light standard ones.
    static var custom: [RGB] {
        get {
            let saved = (UserDefaults.standard.stringArray(forKey: customKey) ?? []).compactMap(rgb(hex:))
            return saved.count == 4 ? saved : standard.map(\.light)
        }
        set {
            UserDefaults.standard.set(newValue.map(hex), forKey: customKey)
            didChange()
        }
    }

    /// Tone 1 to 4's colour in a scheme; nil for the neutral tone or with colours off.
    static func color(_ n: Int, in scheme: ToneScheme = scheme) -> Color? {
        guard (1...4).contains(n) else { return nil }
        let pair: (light: RGB, dark: RGB)
        switch scheme {
        case .off: return nil
        case .standard: pair = standard[n - 1]
        case .dummitt: pair = dummitt[n - 1]
        case .custom: pair = readable(custom[n - 1])
        }
        return tone(light: pair.light, dark: pair.dark)
    }

    /// The card surfaces the colours sit on (see `cardSurface`).
    static let lightCard: RGB = (1, 1, 1), darkCard: RGB = (0.12, 0.12, 0.13)

    /// A picked colour's light and dark versions: darkened toward black until it has a
    /// contrast of 4.2 on the light card, and lightened toward white until it has 7 on the
    /// dark card, each only as far as needed. The built-in colours already pass both.
    static func readable(_ c: RGB) -> (light: RGB, dark: RGB) {
        func toward(_ target: RGB, on card: RGB, minimum: CGFloat) -> RGB {
            var t: CGFloat = 0, out = c
            while contrast(out, card) < minimum, t < 1 {
                t += 0.02
                out = (c.r + (target.r - c.r) * t, c.g + (target.g - c.g) * t, c.b + (target.b - c.b) * t)
            }
            return out
        }
        return (toward((0, 0, 0), on: lightCard, minimum: 4.2), toward((1, 1, 1), on: darkCard, minimum: 7))
    }

    /// WCAG contrast ratio between two sRGB colours.
    static func contrast(_ a: RGB, _ b: RGB) -> CGFloat {
        func luminance(_ c: RGB) -> CGFloat {
            func f(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// A strip of the scheme's four colours, for its menu item. It's drawn when shown, so it
    /// follows the menu's light or dark appearance.
    /// Four dots in the scheme's colours for its menu item, each with a hairline edge so
    /// pale colours hold their shape on the menu, the way Finder draws its tag dots.
    static func swatch(_ scheme: ToneScheme) -> NSImage {
        let dot: CGFloat = 10, gap: CGFloat = 2
        let image = NSImage(size: NSSize(width: 4 * dot + 3 * gap, height: dot), flipped: false) { _ in
            for tone in 1...4 {
                let rect = NSRect(x: CGFloat(tone - 1) * (dot + gap), y: 0, width: dot, height: dot)
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
                (color(tone, in: scheme).map { NSColor($0) } ?? .clear).setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.lineWidth = 0.5
                path.stroke()
            }
            return true
        }
        image.accessibilityDescription = scheme.colorNames ?? scheme.label
        return image
    }

    private static func didChange() {
        revision += 1
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func hex(_ c: RGB) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    static func rgb(hex: String) -> RGB? {
        guard hex.count == 7, hex.first == "#", let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return (CGFloat(v >> 16 & 0xFF) / 255, CGFloat(v >> 8 & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
    }
}

/// A colour with a light-mode and a dark-mode version, for the tone and note colours.
func tone(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}

/// The tone colours' revision, set on every card, so a card redraws when they change.
private struct ToneRevisionKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var toneRevision: Int {
        get { self[ToneRevisionKey.self] }
        set { self[ToneRevisionKey.self] = newValue }
    }
}

/// A character's colour: its tone's when tone colours are on, else the primary label.
func hanziColor(_ t: Int) -> Color { ToneColors.enabled ? ToneColors.color(t) ?? .secondary : .primary }
/// A pinyin syllable's colour: its tone's when tone colours are on, else the secondary label.
func pinyinColor(_ t: Int) -> Color { ToneColors.color(t) ?? .secondary }
