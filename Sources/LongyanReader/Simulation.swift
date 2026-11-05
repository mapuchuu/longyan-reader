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
        let savedZoom = UserDefaults.standard.object(forKey: CardLayout.zoomKey)
        UserDefaults.standard.removeObject(forKey: CardLayout.zoomKey)
        popup.ignoresOutsideInput = true
        defer {
            popup.ignoresOutsideInput = false
            if let savedModel { LocalModel.select(savedModel) } else { UserDefaults.standard.removeObject(forKey: "senseModel") }
            UserDefaults.standard.set(savedStyle, forKey: "cardStyle")
            UserDefaults.standard.set(savedAppearance, forKey: "appearance")
            if let savedZoom { UserDefaults.standard.set(savedZoom, forKey: CardLayout.zoomKey) }
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
        let labelled = LookupState(context: WordInContext(word: "紧张", passage: Array("工作太紧张了。"), wordRange: 3..<5, alternatives: []), senses: [Sense(pinyin: "jin3 zhang1", gloss: "nervous")], phase: .choosing)
        labelled.receive(SenseChoice(senseNumber: 1, meaningHere: "busy"))
        check(labelled.isContextual, "the model's own wording is labelled 'In this context'")
        labelled.receive(SenseChoice(senseNumber: 1, meaningHere: "nervous"))
        check(!labelled.isContextual, "dictionary wording isn't labelled")
        multi?.useSuggested()
        await wait(0.3)
        check(multi?.choice?.meaningHere == suggestedText && multi?.chosenIndex == firstChoice,
              "'use suggested meaning' restores the model's answer and wording")

        // 2b2. The full list opens and closes, and the card resizes to fit each time.
        multi?.showAllSenses = true
        multi?.onLayoutChange()
        await wait(0.5)
        check(popup.windowFitsCard, "the card fits after 'Show more'")
        multi?.showAllSenses = false
        multi?.onLayoutChange()
        await wait(0.5)
        check(popup.windowFitsCard, "the card fits after 'Show less'")

        // 2c. 的 and 了 show one fixed line, with no model call; a definition can still be picked.
        show(word("我的书很新。", 1), near: anchor)
        let de = lastLookupState
        check(de?.choice?.meaningHere == de?.grammar?.summary && de?.phase == .chosen && de?.headerPinyin == "de5",
              "的 opens straight to its fixed line")
        check(de?.isContextual == false, "的's fixed line isn't labelled as contextual")
        de?.pick(0)
        await wait(0.3)
        check(de?.chosenIndex == 0 && de?.choice?.meaningHere != de?.grammar?.summary, "a definition of 的 can be picked")
        de?.useSuggested()
        await wait(0.3)
        check(de?.choice?.meaningHere == de?.grammar?.summary, "'use suggested meaning' restores 的's fixed line")
        let liao = Array("吃不了")
        check(GrammarWords.entry("了", in: liao, at: 2)?.reading == "liao3", "了 after 不 reads liǎo")
        check(GrammarWords.entry("了", in: Array("下雨了"), at: 2)?.reading == "le5", "了 after a verb reads le")
        check(Gloss.readable("also pr. [di4] or [di5] in poetry and songs") == "also pronounced dì or di in poetry and songs",
              "pronunciation notes keep their pinyin")

        // 2d. Every meaning is on offer; a short list always includes the one chosen.
        if let dict {
            let gan = dict.senses(for: "干")
            check(gan.count > CEDict.modelSenseLimit, "a card has all of 干's meanings (\(gan.count))")
            let toDo = gan.firstIndex { $0.gloss == "to do" }
            let preview = gan.preview(chosen: toDo)
            check(preview.count == 5 && preview.contains(toDo ?? -1), "the short list has 5 meanings, with the chosen one")
            check(Set(preview.map { gan[$0].pinyin }).count > 1, "the short list covers 干's readings")
        }

        // 2e. A real drag on the card moves it, and it stays there as it changes size. The next
        //     card opens by its word again. Uses the pointer, and puts it back afterwards.
        show(word("奶奶上个月走了，全家人都很难过。", 5), near: anchor)
        let dragged = lastLookupState
        await waitForAnswer(dragged)
        await wait(0.5)
        let home = popup.windowOrigin
        if let from = popup.dragHandlePoint, let height = NSScreen.screens.first?.frame.height {
            let back = NSEvent.mouseLocation
            func post(_ type: CGEventType, _ p: NSPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: height - p.y), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            post(.mouseMoved, from)
            await wait(0.15)
            post(.leftMouseDown, from)
            await wait(0.1)
            for step in 1...10 {
                post(.leftMouseDragged, NSPoint(x: from.x - CGFloat(step) * 12, y: from.y - CGFloat(step) * 8))
                await wait(0.02)
            }
            await wait(0.1)
            post(.leftMouseUp, NSPoint(x: from.x - 120, y: from.y - 80))
            await wait(0.2)
            post(.mouseMoved, back)
            let moved = popup.windowOrigin
            lines.append("  card moved from \(home.map { "\($0)" } ?? "none") to \(moved.map { "\($0)" } ?? "none")")
            check((home?.x ?? 0) - (moved?.x ?? 0) > 80 && (home?.y ?? 0) - (moved?.y ?? 0) > 50 && popup.kind == .word, "dragging the card moves it")
            popup.scrolledOutside()
            check(popup.kind == .word, "scrolling elsewhere leaves a dragged card open")
            dragged?.showAllSenses = true
            dragged?.onLayoutChange()
            await wait(0.5)
            check(popup.windowOrigin?.x == moved?.x, "a dragged card stays put when its content grows")
            dragged?.showAllSenses = false
            // From a row: the card moves and the row isn't picked. A plain click still picks.
            if let frame = popup.windowFrame, let layout = popup.currentLayout {
                let row = NSPoint(x: frame.midX, y: frame.maxY - 28 - min(layout.height, 200))
                let start = popup.windowOrigin
                post(.mouseMoved, row)
                await wait(0.15)
                post(.leftMouseDown, row)
                await wait(0.1)
                for step in 1...6 {
                    post(.leftMouseDragged, NSPoint(x: row.x + CGFloat(step) * 8, y: row.y))
                    await wait(0.02)
                }
                await wait(0.1)
                let end = NSPoint(x: row.x + 48, y: row.y)
                post(.leftMouseUp, end)
                await wait(0.3)
                check((popup.windowOrigin?.x ?? 0) - (start?.x ?? 0) > 30 && dragged?.userPicked == false,
                      "a drag from a row moves the card without picking the row")
                // Clicking the meaning already chosen does nothing, so try a few rows.
                var tried: [String] = []
                for offset in [0, 45, -45, 90] as [CGFloat] where dragged?.userPicked == false {
                    let target = NSPoint(x: end.x, y: end.y + offset)
                    post(.mouseMoved, target)
                    await wait(0.1)
                    post(.leftMouseDown, target)
                    await wait(0.05)
                    post(.leftMouseUp, target)
                    await wait(0.4)
                    tried.append("\(offset)")
                }
                check(dragged?.userPicked == true, "a plain click on a row still picks it (tried \(tried.joined(separator: ", ")))")
                post(.mouseMoved, back)
            }
            popup.close()
            await wait(0.2)
            show(word("奶奶上个月走了，全家人都很难过。", 5), near: anchor)
            await wait(0.4)
            check(popup.windowOrigin?.x == home?.x, "the next card opens by its word again")
            popup.scrolledOutside()
            check(popup.kind == nil, "scrolling elsewhere still closes a card that wasn't dragged")
        }

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
            let ambiguous = PhraseState.ambiguous(phrase.tokens, in: phrase.selection.passage, dict: dict)
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
            let senseBefore = phrase.shownSense(a)
            withAnimation(.smooth(duration: 0.25)) { phrase.pick(a, sense: target) }
            await watch(0.6)
            check(phrase.choices[a.id]?.senseNumber == target + 1 && phrase.gloss(a) != glossBefore,
                  "picking another meaning inside a phrase row updates that row")
            withAnimation(.smooth(duration: 0.25)) { phrase.pick(a, sense: target) }
            await watch(0.3)
            check(phrase.choices[a.id]?.senseNumber == target + 1, "clicking the shown meaning again changes nothing")
            await watch(3)
            check(phrase.choices[a.id]?.senseNumber == target + 1, "that pick isn't overwritten by a late model answer")
            check(phrase.canUseSuggested(a), "a row moved off its meaning offers the suggested one")
            withAnimation(cardMotion) { phrase.useSuggested(a) }
            await watch(0.4)
            check(phrase.shownSense(a) == senseBefore && phrase.gloss(a) == glossBefore && !phrase.canUseSuggested(a),
                  "'use suggested meaning' restores a phrase row")
            withAnimation(cardMotion) { phrase.pick(a, sense: target) }
            withAnimation(cardMotion) { phrase.pick(a, sense: senseBefore ?? 0) }
            await watch(0.3)
            check(!phrase.canUseSuggested(a) && phrase.gloss(a) == glossBefore, "picking the suggested meaning by hand counts as going back")
            if let dict {
                let fixed = PhraseState(selection: word("我的书很好", 0, 5), dict: dict)
                if let de = fixed.tokens.first(where: { $0.text == "的" }), fixed.grammarEntry(de) != nil {
                    let line = fixed.gloss(de)
                    fixed.pick(de, sense: 1)
                    let moved = fixed.canUseSuggested(de) && fixed.gloss(de) != line
                    fixed.useSuggested(de)
                    check(moved && fixed.gloss(de) == line, "'use suggested meaning' restores a phrase row's fixed line (的)")
                } else { check(false, "的 has a fixed line in a phrase row") }
            }
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
            let ambiguous = PhraseState.ambiguous(phrase.tokens, in: phrase.selection.passage, dict: dict).map(\.id)
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
