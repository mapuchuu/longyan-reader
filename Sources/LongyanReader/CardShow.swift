import AppKit
import LongyanCore
import SwiftUI

/// Dev only: `LongyanReader --show <card.json> <x> <y>` opens the live card for a saved card
/// JSON (windows/gallery/*.json), through the same popup as a lookup, so the Mac and Windows
/// cards can be filmed doing the same things side by side. No model: CardFixture builds the
/// card from the dictionary and the JSON. The selection is taken to be the box (x, y, 60, 20) in
/// points, from the top-left of the main screen (the one with the menu bar), as Windows' DIPs
/// are. When the card closes it opens again a second later in the same place, until Ctrl+C.
/// Nothing is written to the history, and the card's size and pin are kept in a store of their
/// own (LongyanReader.show), emptied at each start, so every run starts at the usual size.
/// `--script "<plan>"` (or `--script @file`) after the numbers works the card from inside the
/// app each time it opens: CardScript.swift says how. `--appearance light|dark` holds the card
/// in one for the run (the process's appearance; no setting changes), and `--trace FILE`
/// writes what is on screen each frame while it moves (CardTrace.swift).
@MainActor
enum CardShow {
    static func run(_ args: [String]) {
        let usage = "usage: LongyanReader --show <card.json> <x> <y> [--script \"<plan>\" | --script @<file>] [--appearance light|dark] [--trace <file>]   (points from the main screen's top-left)"
        var options: [String: String] = [:]
        var ok = args.count >= 5 && (args.count - 5) % 2 == 0
        if ok {
            for i in stride(from: 5, to: args.count, by: 2) {
                guard ["--script", "--appearance", "--trace"].contains(args[i]), options[args[i]] == nil else { ok = false; break }
                options[args[i]] = args[i + 1]
            }
        }
        if let a = options["--appearance"], a != "light" && a != "dark" { ok = false }
        guard ok, let x = Double(args[3]), let y = Double(args[4]),
              let data = FileManager.default.contents(atPath: args[2]),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            print(usage)
            exit(2)
        }
        var steps: [CardScript.Step] = []
        if var plan = options["--script"] {
            if plan.hasPrefix("@") {
                guard let text = try? String(contentsOfFile: String(plan.dropFirst()), encoding: .utf8) else { print("error: can't read \(plan)"); exit(2) }
                plan = text.split(separator: "\n").filter { !$0.hasPrefix("#") }.joined(separator: ";")
            }
            let parsed = CardScript.parse(plan)
            if let error = parsed.error { print("error: \(error)"); exit(2) }
            steps = parsed.steps
            CardScript.shared.enabled = true
        }
        // Light or dark for this run only: the process's appearance, not the system's or the app's setting.
        if let a = options["--appearance"] {
            let appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
            CardAppearance.forced = appearance
            NSApplication.shared.appearance = appearance
        }
        var tracer: CardTracer?
        if let path = options["--trace"] {
            guard let t = CardTracer(path: path) else { print("error: can't write \(path)"); exit(2) }
            tracer = t
        }
        setvbuf(stdout, nil, _IOLBF, 0)   // notes show as they come, even into a file
        let app = NSApplication.shared
        let show = Shower(json: json, at: CGPoint(x: x, y: y))
        show.steps = steps
        show.tracer = tracer
        app.delegate = show
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static let suite = "LongyanReader.show"

    @MainActor
    final class Shower: NSObject, NSApplicationDelegate {
        let json: [String: Any]
        let at: CGPoint
        let popup = PopupController()
        var dict: CEDict?
        var showing = false
        var stop: DispatchSourceSignal?
        var steps: [CardScript.Step] = []
        var planRunning = false
        var tracer: CardTracer?

