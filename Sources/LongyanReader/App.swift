import AppKit
import ApplicationServices
import Carbon.HIToolbox
import LongyanCore
import SwiftUI

@main
enum Main {
    static func main() {
        AppleServices.install()
        let args = CommandLine.arguments
        if args.count > 1, args[1].hasPrefix("--") {
            CLI.run(args)
            return
        }
        // One copy at a time: a second (say, one opened from Downloads while the Applications
        // copy runs) would add a second eye and menu, and two writers can lose history lines.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != getpid() }) {
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = editingMenu()
        app.run()
    }

    /// Menu-bar apps have no menu bar of their own, but text fields and windows still take their
    /// shortcuts from the main menu: without it ⌘V in History's search and ⌘W do nothing.
    @MainActor
    private static func editingMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Longyan Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private(set) var dict: CEDict?
    let popup = PopupController()
    /// Hints shown while a pinned card is open, so they don't replace it.
    private lazy var hintPopup: PopupController = {
        let c = PopupController()
        c.followsPin = false
        return c
    }()
    private let chip = SelectionChip()
    private var lookupTask: Task<Void, Never>?
    /// The most recent cards' state, for the usage simulation.
    private(set) var lastLookupState: LookupState?
    private(set) var lastPhraseState: PhraseState?
    private var phrasePrep: PhrasePrep?
    private var wordPrep: (key: String, task: Task<SenseChoice, Error>)?
    /// The open card's model work. Ollama answers one request at a time, so work left over
    /// from a card that's gone would hold up the next one: a new card cancels it all.
    private var cardTasks: [Task<SenseChoice, Error>] = []
    private var shownPhrasePrep: PhrasePrep?

    private func cancelCardWork(keeping kept: Task<SenseChoice, Error>? = nil) {
        lookupTask?.cancel()
        for t in cardTasks where t != kept { t.cancel() }
        cardTasks = []
        shownPhrasePrep?.cancel()
        shownPhrasePrep = nil
    }

    /// Longer selections get a hint instead of a card (the selection button doesn't appear for
    /// them either): a card for a page of text would take minutes of model time.
    static let maxSelection = 400
    private var localModelReady = false

    // A quit during the model's first load would otherwise exit under it (see `shutdown`).
    func applicationWillTerminate(_ notification: Notification) {
        EmbeddedModel.shared.shutdown()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessibility calls wait up to about 6 s by default for an app that doesn't answer, and
        // they run on the main thread: the default for every element, not just each app's own.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        // Saved card widths now mean a zoom level; sizes saved by the box-resizing
        // version would open cards shrunk, so start those fresh once.
        let defaults = UserDefaults.standard
        Log.migrate()
        Log.trim()
        applyAppearance()
        if defaults.integer(forKey: "cardSizeVersion") < 2 {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("card.") { defaults.removeObject(forKey: key) }
            defaults.set(2, forKey: "cardSizeVersion")
        }
        Updates.start()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let mark = Icons.mark(size: 18) { statusItem.button?.image = mark } else { statusItem.button?.title = "龙" }
        rebuildMenu()

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = try? CEDict.load()
            DispatchQueue.main.async { self.dict = loaded }
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

        // Switch on Chromium's and iWork's document accessibility as soon as the app comes to
        // the front, and again a moment later for an app that was still starting up.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                SelectionReader.prepare(app)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if app.isActive, !app.isTerminated { SelectionReader.prepare(app) }
                }
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication { SelectionReader.prepare(front) }

