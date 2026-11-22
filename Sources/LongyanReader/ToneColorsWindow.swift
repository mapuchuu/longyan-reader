import AppKit
import SwiftUI

/// Picks the custom tone colours, from Appearance ▸ Tone Colors ▸ Custom…. Every change
/// shows on the open card at once.
@MainActor
final class ToneColorsWindow {
    static let shared = ToneColorsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ToneColorsView { [weak self] in self?.window?.close() }))
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
    let done: () -> Void
    @State private var picked: [ToneColors.RGB] = ToneColors.custom

    private static let names = ["First tone", "Second tone", "Third tone", "Fourth tone"]
    private static let syllables = ["mā", "má", "mǎ", "mà"], characters = ["妈", "麻", "马", "骂"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a color for each tone. Where needed, it's darkened on the light card or lightened on the dark one, so it stays easy to read.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                preview(dark: false)
                preview(dark: true)
            }
            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    HStack {
                        Text(Self.syllables[i]).font(.body.weight(.medium)).foregroundStyle(shown(i))
                            .frame(width: 30, alignment: .leading)
                        Text(Self.names[i])
                        Spacer()
                        ColorPicker(Self.names[i], selection: binding(i), supportsOpacity: false).labelsHidden()
                    }
                }
            }
            HStack {
                Button("Reset") { save(ToneColors.standard.map(\.light)) }
                    .help("Use the red, green, blue and purple of the light card")
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// 妈 麻 马 骂 with their pinyin, on the card's light or dark surface, in the colours the
    /// card will use there.
    private func preview(dark: Bool) -> some View {
        let colors = picked.map { Self.color(dark ? ToneColors.readable($0).dark : ToneColors.readable($0).light) }
        let card = dark ? ToneColors.darkCard : ToneColors.lightCard
        return VStack(spacing: 2) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { Text(Self.characters[$0]).foregroundStyle(colors[$0]) }
            }
            .font(.system(size: 22, weight: .medium))
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { Text(Self.syllables[$0]).foregroundStyle(colors[$0]) }
            }
            .font(.system(size: 12))
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.color(card)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dark ? "Preview on the dark card" : "Preview on the light card")
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
