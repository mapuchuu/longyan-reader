import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1].hasPrefix("--") {
            CLI.run(args)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var dict: CEDict?
    private let popup = PopupController()
    private var lookupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "龍"
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? CEDict.load()
            DispatchQueue.main.async { self.dict = loaded; self.rebuildMenu() }
        }

        // ⌃⌥L: look up the word under the mouse.
        hotKey = HotKey(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, id: 1) { [weak self] in
            Task { @MainActor in self?.lookUpAtMouse() }
        }

        // Debug trigger: look up at a given point without the keyboard.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.mapuchuu.longyanreader.lookup"), object: nil, queue: .main
        ) { [weak self] note in
            let x = (note.object as? String).flatMap { s -> CGPoint? in
                let parts = s.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
            }
            Task { @MainActor in self?.lookUp(at: x ?? Self.mouseInCGSpace(), mouse: x.map(Self.cgToAppKit) ?? NSEvent.mouseLocation) }
        }

        // Ask for Accessibility once; the system shows its own prompt.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Look up word under cursor   ⌃⌥L", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictionary: " + (dict.map { "\($0.entryCount) entries" } ?? "loading…"), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Sense chooser: " + SenseChooser.unavailableReason, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Accessibility: " + (AXIsProcessTrusted() ? "allowed" : "not allowed"), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Screen reading (OCR): " + (CGPreflightScreenCaptureAccess() ? "allowed" : "not allowed"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Allow Screen Reading…", action: #selector(requestScreen), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Status", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Longyan Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func requestScreen() { _ = CGRequestScreenCaptureAccess(); rebuildMenu() }
    @objc private func refresh() { rebuildMenu() }

    // MARK: Lookup

    static func mouseInCGSpace() -> CGPoint { appKitToCG(NSEvent.mouseLocation) }

    static func appKitToCG(_ p: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
    static func cgToAppKit(_ p: CGPoint) -> NSPoint { appKitToCG(p) }   // the flip is its own inverse

    private func lookUpAtMouse() { lookUp(at: Self.mouseInCGSpace(), mouse: NSEvent.mouseLocation) }

    private func lookUp(at point: CGPoint, mouse: NSPoint) {
        lookupTask?.cancel()
        popup.close()
        guard let dict else { hint("Dictionary still loading…", at: mouse); return }
        lookupTask = Task {
            let started = Date()
            guard let captured = await TextCapture.at(point) else {
                let why = !AXIsProcessTrusted() && !CGPreflightScreenCaptureAccess()
                    ? "Allow Accessibility or Screen Reading in the 龍 menu"
                    : "No Chinese text under the cursor"
                hint(why, at: mouse)
                Log.write(["event": "miss", "x": point.x, "y": point.y, "reason": why])
                return
            }
            guard !Task.isCancelled,
                  let context = Segmenter.word(at: captured.index, in: captured.passage, dict: dict) else { return }
            let senses = dict.senses(for: context.word)
            let modelReady = SenseChooser.isAvailable && senses.count > 0
            let state = LookupState(context: context, senses: senses, source: captured.source, appName: captured.appName,
                                    phase: modelReady ? .choosing : .dictionaryOnly(senses.isEmpty ? "not in dictionary" : SenseChooser.unavailableReason))
            popup.show(LookupView(state: state), at: mouse)

            var record: [String: Any] = [
                "event": "lookup", "word": context.word, "sentence": context.sentence, "source": captured.source.rawValue,
                "app": captured.appName ?? "", "senses": senses.count, "captureMs": Int(Date().timeIntervalSince(started) * 1000),
            ]
            if modelReady {
                do {
                    let choice = try await SenseChooser.choose(for: context, senses: senses)
                    guard !Task.isCancelled else { return }
                    state.choice = choice
                    state.phase = .chosen
                    record["chosen"] = choice.senseNumber
                    record["meaningHere"] = choice.meaningHere
                    record["tag"] = choice.tag.rawValue
                    record["note"] = choice.note
                } catch {
                    state.phase = .failed(String(describing: error).prefix(80).description)
                    record["error"] = String(describing: error)
                }
                record["totalMs"] = Int(Date().timeIntervalSince(started) * 1000)
                try? await Task.sleep(for: .milliseconds(30))   // let SwiftUI lay out the new content
                popup.reposition()
            }
            Log.write(record)
            popup.snapshot(to: Log.directory.appendingPathComponent("last-popup.png"))
        }
    }

    private func hint(_ text: String, at mouse: NSPoint) {
        popup.show(HintView(text: text), at: mouse)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in self?.popup.close() }
    }
}

enum Log {
    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LongyanReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func write(_ record: [String: Any]) {
        var r = record
        r["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return }
        let url = directory.appendingPathComponent("lookups.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); h.write("\n".data(using: .utf8)!); try? h.close()
        } else {
            try? (String(data: data, encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
