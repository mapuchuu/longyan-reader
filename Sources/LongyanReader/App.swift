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
    private(set) var dict: CEDict?
    let popup = PopupController()
    private let chip = SelectionChip()
    private var lookupTask: Task<Void, Never>?
    /// The most recent cards' state, for the usage simulation.
    private(set) var lastLookupState: LookupState?
    private(set) var lastPhraseState: PhraseState?
    private var phrasePrep: PhrasePrep?
    private var localModelReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Saved card widths now mean a zoom level; sizes saved by the box-resizing
        // version would open cards shrunk, so start those fresh once.
        let defaults = UserDefaults.standard
        applyAppearance()
        if defaults.integer(forKey: "cardSizeVersion") < 2 {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("card.") { defaults.removeObject(forKey: key) }
            defaults.set(2, forKey: "cardSizeVersion")
        }
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

        chip.onShow = { [weak self] selection in self?.prepare(selection) }
        chip.onClick = { [weak self] selection, chipFrame in
            Task { @MainActor in await self?.chipClicked(selection, chipFrame: chipFrame) }
        }
        chip.start()
        refresh()   // also checks whether the local model is running

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
            if arg == "simulate" {
                Task { @MainActor in
                    let report = await self.runUsageSimulation()
                    try? report.write(to: Log.directory.appendingPathComponent("simulation.txt"), atomically: true, encoding: .utf8)
                }
                return
            }
            if arg == "demo" {
                // Debug: open a word card mid-screen, log its sizing, then drag the corner.
                Task { @MainActor in
                    var lines: [String] = []
                    let screen = NSScreen.main?.visibleFrame ?? .zero
                    let anchor = NSRect(x: screen.midX - 180, y: screen.midY + 200, width: 60, height: 20)
                    let passage = Array("奶奶上个月走了，全家人都很难过。")
                    let selection = Selection(passage: passage, range: 5..<6, bounds: nil, source: .accessibility, appName: "Demo")
                    self.show(selection, near: anchor)
                    for (label, wait) in [("after 0.1 s", 0.1), ("after 0.3 s", 0.2), ("after 0.6 s", 0.3), ("after 1.0 s", 0.4), ("after 2.5 s (answer in)", 1.5)] {
                        try? await Task.sleep(for: .seconds(wait))
                        lines.append("\(label): " + self.popup.debugState)
                    }
                    let savedZoom = UserDefaults.standard.object(forKey: "card.word.width")
                    self.popup.debugDrag(dx: 120, dy: -150)
                    try? await Task.sleep(for: .seconds(0.3))
                    lines.append("after dragging corner +120, +150 down: " + self.popup.debugState)
                    lines.append("saved size: " + "\(UserDefaults.standard.double(forKey: "card.word.width")) x \(UserDefaults.standard.double(forKey: "card.word.height"))")
                    if let savedZoom { UserDefaults.standard.set(savedZoom, forKey: "card.word.width") }
                    else { UserDefaults.standard.removeObject(forKey: "card.word.width") }
                    self.popup.close()
                    try? lines.joined(separator: "\n").write(to: Log.directory.appendingPathComponent("ax-probe.txt"), atomically: true, encoding: .utf8)
                }
                return
            }
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
        menu.addItem(withTitle: "Sense chooser: " + (localModelReady ? "\(LocalModel.name) (local, via Ollama)"
                                                     : "Apple on-device model, " + SenseChooser.unavailableReason),
                     action: nil, keyEquivalent: "")
        let pickerMenu = NSMenu()
        for choice in LocalModel.choices {
            let item = pickerMenu.addItem(withTitle: choice.label, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = LocalModel.name == choice.id ? .on : .off
        }
        let pickerItem = menu.addItem(withTitle: "Sense Picker", action: nil, keyEquivalent: "")
        menu.setSubmenu(pickerMenu, for: pickerItem)

        let appearanceMenu = NSMenu()
        for (id, label) in [("system", "Match System"), ("light", "Light"), ("dark", "Dark")] {
            let item = appearanceMenu.addItem(withTitle: label, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = currentAppearance == id ? .on : .off
        }
        appearanceMenu.addItem(.separator())
        for (id, label) in [("classic", "Classic"), ("glass", "Liquid Glass")] {
            let item = appearanceMenu.addItem(withTitle: label, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = CardStyle.current.rawValue == id ? .on : .off
        }
        let appearanceItem = menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        menu.setSubmenu(appearanceMenu, for: appearanceItem)
        menu.addItem(withTitle: "Accessibility: " + (AXIsProcessTrusted() ? "allowed" : "not allowed"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Refresh Status", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Longyan Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleChip() { chip.isEnabled.toggle(); rebuildMenu() }
    // MARK: Appearance

    /// "system", "light" or "dark"; applies to the cards and the selection button.
    private var currentAppearance: String { UserDefaults.standard.string(forKey: "appearance") ?? "system" }

    /// Applied to the card and selection-button windows only, so the menu-bar icon keeps
    /// following the menu bar.
    func applyAppearance() {
        popup.setAppearance(CardAppearance.current)
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "cardStyle")
        popup.refreshStyle()
        rebuildMenu()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "appearance")
        applyAppearance()
        rebuildMenu()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        LocalModel.select(id)
        refresh()
    }
    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func refresh() {
        Task {
            localModelReady = await LocalModel.isAvailable()
            rebuildMenu()
        }
    }

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
        LocalModel.warmUp()
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
    func show(_ selection: Selection, near anchor: NSRect) {
        guard let dict else { hint("Dictionary still loading…", near: anchor); return }
        let note = selection.source == .clipboard ? "copied, no surrounding text" : nil
        if isSingleWord(selection, dict: dict) {
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
        lastLookupState = state
        popup.show(LookupView(state: state), kind: .word, near: anchor)
        var record: [String: Any] = ["event": "word", "word": context.word, "sentence": context.sentence,
                                     "app": appName ?? "", "senses": senses.count]
        lookupTask = Task {
            let started = Date()
            if modelReady {
                do {
                    let choice = try await SenseChooser.choose(for: context, senses: senses)
                    guard !Task.isCancelled else { return }
                    if state.userPicked { record["userPickedFirst"] = true }   // the reader's choice stands
                    withAnimation(.smooth(duration: 0.3)) { state.receive(choice) }
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
        // Usually started when the text was selected (see `prepare`); otherwise start now.
        let prep = phrasePrep.flatMap { $0.matches(selection) ? $0 : nil } ?? PhrasePrep(selection, dict: dict)
        phrasePrep = nil
        let state = PhraseState(selection: selection, dict: dict, sourceNote: sourceNote)
        state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
        lastPhraseState = state
        lookupTask = Task {
            let started = Date()
            // Open with every word already resolved, waiting a little if need be; past that
            // the card opens anyway and the unresolved rows show a placeholder until they're in.
            await prep.wait(upTo: 1.2)
            guard !Task.isCancelled else { return }
            state.translation = prep.translation
            state.translationError = prep.translationError
            if let picks = prep.picks { state.apply(picks) } else { state.resolving = true }
            popup.show(PhraseView(state: state), kind: .phrase, near: anchor)
            let waited = Int(Date().timeIntervalSince(started) * 1000)
            if !prep.done {
                await prep.wait(upTo: 60)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.3)) {
                    if state.translation == nil { state.translation = prep.translation }
                    state.translationError = state.translation == nil ? prep.translationError : nil
                    state.apply(prep.picks ?? [:])
                }
                await relayout()
            }
            Log.write(["event": "phrase", "text": selection.text, "words": state.tokens.map(\.text),
                       "translation": state.translation ?? "", "app": selection.appName ?? "",
                       "source": selection.source.rawValue, "resolved": state.choices.count,
                       "waitedMs": waited, "ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    /// Starts a phrase card's work for a fresh selection, before the reader clicks.
    func prepare(_ selection: Selection) {
        guard let dict, !isSingleWord(selection, dict: dict) else { return }
        if phrasePrep?.matches(selection) == true { return }
        phrasePrep?.cancel()
        phrasePrep = PhrasePrep(selection, dict: dict)
    }

    private func isSingleWord(_ selection: Selection, dict: CEDict) -> Bool {
        let text = selection.text
        return text.count == 1 || (text.allSatisfy(isCJK) && dict.contains(text))
    }

    /// Let SwiftUI lay out new content, then resize the popup around it.
    private func relayout() async {
        try? await Task.sleep(for: .milliseconds(30))
        popup.reposition()
    }

    /// A short message that closes itself, but only if it's still the card on screen:
    /// a lookup opened in the meantime stays open.
    func hint(_ text: String, near anchor: NSRect) {
        popup.show(HintView(text: text), kind: .hint, near: anchor)
        let generation = popup.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.popup.generation == generation, self.popup.kind == .hint else { return }
            self.popup.close()
        }
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
