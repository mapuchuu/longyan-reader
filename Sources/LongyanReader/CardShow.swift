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
@MainActor
enum CardShow {
    static func run(_ args: [String]) {
        guard args.count >= 5, let x = Double(args[3]), let y = Double(args[4]),
              let data = FileManager.default.contents(atPath: args[2]),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            print("usage: LongyanReader --show <card.json> <x> <y>   (points from the main screen's top-left)")
            exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)   // notes show as they come, even into a file
        let app = NSApplication.shared
        let show = Shower(json: json, at: CGPoint(x: x, y: y))
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

        /// As AppDelegate's: let SwiftUI lay out the new content, then size the card around it.
        private func relayout() async {
            try? await Task.sleep(for: .milliseconds(30))
            popup.reposition()
        }
    }
}
