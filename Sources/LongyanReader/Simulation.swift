import AppKit
import SwiftUI

/// Debug: scripted usage of the real cards through the same code paths as clicks, with
/// checks after each step. Trigger with the probe notification object "simulate";
/// the report is written to ~/Library/Logs/LongyanReader/simulation.txt.
extension AppDelegate {
    func runUsageSimulation() async -> String {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures += 1 }
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func waitForAnswer(_ state: LookupState?, timeout: Double = 12) async {
            var t = 0.0
            while let state, state.phase == .choosing, t < timeout { await wait(0.1); t += 0.1 }
        }

        let savedStyle = UserDefaults.standard.string(forKey: "cardStyle")
        let savedAppearance = UserDefaults.standard.string(forKey: "appearance")
        let savedZoom = UserDefaults.standard.object(forKey: "card.word.width")
        let savedPhraseZoom = UserDefaults.standard.object(forKey: "card.phrase.width")
        UserDefaults.standard.removeObject(forKey: "card.word.width")
        UserDefaults.standard.removeObject(forKey: "card.phrase.width")
        defer {
            UserDefaults.standard.set(savedStyle, forKey: "cardStyle")
            UserDefaults.standard.set(savedAppearance, forKey: "appearance")
            if let savedZoom { UserDefaults.standard.set(savedZoom, forKey: "card.word.width") }
            if let savedPhraseZoom { UserDefaults.standard.set(savedPhraseZoom, forKey: "card.phrase.width") }
            applyAppearance()
        }

        let screen = NSScreen.main?.visibleFrame ?? .zero
        let anchor = NSRect(x: screen.midX - 180, y: screen.midY + 220, width: 60, height: 20)
        func word(_ text: String, _ index: Int, _ length: Int = 1) -> Selection {
            Selection(passage: Array(text), range: index..<(index + length), bounds: nil, source: .accessibility, appName: "Simulation")
        }
        func sample() -> String {
            popup.surfaceSample().map { String(format: "alpha %.2f brightness %.2f", $0.alpha, $0.brightness) } ?? "none"
        }

        for (style, mode) in [("glass", "light"), ("glass", "dark"), ("classic", "light"), ("classic", "dark")] {
            UserDefaults.standard.set(style, forKey: "cardStyle")
            UserDefaults.standard.set(mode, forKey: "appearance")
            applyAppearance()
            lines.append("— \(style), \(mode)")

            // 1. Pick an alternate meaning after the answer: the tint must stay.
            show(word("奶奶上个月走了，全家人都很难过。", 5), near: anchor)
            let state = lastLookupState
            await waitForAnswer(state)
            await wait(0.5)
            let before = popup.surfaceSample()
            let other = (state?.chosenIndex ?? 0) == 0 ? 1 : 0
            state?.pick(other)
            await wait(0.6)
            let after = popup.surfaceSample()
            lines.append("  surface before pick: \(before.map { String(format: "alpha %.2f brightness %.2f", $0.alpha, $0.brightness) } ?? "none"); after: \(sample())")
            check((after?.alpha ?? 0) > 0.3 && abs((after?.alpha ?? 0) - (before?.alpha ?? 0)) < 0.05,
                  "tint/surface unchanged after picking another meaning")
            check(mode == "dark" ? (after?.brightness ?? 1) < 0.4 : (after?.brightness ?? 0) > 0.8,
                  "surface matches \(mode) mode")
            check(state?.chosenIndex == other, "picked meaning is shown")
            check(popup.kind == .word && popup.windowFitsCard, "card open and fully inside its window")
        }
        UserDefaults.standard.set("glass", forKey: "cardStyle")
        UserDefaults.standard.set("light", forKey: "appearance")
        applyAppearance()
        lines.append("— behaviour (glass, light)")

        // 2. Picking before the model answers: the reader's pick must stand.
        show(word("他靠关系找到了工作。", 2, 2), near: anchor)
        let early = lastLookupState
        early?.pick(1)
        await waitForAnswer(early)
        await wait(3)
        check(early?.chosenIndex == 1, "an early pick isn't overwritten by the model's later answer")

        // 3. A hint followed quickly by a lookup: the hint's timer must not close the lookup.
        hint("Highlight some Chinese text first", near: anchor)
        await wait(0.3)
        show(word("他太老实了，总是被人骗。", 2, 2), near: anchor)
        await wait(2.2)
        check(popup.kind == .word, "a hint's close timer leaves the next card open")

        // 4. Phrase card: open rows, pick a meaning inside one, switch rows; the window must
        //    always hold the whole card while it animates.
        show(word("明朝实行海禁，闭关锁国，导致中国错过了工业革命。", 0, 23), near: anchor)
        await wait(1.5)
        var alwaysFits = true
        func watch(_ seconds: Double) async {
            var t = 0.0
            while t < seconds { if !popup.windowFitsCard { alwaysFits = false }; await wait(0.03); t += 0.03 }
        }
        if let phrase = lastPhraseState, phrase.tokens.count > 4 {
            let a = phrase.tokens[3], b = phrase.tokens[1]
            withAnimation(.smooth(duration: 0.25)) { phrase.toggle(a) }
            await watch(2.5)
            withAnimation(.smooth(duration: 0.25)) { phrase.pick(a, sense: 0) }
            await watch(0.6)
            check(phrase.choices[a.id]?.senseNumber == 1, "picking a meaning inside a phrase row works")
            await watch(3)
            check(phrase.choices[a.id]?.senseNumber == 1, "that pick isn't overwritten by a late model answer")
            withAnimation(.smooth(duration: 0.25)) { phrase.toggle(b) }
            await watch(2.5)
            check(phrase.expanded == b.id, "opening another row switches rows")
            withAnimation(.smooth(duration: 0.25)) { phrase.toggle(b) }
            await watch(0.8)
            check(phrase.expanded == nil, "a row closes again")
            check(popup.surfaceSample().map { $0.alpha > 0.3 } ?? false, "phrase card keeps its tint after row changes")
        } else {
            check(false, "phrase card opened with words")
        }
        check(alwaysFits, "the window held the whole card through every phrase animation")

        // 5. Switching style with a card open redraws it.
        UserDefaults.standard.set("classic", forKey: "cardStyle")
        popup.refreshStyle()
        await wait(0.4)
        let classic = popup.surfaceSample()
        check((classic?.alpha ?? 0) > 0.7, "switching to Classic redraws the open card (surface \(sample()))")

        // 6. Rapid lookups leave exactly one card on screen.
        for i in 0..<6 {
            show(word("这本书很有意思。", i % 4 + 1), near: anchor)
            await wait(0.05)
        }
        await wait(0.6)
        check(PopupController.visibleCardWindows == 1, "rapid lookups leave one card (found \(PopupController.visibleCardWindows))")

        popup.close()
        await wait(0.3)
        check(PopupController.visibleCardWindows == 0, "closing leaves no card windows")
        lines.insert("Usage simulation: \(failures == 0 ? "all passed" : "\(failures) failed")", at: 0)
        return lines.joined(separator: "\n")
    }
}
