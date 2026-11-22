import AppKit
import SwiftUI

/// Picks the custom tone colours, from Appearance ▸ Tone Colors ▸ Edit Custom Colors….
/// Like a settings window, every change applies at once, so there's nothing to confirm:
/// it just closes.
@MainActor
final class ToneColorsWindow {
    static let shared = ToneColorsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ToneColorsView()))
            w.styleMask = [.titled, .closable]
            w.title = "Tone Colors"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct ToneColorsView: View {
    @State private var picked: [ToneColors.RGB] = ToneColors.custom

    private static let names = ["First tone", "Second tone", "Third tone", "Fourth tone"]
    private static let syllables = ["mā", "má", "mǎ", "mà"], characters = ["妈", "麻", "马", "骂"]

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    preview
                }
                Section {
                    ForEach(0..<4, id: \.self) { i in
                        LabeledContent {
                            ColorPicker(Self.names[i], selection: binding(i), supportsOpacity: false).labelsHidden()
                        } label: {
                            Text(Self.names[i])
                            Text(Self.syllables[i])
                        }
                    }
                } footer: {
                    Text("The same colors are used in light and dark mode.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 362)
            Button("Restore Defaults") { save(ToneColors.standard.map(\.light)) }
                .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
    }

    /// The card's own header, 妈麻马骂 with its pinyin beside it, in the colours a card shows
    /// in this appearance.
    private var preview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { Text(Self.characters[$0]).foregroundStyle(shown($0)) }
            }
            .font(.system(size: TextSize.headword, weight: .medium))
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { Text(Self.syllables[$0]).foregroundStyle(shown($0)) }
            }
            .font(.system(size: TextSize.title3))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: mā, má, mǎ, mà")
    }

    private func binding(_ i: Int) -> Binding<Color> {
        Binding(get: { Self.color(picked[i]) }, set: { new in
            guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
            var all = ToneColors.custom
            all[i] = (c.redComponent, c.greenComponent, c.blueComponent)
            save(all)
        })
    }

    /// Picking a colour chooses the custom scheme too.
    private func save(_ all: [ToneColors.RGB]) {
        ToneColors.custom = all
        if ToneColors.scheme != .custom { ToneColors.scheme = .custom }
        picked = ToneColors.custom
    }

    /// A tone's colour in the window's own light or dark mode, as a card would show it.
    private func shown(_ i: Int) -> Color {
        let pair = ToneColors.readable(picked[i])
        return tone(light: pair.light, dark: pair.dark)
    }

    private static func color(_ c: ToneColors.RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }
}