        init(json: [String: Any], at: CGPoint) {
            self.json = json
            self.at = at
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            CardDefaults.store = UserDefaults(suiteName: suite) ?? .standard
            // Ctrl+C: empty the store again on the way out.
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { UserDefaults.standard.removePersistentDomain(forName: suite); exit(0) }
            source.resume()
            stop = source
            if !AXIsProcessTrusted() {
                print("note: without Accessibility for this terminal, Esc and clicks in other apps aren't seen, so they don't close the card")
            }
            do { dict = try CEDict.load() } catch { print("error: the dictionary didn't load: \(error)"); exit(1) }
            popup.onReveal = { [weak self] in self?.revealed() }
            if let tracer {
                tracer.window = { [weak self] in self?.popup.window }
                tracer.start()
            }
            open()
            // Closed (Esc, a click away, the close button): open it again a second later.
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.showing, !self.popup.isShowing else { return }
                    self.showing = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.open() }
                }
            }
        }

        func applicationWillTerminate(_ notification: Notification) {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        private var anchor: NSRect { AppDelegate.appKitRect(CGRect(x: at.x, y: at.y, width: 60, height: 20)) }

        func open() {
            guard let dict, let (built, warnings) = CardFixture.build(json, dict: dict) else {
                print("error: not a card JSON (it needs \"kind\": \"word\" with \"word\", or \"phrase\" with \"text\")")
                exit(1)
            }
            for w in warnings { print("fixture: \(w)") }
            CardScript.shared.actions = [:]   // this card's buttons register theirs
            CardTrace.values = [:]
            tracer?.card += 1
            switch built {
            case .word(let state): openWord(state)
            case .phrase(let state):
                state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
                popup.show(PhraseView(state: state), kind: .phrase, near: anchor, copyText: { [weak state] in state?.copyText ?? "" },
                           speech: { [weak state] in SpeechPlan(text: state?.selection.text ?? "", help: "Listen") },
                           anki: { [weak state] in state?.ankiNote })
            }
            showing = true
        }

        private func openWord(_ state: LookupState) {
            state.onLayoutChange = { [weak self] in Task { await self?.relayout() } }
            if let part = state.partOf, let dict {
                // Part of: the whole word in its place, still reading the sentence (no model).
                state.openPartOf = { [weak self] in
                    self?.popup.nextOpensInPlace()
                    self?.openWord(CardFixture.loading(part.word, dict: dict))
                }
            }
            // As a lookup whose pick is in before the card shows: held for it, then let go at once.
            popup.show(LookupView(state: state), kind: .word, near: anchor, holdFor: 0.4,
                       copyText: { [weak state] in state?.copyText ?? "" },
                       speech: { [weak state] in state?.speech ?? SpeechPlan(text: "", help: "") },
                       anki: { [weak state] in state?.ankiNote })
            DispatchQueue.main.async { [weak self] in self?.popup.endHold() }
        }

        // MARK: The script

        /// A card started to appear: the plan runs from 0.5 s on, when the reveal is done,
        /// unless it's already running (a card it reopened).
        private func revealed() {
            guard !steps.isEmpty else { return }
            CardScript.log("reveal")
            guard !planRunning else { return }
            planRunning = true
            let script = CardScript.shared
            script.hovered = nil; script.pressed = nil; script.cardHovered = false
            let start = DispatchTime.now() + 0.5
            DispatchQueue.main.asyncAfter(deadline: start) { CardScript.log("t=0 (reveal done)") }
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: start + step.t) { [weak self] in
                    self?.run(step)
                    if i == self?.steps.count.advanced(by: -1) { self?.planRunning = false }
                }
            }
        }

        private func run(_ step: CardScript.Step) {
            let script = CardScript.shared
            CardScript.log(String(format: "t=%g %@", step.t, step.action) + (step.target.map { " " + $0 } ?? ""))
            switch step.action {
            case "hover":
                script.cardHovered = true
                script.pressed = nil
                script.hovered = step.target
            case "unhover":
                script.pressed = nil
                script.hovered = nil
                script.cardHovered = false
            case "press":
                script.cardHovered = true
                script.hovered = step.target
                script.pressed = step.target
            case "release":
                release()
            case "click":
                script.cardHovered = true
                script.hovered = step.target
                script.pressed = step.target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
                    CardScript.log(String(format: "t=%g release", step.t + 0.07))
                    self?.release()
                }
            case "esc", "close":
                popup.outside()
            case "reopen":
                open()
            default: break
            }
        }

        /// The pressed target's own action, as letting go over it runs it.
        private func release() {
            let script = CardScript.shared
            guard let target = script.pressed else { return }
            script.pressed = nil
            if let action = script.actions[target] { action() } else { CardScript.log("no \(target) on this card") }
        }

        /// As AppDelegate's: let SwiftUI lay out the new content, then size the card around it.
        private func relayout() async {
            try? await Task.sleep(for: .milliseconds(30))
            popup.reposition()
        }
    }
}
