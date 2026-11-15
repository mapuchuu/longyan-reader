import AppKit
import ApplicationServices
import SwiftUI

/// First-run window: why the app needs Accessibility, a button to the right Settings pane,
/// and a check every second that turns into "You're set" once the switch is on.
@MainActor
final class Onboarding {
    static let shared = Onboarding()
    private var window: NSWindow?
    private var timer: Timer?
    var onTrusted: () -> Void = {}

    func showIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        show()
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let model = OnboardingModel()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Longyan Reader"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in self?.close() })
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard AXIsProcessTrusted(), !model.trusted else { return }
                model.trusted = true
                self?.onTrusted()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.timer?.invalidate(); self?.timer = nil; self?.window = nil }
        }
    }

    func close() { window?.close() }

    static func openAccessibilitySettings() {
        // The prompt also adds the app to the Accessibility list, so the user only flips a switch.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// The Accessibility grant belongs to the app at its path; moving it later means granting again.
    static var outsideApplications: Bool {
        let path = Bundle.main.bundlePath
        return !(path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
            && path.hasSuffix(".app")
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
}

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlight Chinese text in any app, then click the eye that appears or press ⌃⌥L.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("To read what you highlight, Longyan Reader needs the **Accessibility** permission. It reads only the selection and the sentence around it, when you ask. Lookups stay on this Mac: the dictionary and the model run locally, and nothing is sent anywhere. The words you look up are kept for review and flashcards under History… in the menu, where you can also turn that off.")
                .fixedSize(horizontal: false, vertical: true)
            if Onboarding.outsideApplications && !model.trusted {
                Label("Move the app to your Applications folder first: the permission is tied to where the app is, so moving it later means granting it again.", systemImage: "folder")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
            if model.trusted {
                Label("You're set. Highlight some Chinese text to try it.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
            } else {
                Text("In System Settings, turn on Longyan Reader under Privacy & Security › Accessibility. This window notices as soon as you do.")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Later", action: done)
                    Button("Open Accessibility Settings") { Onboarding.openAccessibilitySettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// The standard About panel, with the credits the dictionary and model licences ask for.
enum About {
    @MainActor static func show() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString()
        func add(_ s: String, font: NSFont = body, link: String? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if let link { attrs[.link] = URL(string: link) }
            credits.append(NSAttributedString(string: s, attributes: attrs))
        }
        add("Dictionary\n", font: bold)
        add("CC-CEDICT, © MDBG and contributors; based on CEDICT © 1997–1998 Paul Andrew Denisowski. Licensed under ")
        add("CC BY-SA 4.0", link: "https://creativecommons.org/licenses/by-sa/4.0/")
        add(". Modified: senses reordered, words added, notes attached. ")
        add("cc-cedict.org", link: "https://cc-cedict.org/")
        add("\n\nModels\n", font: bold)
        add("Sense picks and translations come from a local language model (Qwen 3.5, Apache 2.0, run in the app with llama.cpp, MIT; or through Ollama), or Apple's on-device models and Translation framework. They can be wrong: check a pick against the other listed senses. Sentence translations are machine translations.")
        add("\n\nNotes\n", font: bold)
        add("The cultural and nuance notes were written by an AI model (Claude) and checked against the dictionary senses they attach to; they can contain mistakes.")
        add("\n\nPrivacy\n", font: bold)
        add("Lookups are processed on this Mac. Lookup history (History… in the menu, which exports flashcards) is kept on this Mac in ~/Library/Logs/LongyanReader/lookups.jsonl, readable only by your account; Lookup History in the menu turns it off or clears it.")
        NSApp.activate()
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "Longyan Reader", .credits: credits]
        if let mark = Icons.mark(size: 64) {
            // The mark is a template image (black); tint it so it shows in dark mode too.
            options[.applicationIcon] = NSImage(size: mark.size, flipped: false) { rect in
                mark.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
