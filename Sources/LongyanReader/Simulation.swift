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

        let savedModel = UserDefaults.standard.string(forKey: "senseModel")
        let savedStyle = UserDefaults.standard.string(forKey: "cardStyle")
        let savedAppearance = UserDefaults.standard.string(forKey: "appearance")
        let savedZoom = UserDefaults.standard.object(forKey: "card.word.width")
        let savedPhraseZoom = UserDefaults.standard.object(forKey: "card.phrase.width")
        UserDefaults.standard.removeObject(forKey: "card.word.width")
        UserDefaults.standard.removeObject(forKey: "card.phrase.width")
        popup.ignoresOutsideInput = true
        defer {
            popup.ignoresOutsideInput = false
            if let savedModel { LocalModel.select(savedModel) } else { UserDefaults.standard.removeObject(forKey: "senseModel") }
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

        // 2b. Clicking the meaning already chosen leaves the headline alone; picking another
        //     and then "use suggested" brings the model's wording back.
        show(word("我很理解你的想法。", 2, 2), near: anchor)
        let single = lastLookupState
        await waitForAnswer(single)
        let headline = single?.choice?.meaningHere
        if let i = single?.chosenIndex { single?.pick(i) }
        await wait(0.3)
        check(single?.choice?.meaningHere == headline && headline != nil,
              "clicking the chosen meaning keeps the headline (\(headline ?? "none"))")
        show(word("奶奶上个月走了，全家人都很难过。", 5), near: anchor)
        let multi = lastLookupState
        await waitForAnswer(multi)
        let suggestedText = multi?.choice?.meaningHere
        let firstChoice = multi?.chosenIndex ?? 0
        multi?.pick(firstChoice == 0 ? 1 : 0)
        await wait(0.3)
        check(multi?.choice?.meaningHere != suggestedText, "picking another meaning updates the headline")
        check(multi?.isContextual == false, "a meaning the reader picked isn't labelled as contextual")
        let labelled = LookupState(context: WordInContext(word: "紧张", passage: Array("工作太紧张了。"), wordRange: 3..<5, alternatives: []), senses: [Sense(pinyin: "jin3 zhang1", gloss: "nervous")], appName: nil, phase: .choosing)
        labelled.receive(SenseChoice(senseNumber: 1, meaningHere: "busy"))
        check(labelled.isContextual, "the model's own wording is labelled 'In this context'")
        labelled.receive(SenseChoice(senseNumber: 1, meaningHere: "nervous"))
        check(!labelled.isContextual, "dictionary wording isn't labelled")
        multi?.useSuggested()
        await wait(0.3)
        check(multi?.choice?.meaningHere == suggestedText && multi?.chosenIndex == firstChoice,
              "'use suggested meaning' restores the model's answer and wording")

        // 3. A hint followed quickly by a lookup: the hint's timer must not close the lookup.
        hint("Highlight some Chinese text first", near: anchor)
        await wait(0.3)
        show(word("他太老实了，总是被人骗。", 2, 2), near: anchor)
        await wait(2.2)
        check(popup.kind == .word, "a hint's close timer leaves the next card open")

        // 4. Phrase card: open rows, pick a meaning inside one, switch rows; the window must
        //    always hold the whole card while it animates.
        //    Every word's sense is chosen before the card opens; when the text was selected a
        //    moment earlier (the button appearing), the card should open at once.
        let phraseSelection = word("明朝实行海禁，闭关锁国，导致中国错过了工业革命。", 0, 23)
        prepare(phraseSelection)
        await wait(2.5)
        let clicked = Date()
        show(phraseSelection, near: anchor)
        var opened = 0.0
        while popup.kind != .phrase || lastPhraseState?.selection.text != phraseSelection.text, opened < 3 { await wait(0.02); opened += 0.02 }
        lines.append("  card opened \(Int(Date().timeIntervalSince(clicked) * 1000)) ms after the click (prepared while selecting)")
        check(opened < 0.3, "a phrase prepared while selecting opens at once")
        var settle = 0.0
        while lastPhraseState?.resolving == true, settle < 8 { await wait(0.05); settle += 0.05 }
        if let phrase = lastPhraseState {
            let dict = self.dict!
            let ambiguous = PhraseState.ambiguous(phrase.tokens, dict: dict)
            let resolved = ambiguous.filter { phrase.choices[$0.id] != nil }.count
            lines.append("  resolved before opening: " + ambiguous.map { "\($0.text)=\(phrase.gloss($0))" }.joined(separator: " / "))
            check(resolved == ambiguous.count && !phrase.resolving, "every ambiguous word resolved (\(resolved)/\(ambiguous.count))")
        }
        await wait(0.4)
        var alwaysFits = true
        func watch(_ seconds: Double) async {
            var t = 0.0
            while t < seconds { if !popup.windowFitsCard { alwaysFits = false }; await wait(0.03); t += 0.03 }
        }
        if let phrase = lastPhraseState, phrase.tokens.count > 4 {
            let a = phrase.tokens[3], b = phrase.tokens[1]
            // Opening a row never changes it: the senses were chosen before the card opened.
            var rowsChecked = 0, rowsStable = 0
            for t in phrase.tokens.prefix(6) {
                let before = phrase.gloss(t), senseBefore = phrase.shownSense(t)
                withAnimation(.smooth(duration: 0.25)) { phrase.toggle(t) }
                var waited = 0.0
                while phrase.choosing.contains(t.id) || (phrase.choices[t.id] == nil && waited < 0.4), waited < 8 {
                    await wait(0.1); waited += 0.1
                }
                rowsChecked += 1
                if phrase.shownSense(t) == senseBefore && phrase.gloss(t) == before { rowsStable += 1 }
                lines.append("  row \(t.text): \(before) → \(phrase.gloss(t))\(phrase.meaningHere(t).map { " (here: \($0))" } ?? "")")
            }
            check(rowsStable == rowsChecked, "opening phrase rows never changes their gloss (\(rowsStable)/\(rowsChecked))")
            if phrase.expanded != nil, let open = phrase.tokens.first(where: { $0.id == phrase.expanded }) {
                withAnimation(.smooth(duration: 0.25)) { phrase.toggle(open) }
                await wait(0.4)
            }
            withAnimation(.smooth(duration: 0.25)) { phrase.toggle(a) }
            await watch(2.5)
            let target = phrase.shownSense(a) == 0 ? 1 : 0
            let glossBefore = phrase.gloss(a)
            withAnimation(.smooth(duration: 0.25)) { phrase.pick(a, sense: target) }
            await watch(0.6)
            check(phrase.choices[a.id]?.senseNumber == target + 1 && phrase.gloss(a) != glossBefore,
                  "picking another meaning inside a phrase row updates that row")
            withAnimation(.smooth(duration: 0.25)) { phrase.pick(a, sense: target) }
            await watch(0.3)
            check(phrase.choices[a.id]?.senseNumber == target + 1, "clicking the shown meaning again changes nothing")
            await watch(3)
            check(phrase.choices[a.id]?.senseNumber == target + 1, "that pick isn't overwritten by a late model answer")
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

        // 5b. A phrase that wasn't prepared, with each sense picker: the card opens at once,
        //     the translation comes first, then the rows fill in from the top.
        for model in ["qwen3.5:4b", "apple"] {
            LocalModel.select(model)
            let usable = model == "apple" ? true : await LocalModel.isAvailable()
            guard usable else { lines.append("  (\(model) not running; skipped)"); continue }
            lines.append("— unprepared phrase, \(model)")
            let fresh = word("看到妈妈的白头发，我一下子破防了，真心疼她。", 0, 21)
            let clickedFresh = Date()
            show(fresh, near: anchor)
            var t = 0.0
            while popup.kind != .phrase || lastPhraseState?.selection.text != fresh.text, t < 3 { await wait(0.01); t += 0.01 }
            let openMs = Int(Date().timeIntervalSince(clickedFresh) * 1000)
            check(openMs < 150, "an unprepared phrase card opens at once (\(openMs) ms)")
            guard let phrase = lastPhraseState, let dict = self.dict else { continue }
            var order: [Int] = [], translationFirst = true, translatedAt = 0
            t = 0
            while phrase.resolving || phrase.translation == nil, t < 15 {
                if translatedAt == 0, phrase.translation != nil { translatedAt = Int(Date().timeIntervalSince(clickedFresh) * 1000) }
                for id in phrase.choices.keys.sorted() where !order.contains(id) {
                    order.append(id)
                    if phrase.translation == nil { translationFirst = false }
                }
                await wait(0.02); t += 0.02
            }
            let ambiguous = PhraseState.ambiguous(phrase.tokens, dict: dict).map(\.id)
            lines.append("  translation at \(translatedAt) ms: \(phrase.translation ?? "none")")
            lines.append("  \(order.count)/\(ambiguous.count) words by \(Int(Date().timeIntervalSince(clickedFresh) * 1000)) ms, in order: "
                         + order.compactMap { id in phrase.tokens.first { $0.id == id }?.text }.joined(separator: " "))
            check(translationFirst && phrase.translation != nil, "the translation arrives before the word rows")
            check(!order.isEmpty && order == order.sorted(), "rows fill in from the top")
            let words = phrase.tokens.map(\.text)
            check(words.contains("破防") && words.contains("心疼"), "slang and 真|心疼 stay whole")
        }
        if let savedModel { LocalModel.select(savedModel) }

        // 5c. Text that wraps mid-word reads as one line; a blank line stays a break.
        let wrapped = word("是跟着师\n父看看学学", 0, 10).trimmed()
        check(wrapped.text == "是跟着师父看看学学", "a line break inside a word is removed (\(wrapped.text))")
        let inner = Selection(passage: Array("前面的话。跟着师\n父学，后面"), range: 5..<11, bounds: nil, source: .accessibility, appName: nil).trimmed()
        check(inner.text == "跟着师父学", "the selection stays on the same words after unwrapping (\(inner.text))")
        let paragraphs = word("第一段。\n\n第二段。", 0, 10).trimmed()
        check(paragraphs.text.contains("\n\n"), "a blank line stays a paragraph break")

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
