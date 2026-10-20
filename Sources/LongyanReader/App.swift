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
    private let chip = SelectionChip()
    private var lookupTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let mark = Icons.mark(size: 18) { statusItem.button?.image = mark } else { statusItem.button?.title = "龙" }
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? CEDict.load()
            DispatchQueue.main.async { self.dict = loaded; self.rebuildMenu() }
        }

        // ⌃⌥L: look up the selection, or the word under the mouse when nothing is selected.
        hotKey = HotKey(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey, id: 1) { [weak self] in
            Task { @MainActor in self?.hotKeyPressed() }
        }

        chip.onClick = { [weak self] selection, chipFrame in
            Task { @MainActor in await self?.chipClicked(selection, chipFrame: chipFrame) }
        }
        chip.start()

        // Switch on Chromium's page accessibility as soon as a browser comes to the front.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                SelectionReader.prepare(app)
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication { SelectionReader.prepare(front) }

        // Debug: describe an app's accessibility structure (see Probe.swift).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.mapuchuu.longyanreader.probe"), object: nil, queue: .main
        ) { note in
            let arg = note.object as? String ?? ""
            var report: String
            if arg.hasSuffix("|read"), let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: String(arg.dropLast(5))).first {
                // Run the real selection reader against that app; log shape, not content.
                switch SelectionReader.readAccessibility(from: app) {
                case .selection(let s):
                    report = "selection: \(s.range.count) chars, passage \(s.passage.count) chars, bounds \(s.bounds.map { "\($0)" } ?? "none"), source \(s.source.rawValue)"
                case .nothingSelected: report = "nothing selected"
                case .unreadable: report = "unreadable"
                }
                report += "\ntrace: " + SelectionReader.trace.joined(separator: " | ")
            } else {
                report = Probe.run(bundleID: arg)
            }
            try? report.write(to: Log.directory.appendingPathComponent("ax-probe.txt"), atomically: true, encoding: .utf8)
        }

        // Ask for Accessibility once; the system shows its own prompt.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Highlight Chinese text, then click the eye or press ⌃⌥L", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let chipItem = menu.addItem(withTitle: "Show Button on Selection", action: #selector(toggleChip), keyEquivalent: "")
        chipItem.target = self
        chipItem.state = chip.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictionary: " + (dict.map { "\($0.entryCount) entries" } ?? "loading…"), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Sense chooser: " + SenseChooser.unavailableReason, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Accessibility: " + (AXIsProcessTrusted() ? "allowed" : "not allowed"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Status", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Longyan Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleChip() { chip.isEnabled.toggle(); rebuildMenu() }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func refresh() { rebuildMenu() }

    // MARK: Triggers

    static func appKitRect(_ cg: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }
    static func mouseInCGSpace() -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let p = NSEvent.mouseLocation
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
    private static var mouseBox: NSRect {
        let p = NSEvent.mouseLocation
        return NSRect(x: p.x - 20, y: p.y - 10, width: 40, height: 20)
    }

    private func hotKeyPressed() {
        chip.hide()
        if case .selection(let s) = SelectionReader.readAccessibility(), s.trimmed().hasChinese {
            show(s.trimmed(), near: s.bounds.map(Self.appKitRect) ?? Self.mouseBox)
            return
        }
        // Nothing readable is selected: the word under the cursor, else whatever copying finds.
        if let captured = TextCapture.at(Self.mouseInCGSpace()) {
            showWord(captured)
            return
        }
        Task {
            if let s = await SelectionReader.readByCopying()?.trimmed(), s.hasChinese {
                show(s, near: Self.mouseBox)
            } else {
                hint("Highlight some Chinese text first", near: Self.mouseBox)
                Log.write(["event": "miss", "trace": SelectionReader.trace + TextCapture.trace,
                           "frontApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
            }
        }
    }

    private func chipClicked(_ selection: Selection?, chipFrame: NSRect) async {
        var selection = selection
        if selection == nil { selection = await SelectionReader.readByCopying()?.trimmed() }
        guard let s = selection, s.hasChinese else {
            hint("No Chinese text in the selection", near: chipFrame)
            Log.write(["event": "miss", "trace": SelectionReader.trace,
                       "frontApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
            return
        }
        show(s, near: s.bounds.map(Self.appKitRect) ?? chipFrame)
    }

    // MARK: Lookup

    /// One dictionary word gets the word card; anything longer gets the phrase card.
    private func show(_ selection: Selection, near anchor: NSRect) {
        guard let dict else { hint("Dictionary still loading…", near: anchor); return }
        let note = selection.source == .clipboard ? "copied, no surrounding text" : nil
        let text = selection.text
        if text.count == 1 || (text.allSatisfy(isCJK) && dict.contains(text)) {
            let context = Segmenter.context(for: selection.range, in: selection.passage)
            showWord(context, sourceNote: note, appName: selection.appName, near: anchor)
        } else {
            showPhrase(selection, dict: dict, sourceNote: note, near: anchor)
        }
    }

    private func showWord(_ captured: CapturedText) {
        guard let dict, let context = Segmenter.word(at: captured.index, in: captured.passage, dict: dict) else { return }
        showWord(context, sourceNote: nil, appName: captured.appName, near: Self.mouseBox)
    }

    private func showWord(_ context: WordInContext, sourceNote: String?, appName: String?, near anchor: NSRect) {
        guard let dict else { return }
        lookupTask?.cancel()
        let senses = dict.senses(for: context.word)
        let modelReady = SenseChooser.isAvailable && !senses.isEmpty
        let state = LookupState(context: context, senses: senses, sourceNote: sourceNote, appName: appName,
                                phase: modelReady ? .choosing : .dictionaryOnly(senses.isEmpty ? "not in dictionary" : SenseChooser.unavailableReason))
        state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
        popup.show(LookupView(state: state), near: anchor)
        var record: [String: Any] = ["event": "word", "word": context.word, "sentence": context.sentence,
                                     "app": appName ?? "", "senses": senses.count]
        lookupTask = Task {
            let started = Date()
            if modelReady {
                do {
                    let choice = try await SenseChooser.choose(for: context, senses: senses)
                    guard !Task.isCancelled else { return }
                    state.choice = choice
                    state.phase = .chosen
                    record["meaningHere"] = choice.meaningHere
                    record["tag"] = choice.tag.rawValue
                } catch {
                    state.phase = .failed(String(describing: error).prefix(80).description)
                    record["error"] = String(describing: error)
                }
                record["ms"] = Int(Date().timeIntervalSince(started) * 1000)
                await relayout()
            }
            Log.write(record)
        }
    }

    private func showPhrase(_ selection: Selection, dict: CEDict, sourceNote: String?, near anchor: NSRect) {
        lookupTask?.cancel()
        let state = PhraseState(selection: selection, dict: dict, sourceNote: sourceNote)
        state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
        popup.show(PhraseView(state: state), near: anchor)
        lookupTask = Task {
            let started = Date()
            do { state.translation = try await Translator.translate(selection.text) }
            catch { state.translationError = String(describing: error).prefix(60).description }
            await relayout()
            Log.write(["event": "phrase", "text": selection.text, "words": state.tokens.map(\.text),
                       "translation": state.translation ?? "", "app": selection.appName ?? "",
                       "source": selection.source.rawValue, "ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    /// Let SwiftUI lay out new content, then resize the popup around it.
    private func relayout() async {
        try? await Task.sleep(for: .milliseconds(30))
        popup.reposition()
    }

    private func hint(_ text: String, near anchor: NSRect) {
        popup.show(HintView(text: text), near: anchor)
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
