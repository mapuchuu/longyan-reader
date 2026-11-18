import AppKit
import ApplicationServices
import SwiftUI

/// First-run window, in two steps. First Accessibility: why the app needs it, a button to the
/// right Settings pane, and a check every second that notices once the switch is on. Then the
/// reading model: offered once, downloaded here with its progress, or found already installed.
@MainActor
final class Onboarding {
    static let shared = Onboarding()
    private var window: NSWindow?
    private var timer: Timer?
    private var closeObserver: NSObjectProtocol?

    func showIfNeeded() {
        if !AXIsProcessTrusted() { show(); return }
        guard OnboardingModel.modelNotAsked else { return }
        // Someone with Qwen in Ollama already has what the download would give them.
        Task { if await !LocalModel.isAvailable() { show() } }
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
            }
        }
        // Removed on close, or it (and the model it holds) would outlive every window.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in
                model.commitOpenAtLogin(); self?.timer?.invalidate(); self?.timer = nil; self?.window = nil
                if let o = self?.closeObserver { NotificationCenter.default.removeObserver(o); self?.closeObserver = nil }
            }
        }
    }

    func close() { window?.close() }

    static func openAccessibilitySettings() {
        // The prompt also adds the app to the Accessibility list, so the user only flips a switch.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Outside Applications the app can be run from a read-only, translocated copy (no updates),
    /// and it's easy to lose. The Accessibility grant follows the signing certificate, not the path.
    static var outsideApplications: Bool {
        let path = Bundle.main.bundlePath
        return !(path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
            && path.hasSuffix(".app")
    }

    /// Run from Downloads with the quarantine flag, macOS opens a copy from a temporary folder.
    static var translocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    @Published var download = ModelDownloader.shared.state
    /// Whether Qwen is already here, as the model file or in Ollama; nil while Ollama is asked.
    @Published var modelFound: Bool?
    @Published var spaceProblem = ModelDownloader.shared.spaceProblem()
    /// "About 4 minutes left", once the download has run long enough to tell.
    @Published var timeLeft: String?
    @Published var openAtLogin = LoginItem.isEnabled {
        didSet { if !rendering, !loginPending, openAtLogin != oldValue { LoginItem.set(openAtLogin) } }
    }
    /// The offered tick is only a suggestion until the reader moves on (download or close),
    /// so Later doesn't leave a login item they never agreed to.
    private var loginPending = false
    func commitOpenAtLogin() {
        guard loginPending else { return }
        loginPending = false
        LoginItem.set(openAtLogin)
    }
    private var rendering = false
    var foundInOllama = false
    private var rateStart: (at: Date, progress: Double)?

    /// A fixed state, for drawing the window with --render-onboarding.
    init(trusted: Bool, download: ModelDownloader.State, found: Bool?, ollama: Bool = false,
         spaceProblem: String? = nil, timeLeft: String? = nil) {
        self.trusted = trusted; self.download = download; modelFound = found; foundInOllama = ollama
        self.spaceProblem = spaceProblem; self.timeLeft = timeLeft
        rendering = true; openAtLogin = true
    }

    /// Ticked the first time the reader gets past Accessibility; after that it's theirs to change.
    func offerOpenAtLogin() {
        guard !rendering, LoginItem.available, !Onboarding.translocated,
              !UserDefaults.standard.bool(forKey: "onboarding.loginOffered") else { return }
        UserDefaults.standard.set(true, forKey: "onboarding.loginOffered")
        loginPending = true
        openAtLogin = true
    }

    init() {
        ModelDownloader.shared.observe { [weak self] in
            guard let self else { return }
            download = ModelDownloader.shared.state
            if download == .done { modelFound = true }
            estimate()
        }
        checkModel()
    }

    func checkModel() {
        if EmbeddedModel.modelPath != nil || !LocalModel.enabled { modelFound = true; return }
        Task {
            modelFound = await LocalModel.isAvailable()
            foundInOllama = modelFound == true
        }
    }

    func startDownload() {
        spaceProblem = ModelDownloader.shared.spaceProblem()
        if spaceProblem == nil { ModelDownloader.shared.start() }
    }

    private func estimate() {
        guard case .downloading(let p) = download else { rateStart = nil; timeLeft = nil; return }
        guard let start = rateStart else { rateStart = (Date(), p); return }
        let elapsed = Date().timeIntervalSince(start.at)
        guard elapsed > 5, p > start.progress else { return }
        let seconds = (1 - p) * elapsed / (p - start.progress)
        if seconds < 60 { timeLeft = "Less than a minute left"; return }
        let f = DateComponentsFormatter()
        f.unitsStyle = .full; f.maximumUnitCount = 1; f.includesApproximationPhrase = true
        f.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        timeLeft = f.string(from: seconds).map { $0 + " left" }
    }

    /// The model step is offered once; after that, it's in the menu.
    static var modelNotAsked: Bool {
        LocalModel.enabled && EmbeddedModel.modelPath == nil && !ModelDownloader.shared.isRunning
            && !UserDefaults.standard.bool(forKey: "onboarding.modelAsked")
    }
    static func markModelAsked() { UserDefaults.standard.set(true, forKey: "onboarding.modelAsked") }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Highlight Chinese text anywhere, then click the eye or press\u{00A0}⌃⌥L.")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if model.trusted {
                Label("Accessibility is on.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Divider()
                ModelStep(model: model, done: done)
            } else {
                accessStep
            }
        }
        .padding(20)
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.2), value: model.trusted)
        .animation(.easeInOut(duration: 0.2), value: model.modelFound)
    }

    @ViewBuilder private var accessStep: some View {
        Text("Longyan Reader needs Accessibility access to read the text you highlight. Nothing leaves your Mac.")
            .fixedSize(horizontal: false, vertical: true)
        if Onboarding.outsideApplications {
            Label("Move Longyan Reader to your Applications folder first.", systemImage: "folder")
                .foregroundStyle(.secondary)
        }
        Text("Turn on Longyan Reader in Privacy & Security › Accessibility.")
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.secondary)
        HStack {
            Spacer()
            Button("Later", action: done).keyboardShortcut(.cancelAction)
            Button("Open System Settings") { Onboarding.openAccessibilitySettings() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The reading model: Download or Later, then progress, then ready. Lookups work throughout.
private struct ModelStep: View {
    @ObservedObject var model: OnboardingModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch (model.modelFound, model.download) {
            case (nil, _):
                ProgressView().controlSize(.small)
            case (true?, _):
                Label(model.foundInOllama ? "You're all set. Using the reading model from Ollama." : "You're all set.",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                buttons { Button("Done", action: done).keyboardShortcut(.defaultAction) }
            case (false?, .downloading(let p)):
                intro
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p)
                    Text(progressText(p)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
                buttons {
                    Button("Stop") { ModelDownloader.shared.cancel() }
                    Button("Close", action: done).keyboardShortcut(.defaultAction)
                }
            case (false?, .verifying):
                intro
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: 1)
                    Text("Checking download…").font(.callout).foregroundStyle(.secondary)
                }
                buttons { Button("Close", action: done).keyboardShortcut(.defaultAction) }
            case (false?, .failed(let why)):
                intro
                Label("Download failed: \(Self.plain(why)).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                choice("Try Again")
            case (false?, _):
                intro
                if let problem = model.spaceProblem {
                    Label("Not enough disk space. The download \(problem).", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                choice(model.spaceProblem == nil ? "Download" : "Try Again")
            }
        }
        .onAppear {
            if !CommandLine.arguments.contains("--render-onboarding") { OnboardingModel.markModelAsked() }
            model.offerOpenAtLogin()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Download the reading model").font(.headline)
            Text("Recommended. It picks the meaning each word has in its sentence and translates phrases. It's a 2.7 GB download and runs on your Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progressText(_ p: Double) -> String {
        let gb = String(format: "%.1f of %.1f GB", p * Double(ModelDownloader.size) / 1e9, Double(ModelDownloader.size) / 1e9)
        return [gb, model.timeLeft].compactMap { $0 }.joined(separator: " · ")
    }

    /// A system error inside a sentence: "The network connection was lost." → "the network connection was lost".
    private static func plain(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".") { s.removeLast() }
        return s.prefix(1).lowercased() + s.dropFirst()
    }

    private func choice(_ primary: String) -> some View {
        buttons {
            Button("Later", action: done).keyboardShortcut(.cancelAction)
            Button(primary) { model.commitOpenAtLogin(); model.startDownload() }.keyboardShortcut(.defaultAction)
        }
    }

    /// The step's buttons, with Open at Login beside them in every state.
    private func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack {
            // Run from Downloads, a login item would point at a temporary copy that goes away;
            // the window already asks them to move the app first.
            if (LoginItem.available && !Onboarding.translocated) || CommandLine.arguments.contains("--render-onboarding") {
                Toggle("Open at login", isOn: $model.openAtLogin).toggleStyle(.checkbox)
            }
            Spacer()
            content()
        }
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
        add("Meanings and translations come from the reading model (Qwen 3.5, Apache 2.0, run in the app with llama.cpp, MIT; or through Ollama), or Apple's on-device models. They can be wrong: check a meaning against the other ones listed. Sentence translations are machine translations.")
        add("\n\nNotes\n", font: bold)
        add("The notes were written by Claude and checked against the dictionary meanings they belong to. They can contain mistakes.")
        add("\n\nPrivacy\n", font: bold)
        add("Lookups are processed on this Mac. Your history (Lookup History in the menu, which exports flashcards) is kept on this Mac in ~/Library/Application Support/LongyanReader/History, readable only by your account. Keep History in the menu turns it off or clears it.")
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