        #if DEV_TOOLS
        // Debug (dev builds only: scripts/build-app.sh --dev): describe an app's accessibility
        // structure (see Probe.swift), or run the usage simulation. Any local process can post
        // this notification, and the probe acts with this app's Accessibility permission, so
        // it isn't compiled into the builds people download.
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
            if arg == "onboarding" { Onboarding.shared.show(); return }
            if arg == "about" { About.show(); return }
            if arg == "history" { self.showHistory(); return }
            if arg.hasPrefix("showlow:") {
                // Debug: open a card near the bottom of the screen, so it opens above. showlow:<passage>|<from>|<to>
                let f = arg.dropFirst(8).split(separator: "|").map(String.init)
                guard f.count == 3, let lo = Int(f[1]), let hi = Int(f[2]) else { return }
                let screen = NSScreen.main?.visibleFrame ?? .zero
                let anchor = NSRect(x: screen.midX - 200, y: screen.minY + 70, width: 60, height: 20)
                self.show(Selection(passage: Array(f[0]), range: lo..<hi, bounds: nil, source: .accessibility, appName: "Demo"), near: anchor)
                return
            }
            if arg == "press" { self.popup.hangFromTop(); return }
            if arg == "holdopen" { self.popup.ignoresOutsideInput = true; return }
            if arg == "letgo" { self.popup.ignoresOutsideInput = false; return }
            if arg.hasPrefix("tracegrow:") {
                // Debug: open (or close) a phrase row and log the window and card every frame for 0.8 s.
                let word = String(arg.dropFirst(10))
                guard let state = self.lastPhraseState, let token = state.tokens.first(where: { $0.text == word }) else { return }
                var lines: [String] = []
                @MainActor func snap(_ t: Double) {
                    let f = self.popup.windowFrame ?? .zero, l = self.popup.currentLayout
                    lines.append(String(format: "%5.3f window y %.1f…%.1f h %.1f  below %@/%@  layout.height %.1f content %.1f max %.1f",
                                        t, f.minY, f.maxY, f.height, self.popup.isPlacedBelow ? "Y" : "N", (l?.placedBelow ?? false) ? "Y" : "N",
                                        l?.height ?? 0, l?.contentHeight ?? 0, l?.maxHeight ?? 0))
                }
                snap(0)
                withAnimation(cardMotion) { state.toggle(token) }
                let start = Date()
                Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
                    MainActor.assumeIsolated {
                        let t = Date().timeIntervalSince(start)
                        snap(t)
                        if t > 0.8 {
                            timer.invalidate()
                            try? lines.joined(separator: "\n").write(to: Log.directory.appendingPathComponent("grow-trace.txt"), atomically: true, encoding: .utf8)
                        }
                    }
                }
                return
            }
            if arg == "partof" { self.lastLookupState?.openPartOf(); return }
            if arg.hasPrefix("capture:") {
                // Debug: the word-under-pointer capture at a screen point (CG space). capture:<x>,<y>
                let f = arg.dropFirst(8).split(separator: ",").compactMap { Double($0) }
                guard f.count == 2 else { return }
                let started = Date()
                if TextCapture.at(CGPoint(x: f[0], y: f[1])) == nil, let cell = TextCapture.cell(at: CGPoint(x: f[0], y: f[1])) {
                    try? ("cell: \(cell.text.count) chars, frame \(cell.frame), app \(cell.appName ?? "?")\ntrace: " + TextCapture.trace.joined(separator: " | "))
                        .write(to: Log.directory.appendingPathComponent("ax-probe.txt"), atomically: true, encoding: .utf8)
                    return
                }
                let c = TextCapture.at(CGPoint(x: f[0], y: f[1]))
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let word = c.flatMap { c in self.dict.flatMap { Segmenter.word(at: c.index, in: c.passage, dict: $0)?.word } }
                let out = c.map { "index \($0.index) of \($0.passage.count), word \(word ?? "-"), \(ms) ms" } ?? "nothing, \(ms) ms"
                try? (out + "\ntrace: " + TextCapture.trace.joined(separator: " | "))
                    .write(to: Log.directory.appendingPathComponent("ax-probe.txt"), atomically: true, encoding: .utf8)
                return
            }
            if arg.hasPrefix("show:") {
                // Debug: open a card mid-screen and leave it open. show:<passage>|<from>|<to>
                let f = arg.dropFirst(5).split(separator: "|").map(String.init)
                guard f.count == 3, let lo = Int(f[1]), let hi = Int(f[2]) else { return }
                let screen = NSScreen.main?.visibleFrame ?? .zero
                let anchor = NSRect(x: screen.midX - 200, y: screen.midY + 260, width: 60, height: 20)
                self.show(Selection(passage: Array(f[0]), range: lo..<hi, bounds: nil, source: .accessibility, appName: "Demo"), near: anchor)
                return
            }
            if arg.hasPrefix("expand:") {
                // Debug: open (or close) a phrase card's row. expand:<word>
                let word = String(arg.dropFirst(7))
                if let state = self.lastPhraseState, let token = state.tokens.first(where: { $0.text == word }) {
                    withAnimation(cardMotion) { state.toggle(token) }
                }
                return
            }
            if arg.hasPrefix("zoomdrag:") {
                // Debug: resize the card from edges over a second. zoomdrag:<right|left|top|bottom, joined by +>|<points outward>
                let f = arg.dropFirst(9).split(separator: "|").map(String.init)
                let names: [String: CardLayout.Edges] = ["right": .right, "left": .left, "top": .top, "bottom": .bottom]
                let edges = (f.first ?? "").split(separator: "+").reduce(into: CardLayout.Edges()) { $0.formUnion(names[String($1)] ?? []) }
                self.popup.debugEdgeDrag(edges.isEmpty ? [.bottom, .right] : edges, by: CGFloat(Double(f.last ?? "") ?? 80))
                return
            }
            if arg.hasPrefix("scroll:") {
                // Debug: scroll the card's content. scroll:<points>
                self.popup.debugScroll(to: CGFloat(Double(arg.dropFirst(7)) ?? 0))
                return
            }
            if arg.hasPrefix("pick:") {
                // Debug: pick a word card's meaning by index. pick:<n>
                if let n = Int(arg.dropFirst(5)), let state = self.lastLookupState { withAnimation(cardMotion) { state.pick(n) } }
                return
            }
            if arg == "demo" {
                // Debug: open a word card mid-screen, log its sizing, then drag the corner.
                Task { @MainActor in
                    var lines: [String] = []
                    let screen = NSScreen.main?.visibleFrame ?? .zero
                    let anchor = NSRect(x: screen.midX - 180, y: screen.midY + 200, width: 60, height: 20)
                    let passage = Array("最近工作太卷了，我想躺平。")
                    let selection = Selection(passage: passage, range: 5..<6, bounds: nil, source: .accessibility, appName: "Demo")
                    self.show(selection, near: anchor)
                    for (label, wait) in [("after 0.1 s", 0.1), ("after 0.3 s", 0.2), ("after 0.6 s", 0.3), ("after 1.0 s", 0.4), ("after 2.5 s (answer in)", 1.5)] {
                        try? await Task.sleep(for: .seconds(wait))
                        lines.append("\(label): " + self.popup.debugState)
                    }
                    let savedZoom = UserDefaults.standard.object(forKey: CardLayout.zoomKey)
                    self.popup.debugDrag(dx: 120, dy: -150)
                    try? await Task.sleep(for: .seconds(0.3))
                    lines.append("after dragging corner +120, +150 down: " + self.popup.debugState)
                    lines.append("saved zoom: \(UserDefaults.standard.double(forKey: CardLayout.zoomKey))")
                    if let savedZoom { UserDefaults.standard.set(savedZoom, forKey: CardLayout.zoomKey) }
                    else { UserDefaults.standard.removeObject(forKey: CardLayout.zoomKey) }
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
        #endif

        // Without Accessibility nothing works, so explain it before the system prompt appears.
        // Then it offers the model download. The menu shows its progress when opened.
        ModelDownloader.shared.observe { [weak self] in
            // Downloading is choosing it, even after picking Apple's model earlier.
            if ModelDownloader.shared.state == .done { LocalModel.select(LocalModel.choices[0].id); self?.refresh() }
        }
        AnkiLink.shared.check()
        // A new tone colour scheme, or a custom colour picked, shows on the open card at once.
        NotificationCenter.default.addObserver(forName: ToneColors.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.popup.refreshStyle() }
        }
        // Outside Applications it can't update; moving relaunches it, so onboarding waits.
        if AppMover.offerAtLaunch() { return }
        Onboarding.shared.showIfNeeded()
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt in place each time the menu opens, so History, Accessibility and the
    /// model's line are current (the first lookup creates the history file, for one).
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        // Anki's answer arrives after the menu opens: if it changed (Anki just opened, a new
        // deck), the open menu is filled again so Anki Deck is right.
        AnkiLink.shared.check { [weak self, weak menu] in
            guard let self, let menu, menu === self.statusItem.menu else { return }
            self.refill(menu)
        }
        refill(menu)
    }

    private func refill(_ menu: NSMenu) {
        let fresh = makeMenu()
        menu.removeAllItems()
        for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Highlight Chinese text, then click the eye or press ⌃⌥L", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let chipItem = menu.addItem(withTitle: "Show Eye When You Highlight Text", action: #selector(toggleChip), keyEquivalent: "")
        chipItem.target = self
        chipItem.state = chip.isEnabled ? .on : .off
        // Apps the eye was hidden in from its right-click menu; unticking one shows it there again.
        let hidden = chip.hiddenApps
        if chip.isEnabled, !hidden.isEmpty {
            let hiddenMenu = NSMenu()
            for id in hidden {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
                let item = hiddenMenu.addItem(withTitle: name, action: #selector(showEyeAgain(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = id; item.state = .on
            }
            menu.setSubmenu(hiddenMenu, for: menu.addItem(withTitle: "Hide Eye In", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictionary: " + (dict.map { "\($0.entryCount.formatted()) entries" } ?? "loading…"), action: nil, keyEquivalent: "")
        let localLabel = LocalModel.backend == .embedded ? "Qwen 3.5 4B" : "Qwen 3.5 4B from Ollama"
        menu.addItem(withTitle: "Reading model: " + (localModelReady ? localLabel
                                                     : LocalModel.enabled ? "not downloaded (Apple's model: \(SenseChooser.unavailableReason))"
                                                     : "Apple's model (\(SenseChooser.unavailableReason))"),
                     action: nil, keyEquivalent: "")
        // The model file isn't bundled (2.7 GB); offer it until it's here.
        let downloader = ModelDownloader.shared
        switch downloader.state {
        case .downloading(let p):
            menu.addItem(withTitle: String(format: "Downloading Reading Model… %.0f%%", p * 100), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Stop Download",
                         action: #selector(cancelModelDownload), keyEquivalent: "").target = self
        case .verifying:
            menu.addItem(withTitle: "Checking Download…", action: nil, keyEquivalent: "")
        case .failed(let why) where EmbeddedModel.modelPath == nil || EmbeddedModel.fileUnloadable:
            menu.addItem(withTitle: "Download failed: \(why)", action: nil, keyEquivalent: "")
            menu.addItem(withTitle: "Retry Download", action: #selector(downloadModel), keyEquivalent: "").target = self
        default:
            if EmbeddedModel.fileUnloadable {
                // The file is there but won't load: offer a fresh copy (it replaces the file).
                menu.addItem(withTitle: "The reading model won't open", action: nil, keyEquivalent: "")
                menu.addItem(withTitle: "Download It Again (2.7 GB)…", action: #selector(downloadModel), keyEquivalent: "").target = self
            } else if EmbeddedModel.modelPath == nil {
                menu.addItem(withTitle: "Download Reading Model (2.7 GB)…", action: #selector(downloadModel), keyEquivalent: "").target = self
            }
        }
        let pickerMenu = NSMenu()
        for choice in LocalModel.choices {
            let item = pickerMenu.addItem(withTitle: choice.label, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = LocalModel.name == choice.id ? .on : .off
        }
        let pickerItem = menu.addItem(withTitle: "Reading Model", action: nil, keyEquivalent: "")
        menu.setSubmenu(pickerMenu, for: pickerItem)

        let appearanceMenu = NSMenu()
        for (id, label) in [("system", "Match System"), ("light", "Light"), ("dark", "Dark")] {
            let item = appearanceMenu.addItem(withTitle: label, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = currentAppearance == id ? .on : .off
        }
        appearanceMenu.addItem(.separator())
        for (id, label) in [("classic", "Classic"), ("glass", "Liquid Glass")] where id == "classic" || CardStyle.isGlassAvailable {
            let item = appearanceMenu.addItem(withTitle: label, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = CardStyle.current.rawValue == id ? .on : .off
        }
        appearanceMenu.addItem(.separator())
        // Each scheme by name with its four colours beside it (Off: four empty rings). Picking
        // a scheme and editing the custom colours are separate items, as in Finder's View menu.
        let toneMenu = NSMenu()
        for scheme in ToneScheme.allCases {
            if scheme == .off { toneMenu.addItem(.separator()) }
            let item = toneMenu.addItem(withTitle: scheme.label, action: #selector(selectToneScheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scheme.rawValue
            item.image = ToneColors.swatch(scheme)
            item.toolTip = scheme.colorNames
            item.state = ToneColors.scheme == scheme ? .on : .off
        }
        toneMenu.addItem(.separator())
        let edit = toneMenu.addItem(withTitle: "Edit Custom Colors…", action: #selector(editToneColors), keyEquivalent: "")
        edit.target = self
        edit.image = NSImage(size: ToneColors.swatch(.off).size)   // blank, so the titles line up
        appearanceMenu.setSubmenu(toneMenu, for: appearanceMenu.addItem(withTitle: "Tone Colors", action: nil, keyEquivalent: ""))
        appearanceMenu.addItem(.separator())
        for (title, key, steps) in [("Bigger Text", "+", 1), ("Smaller Text", "-", -1), ("Actual Size", "0", 0)] {
            let item = appearanceMenu.addItem(withTitle: title, action: #selector(changeTextSize(_:)), keyEquivalent: key)
            item.target = self
            item.tag = steps
        }
        let appearanceItem = menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "")
        menu.setSubmenu(appearanceMenu, for: appearanceItem)
        menu.addItem(withTitle: "Lookup History", action: #selector(showHistory), keyEquivalent: "y").target = self
        let historyMenu = NSMenu()
        for (keep, label) in [(Log.Keep.off, "Off"), (.days30, "Keep 30 Days"), (.all, "Keep Everything")] {
            let item = historyMenu.addItem(withTitle: label, action: #selector(selectHistory(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = keep.rawValue; item.state = Log.keep == keep ? .on : .off
        }
        historyMenu.addItem(.separator())
        let hasHistory = FileManager.default.fileExists(atPath: Log.file.path)
        let reveal = historyMenu.addItem(withTitle: "Show in Finder", action: hasHistory ? #selector(revealHistory) : nil, keyEquivalent: "")
        reveal.target = self
        let clear = historyMenu.addItem(withTitle: "Clear History…", action: hasHistory ? #selector(clearHistory) : nil, keyEquivalent: "")
        clear.target = self
        let historyItem = menu.addItem(withTitle: "Keep History", action: nil, keyEquivalent: "")
        menu.setSubmenu(historyMenu, for: historyItem)
        // Where Add to Anki puts cards; only while Anki is open with AnkiConnect.
        let anki = AnkiLink.shared
        if anki.available {
            let deckMenu = NSMenu()
            let current = AnkiLink.deck
            // The chosen deck stays listed (checked) even if it was renamed or deleted in Anki:
            // the next card makes it again, so the menu says where cards go.
            let others = Set(anki.decks + [current]).subtracting([AnkiLink.defaultDeck]).sorted()
            for deck in [AnkiLink.defaultDeck] + others {
                let item = deckMenu.addItem(withTitle: deck, action: #selector(selectAnkiDeck(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = deck; item.state = deck == current ? .on : .off
                if deck == AnkiLink.defaultDeck { deckMenu.addItem(.separator()) }
            }
            if deckMenu.items.last?.isSeparatorItem == true { deckMenu.removeItem(at: deckMenu.items.count - 1) }
            menu.setSubmenu(deckMenu, for: menu.addItem(withTitle: "Anki Deck", action: nil, keyEquivalent: ""))
        }
        menu.addItem(withTitle: "Accessibility: " + (AXIsProcessTrusted() ? "on" : "off"), action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check Accessibility Again", action: #selector(refresh), keyEquivalent: "").target = self
        menu.addItem(.separator())
        // Opened straight from Downloads, macOS runs a read-only copy from a temporary folder:
        // it can't update itself, and a login item would point at a path that goes away.
        let translocated = Onboarding.translocated
        if Updates.available && Onboarding.outsideApplications {
            menu.addItem(withTitle: "Move to Applications to Get Updates…", action: #selector(moveToApplications), keyEquivalent: "").target = self
        }
        if LoginItem.available {
            let login = menu.addItem(withTitle: "Open at Login", action: translocated ? nil : #selector(toggleOpenAtLogin), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
        }
        if Updates.available {
            menu.addItem(withTitle: "Check for Updates…", action: translocated ? nil : #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Report a Problem", action: #selector(reportIssue), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About Longyan Reader", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Longyan Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func toggleChip() { chip.isEnabled.toggle() }
    @objc private func showEyeAgain(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        chip.hiddenApps.removeAll { $0 == id }
    }
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
    }

    /// Bigger, Smaller or Actual Size: the open card follows at once; with none open, the
    /// next one opens at the new size. Pinching a card does the same.
    @objc private func changeTextSize(_ sender: NSMenuItem) {
        let open = popup.currentLayout.flatMap { $0.kind == .hint ? nil : $0 }
        // Each kind keeps its own width and height; changing either one's zoom rescales both.
        let layout = open ?? CardLayout(kind: .word)
        if sender.tag == 0 { layout.resetSize(zoomToo: true) } else { layout.stepZoom(sender.tag) }
        if open == nil || sender.tag == 0 {
            // Actual Size resets the other kind's size too.
            let other = CardLayout(kind: layout.kind == .word ? .phrase : .word)
            if sender.tag == 0 { other.resetSize(zoomToo: true) }
        }
    }

    @objc private func toggleOpenAtLogin() {
        LoginItem.set(!LoginItem.isEnabled)
    }

    @objc private func selectAnkiDeck(_ sender: NSMenuItem) {
        guard let deck = sender.representedObject as? String else { return }
        AnkiLink.deck = deck
    }

    @objc private func selectToneScheme(_ sender: NSMenuItem) {
        guard let scheme = (sender.representedObject as? String).flatMap(ToneScheme.init) else { return }
        ToneColors.scheme = scheme
    }

    /// Opens the Tone Colors window, and uses the custom colours while it's open.
    @objc private func editToneColors() {
        ToneColors.scheme = .custom
        ToneColorsWindow.shared.show()
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        UserDefaults.standard.set(id, forKey: "appearance")
        applyAppearance()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        LocalModel.select(id)
        refresh()
    }
    @objc private func openAccessibility() {
        if AXIsProcessTrusted() { Onboarding.openAccessibilitySettings() } else { Onboarding.shared.show() }
    }
    @objc private func showAbout() { About.show() }
    @objc private func checkForUpdates() { Updates.checkNow() }
    @objc private func moveToApplications() { AppMover.offer() }
    /// A new GitHub issue with the app, macOS and model versions filled in (nothing else: no
    /// lookups, no file paths), opened in the browser for the reader to write and send.
    @objc private func reportIssue() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var chip = [CChar](repeating: 0, count: 128), size = chip.count
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        let model = LocalModel.enabled ? (LocalModel.backend == .embedded ? "Qwen 3.5 4B (built in)" : "Ollama") : "Apple"
        let body = """
        **What happened**


        **What you expected**


        **Which app the text was in** (for example Safari, Preview, WeChat)


        **Steps or text to reproduce** (a sentence and the word you looked up help most)


        ---
        Longyan Reader \(version) (\(build)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(String(cString: chip)), \(Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())) GB, reading model: \(model)
        """
        var url = URLComponents(string: "https://github.com/mapuchuu/longyan-reader/issues/new")!
        url.queryItems = [URLQueryItem(name: "body", value: body)]
        if let u = url.url { NSWorkspace.shared.open(u) }
    }
    @objc private func downloadModel() {
        if let problem = ModelDownloader.shared.spaceProblem() {
            let alert = NSAlert()
            alert.messageText = "Not enough disk space"
            alert.informativeText = "The download \(problem). Free up some space and try again."
            NSApp.activate()
            alert.runModal()
            return
        }
        if case .failed = ModelDownloader.shared.state {} else {
            let alert = NSAlert()
            alert.messageText = "Download the reading model?"
            alert.informativeText = "It picks the meaning each word has in its sentence and translates phrases. It's a 2.7 GB download and runs on your Mac."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        ModelDownloader.shared.start()
    }
    @objc private func cancelModelDownload() { ModelDownloader.shared.cancel() }
    @objc private func selectHistory(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let keep = Log.Keep(rawValue: raw) else { return }
        Log.keep = keep
        HistoryWindow.shared.reloadIfOpen()
    }
    @objc private func showHistory() {
        Log.trim()   // "30 days" holds on a Mac that runs for weeks without a relaunch
        HistoryWindow.shared.show(dict: { [weak self] in self?.dict })
    }
    @objc private func revealHistory() { NSWorkspace.shared.activateFileViewerSelecting([Log.file]) }
    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear lookup history?"
        alert.informativeText = "The history file moves to the Trash, where you can still restore it."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Log.clear()
        HistoryWindow.shared.reloadIfOpen()
    }
    @objc private func refresh() {
        Task {
            localModelReady = await LocalModel.isAvailable()
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
        // Without Accessibility nothing can be read (and the ⌘C fallback is dropped too):
        // say so, instead of "highlight some Chinese text" when they already have.
        guard AXIsProcessTrusted() else { Onboarding.shared.show(); return }
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
        if let cell = TextCapture.cell(at: Self.mouseInCGSpace()) {
            let passage = Array(cell.text)
            let s = Selection(passage: passage, range: 0..<passage.count, bounds: cell.frame.width > 0 ? cell.frame : nil,
                              source: .accessibility, appName: cell.appName).trimmed()
            show(s, near: s.bounds.map(Self.appKitRect) ?? Self.mouseBox)
            return
        }
        Task {
            if let s = await SelectionReader.readByCopying()?.trimmed(), s.hasChinese {
                show(s, near: Self.mouseBox)
            } else {
                hint("Highlight Chinese text, or point at a word and press ⌃⌥L", near: Self.mouseBox)
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
        guard selection.range.count <= Self.maxSelection else {
            hint("That's a lot of text: select a sentence or two", near: anchor)
            return
        }
        let selection = selection.wholeWords(dict: dict)
        if selection.isOneWord(dict: dict) {
            let context = Segmenter.context(for: selection.range, in: selection.passage)
            showWord(context, appName: selection.appName, near: anchor, alone: selection.isAlone)
        } else {
            showPhrase(selection, dict: dict, near: anchor)
        }
    }

    private func showWord(_ captured: CapturedText) {
        guard let dict else { hint("Dictionary still loading…", near: Self.mouseBox); return }
        guard let context = Segmenter.word(at: captured.index, in: captured.passage, dict: dict) else {
            hint("Highlight Chinese text, or point at a word and press ⌃⌥L", near: Self.mouseBox)
            return
        }
        showWord(context, appName: captured.appName, near: Self.mouseBox)
    }

    private func showWord(_ context: WordInContext, appName: String?, near anchor: NSRect, alone: Bool = false) {
        guard let dict else { return }
        let opening = LookupState.opening(context, dict: dict, alone: alone)
        let state = opening.state, senses = state.senses, modelReady = opening.modelReady, partPick = opening.partPick
        state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
        if let whole = opening.whole {
            state.openPartOf = { [weak self] in
                self?.popup.nextOpensInPlace()
                self?.showWord(whole, appName: appName, near: anchor)
            }
        }
        lastLookupState = state
        // Usually started when the text was selected (see `prepare`); otherwise start now. The
        // card waits briefly for the answer, so it opens complete instead of growing after.
        let key = Self.wordKey(context)
        let prepared = wordPrep.flatMap { $0.key == key ? $0.task : nil }
        if prepared == nil { wordPrep?.task.cancel() }
        wordPrep = nil
        cancelCardWork(keeping: prepared)
        phrasePrep?.cancel()
        phrasePrep = nil
        let pick: Task<SenseChoice, Error>? = !modelReady ? nil : prepared ?? Task { try await SenseChooser.choose(for: context, senses: senses) }
        if let pick { cardTasks.append(pick) }
        popup.show(LookupView(state: state), kind: .word, near: anchor, holdFor: modelReady ? 0.4 : 0,
                   copyText: { [weak state] in state?.copyText ?? "" },
                   speech: { [weak state] in state?.speech ?? SpeechPlan(text: "", help: "") },
                   anki: { [weak state] in state?.ankiNote })
        var record: [String: Any] = ["event": "word", "word": context.word, "sentence": context.sentence,
                                     "app": appName ?? "", "senses": senses.count]
        // A meaning picked on the card after its lookup was logged: History shows that one.
        var recordWritten = false
        state.onUserPick = { choice in
            guard recordWritten, let sense = senses[safe: choice.senseNumber - 1] else { return }
            Log.write(["event": "pick", "word": context.word, "sentence": context.sentence, "meaning": choice.meaningHere,
                       "pinyin": sense.pinyin, "gloss": Gloss.readable(sense.gloss)])
        }
        lookupTask = Task {
            let started = Date()
            // What the card ended on (the reader's pick, if they made one first), for History.
            // Written even when a newer card replaced this one before its pick: it was looked up.
            @MainActor func finish() {
                if let c = state.choice, let sense = state.senses[safe: c.senseNumber - 1] {
                    record["meaningHere"] = c.meaningHere
                    record["pinyin"] = sense.pinyin
                    record["gloss"] = Gloss.readable(sense.gloss)
                }
                Log.write(record)
                recordWritten = true
            }
            if let pick {
                do {
                    let choice = try await pick.value
                    guard !Task.isCancelled else { finish(); return }
                    if state.userPicked { record["userPickedFirst"] = true }   // the reader's choice stands
                    if popup.isRevealed {
                        withAnimation(cardMotion) { state.receive(choice) }
                    } else {
                        var still = Transaction()
                        still.disablesAnimations = true
                        withTransaction(still) { state.receive(choice) }
                        popup.endHold()
                    }
                    record["meaningHere"] = choice.meaningHere
                    record["tag"] = choice.tag.rawValue
                } catch is CancellationError {
                    finish(); return   // a newer card replaced this one
                } catch {
                    state.pickFailed(error)
                    popup.endHold()
                    record["error"] = String(describing: error)
                }
                record["ms"] = Int(Date().timeIntervalSince(started) * 1000)
                await relayout()
            }
            if let partPick, !Task.isCancelled {
                // Kept as the word's prepared answer, so opening the word doesn't ask again.
                let task = Task { try await SenseChooser.choose(for: partPick.context, senses: partPick.senses) }
                wordPrep = (Self.wordKey(partPick.context), task)
                cardTasks.append(task)
                if let c = try? await task.value, !Task.isCancelled {
                    state.receivePartOf(c, senses: partPick.senses)
                    record["partOf"] = partPick.context.word + "=" + c.meaningHere
                    await relayout()
                }
            }
            finish()
        }
    }

    private func showPhrase(_ selection: Selection, dict: CEDict, near anchor: NSRect) {
        cancelCardWork()
        wordPrep?.task.cancel()
        wordPrep = nil
        // Usually started when the text was selected (see `prepare`); otherwise start now.
        let prep = phrasePrep.flatMap { $0.matches(selection) ? $0 : nil } ?? PhrasePrep(selection, dict: dict)
        if phrasePrep !== prep { phrasePrep?.cancel() }
        phrasePrep = nil
        shownPhrasePrep = prep
        let state = PhraseState(selection: selection, dict: dict)
        state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
        lastPhraseState = state
        // The card opens at once with whatever is ready; the translation streams in, then the
        // rows fill in from the top as each word's sense is chosen.
        state.resolving = !prep.done
        state.follow(prep)
        popup.show(PhraseView(state: state), kind: .phrase, near: anchor, copyText: { [weak state] in state?.copyText ?? "" },
                   speech: { [weak state] in SpeechPlan(text: state?.selection.text ?? "", help: "Listen") },
                   anki: { [weak state] in state?.ankiNote })
        let started = Date()
        let readyAtClick = prep.done
        lookupTask = Task {
            await prep.finished()
            // Replaced by a newer card: kept only if it got as far as a translation.
            guard !Task.isCancelled || state.translation != nil else { return }
            Log.write(["event": "phrase", "text": selection.text, "words": state.tokens.map(\.text),
                       "translation": state.translation ?? "", "app": selection.appName ?? "",
                       "source": selection.source.rawValue, "resolved": state.choices.count,
                       "readyAtClick": readyAtClick, "translationMs": prep.translationMs,
                       "ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    private static func wordKey(_ context: WordInContext) -> String {
        "\(context.wordRange)|\(String(context.passage))"
    }

    /// Starts a card's work for a fresh selection, before the reader clicks.
    func prepare(_ selection: Selection) {
        AnkiLink.shared.check()   // so the card knows whether to offer Add to Anki
        guard let dict else { return }
        let selection = selection.wholeWords(dict: dict)
        if selection.isOneWord(dict: dict) {
            let context = Segmenter.context(for: selection.range, in: selection.passage)
            let key = Self.wordKey(context)
            let senses = dict.senses(for: context.word)
            guard wordPrep?.key != key, SenseChooser.canChoose, !senses.isEmpty,
                  GrammarWords.entry(context.word, in: context.passage, at: context.wordRange.lowerBound) == nil else { return }
            // Not the open card's own work (its "part of" pick is kept in wordPrep too).
            if let t = wordPrep?.task, !cardTasks.contains(t) { t.cancel() }
            wordPrep = (key, Task { try await SenseChooser.choose(for: context, senses: senses) })
            return
        }
        if phrasePrep?.matches(selection) == true { return }
        phrasePrep?.cancel()
        phrasePrep = PhrasePrep(selection, dict: dict)
    }

    /// Let SwiftUI lay out new content, then resize the popup around it.
    private func relayout() async {
        try? await Task.sleep(for: .milliseconds(30))
        popup.reposition()
    }

    /// A short message that closes itself, but only if it's still the card on screen:
    /// a lookup opened in the meantime stays open.
    func hint(_ text: String, near anchor: NSRect) {
        // Beside a pinned card, not in its place.
        let target = CardPin.shared.isOn && popup.isShowing ? hintPopup : popup
        target.show(HintView(text: text), kind: .hint, near: anchor)
        let generation = target.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard target.generation == generation, target.kind == .hint else { return }
            target.close()
        }
    }
}

/// The lookup history: one JSON line per lookup in
/// ~/Library/Application Support/LongyanReader/History/lookups.jsonl, on this Mac only. It's on
/// for new installs (it's what History shows); the menu keeps it for 30 days or turns it off,
/// and Clear moves the file to the Trash. Diagnostics (traces, probe output) go to `directory`,
/// under Logs, which cleanup tools empty freely; history moved out of there in 1.0.
enum Log {
    enum Keep: String, CaseIterable { case off, days30, all }

    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LongyanReader")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let historyDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LongyanReader/History")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static var file: URL { historyDirectory.appendingPathComponent("lookups.jsonl") }

    /// The history as text. A byte that isn't UTF-8 (a write cut off mid-character) becomes
    /// U+FFFD and spoils only its own line, not the whole file.
    static func text() -> String? {
        (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Before 1.0 the history was in Logs/LongyanReader. Moves it here once, at launch; if both
    /// exist, the old lines not already here go first (they're older) and the old file goes to
    /// the Trash. Merging twice (the Trash refused, or a quit in between) adds nothing.
    static func migrate() {
        let fm = FileManager.default
        let old = directory.appendingPathComponent("lookups.jsonl")
        guard fm.fileExists(atPath: old.path) else { return }
        if !fm.fileExists(atPath: file.path) {
            guard (try? fm.moveItem(at: old, to: file)) != nil else { return }
        } else {
            guard let a = try? Data(contentsOf: old), let b = try? Data(contentsOf: file) else { return }
            let here = Set(b.split(separator: UInt8(ascii: "\n")))
            let add = a.split(separator: UInt8(ascii: "\n")).filter { !here.contains($0) }
            if !add.isEmpty {
                let joined = Data(add.joined(separator: [UInt8(ascii: "\n")])) + Data("\n".utf8) + b
                guard (try? joined.write(to: file, options: .atomic)) != nil else { return }
            }
            try? fm.trashItem(at: old, resultingItemURL: nil)
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// On (kept whole) unless the reader turns it off: it's what the History window shows
    /// and exports as flashcards.
    static var keep: Keep {
        get {
            if let raw = UserDefaults.standard.string(forKey: "lookupHistory"), let k = Keep(rawValue: raw) { return k }
            let k: Keep = .all
            UserDefaults.standard.set(k.rawValue, forKey: "lookupHistory")
            return k
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lookupHistory"); trim() }
    }

    /// Set while the usage simulation runs.
    @MainActor static var paused = false

    @MainActor static func write(_ record: [String: Any]) {
        guard keep != .off, !paused else { return }
        var r = record
        r["at"] = ISO8601DateFormatter().string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return }
        guard FileManager.default.fileExists(atPath: file.path) else {
            FileManager.default.createFile(atPath: file.path, contents: data + Data("\n".utf8),
                                           attributes: [.posixPermissions: 0o600])
            return
        }
        // If it can't be opened, this lookup is lost, never the history (creating it again
        // would replace it).
        guard let h = try? FileHandle(forUpdating: file) else { return }
        // The throwing calls: the old write raises an exception (a crash) on a full disk.
        defer { try? h.close() }
        do {
            // A line cut off by a crash ends first, so it doesn't swallow this one.
            var line = data + Data("\n".utf8)
            let end = try h.seekToEnd()
            if end > 0 {
                try h.seek(toOffset: end - 1)
                if try h.read(upToCount: 1) != Data("\n".utf8) { line = Data("\n".utf8) + line }
                try h.seekToEnd()
            }
            try h.write(contentsOf: line)
        } catch {}
    }

    /// Readable by this account only, and with "30 days", nothing older. Runs at launch.
    static func trim() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard keep == .days30, let text = text() else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let parse = ISO8601DateFormatter()
        let lines = text.split(separator: "\n")
        let kept = lines.filter { line in
            guard let at = line.range(of: #""at":"([^"]+)""#, options: .regularExpression)
                .map({ String(line[$0].dropFirst(6).dropLast()) }), let date = parse.date(from: at) else { return true }
            return date >= cutoff
        }
        guard kept.count < lines.count else { return }
        try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Moves the history to the Trash (recoverable from there).
    static func clear() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
    }
}
