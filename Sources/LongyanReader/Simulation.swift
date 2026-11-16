import AppKit
import SwiftUI

#if DEV_TOOLS   // dev builds only (scripts/build-app.sh --dev)

/// Debug: scripted usage of the real cards through the same code paths as clicks, with
/// checks after each step. Trigger with the probe notification object "simulate";
/// the report is written to ~/Library/Logs/LongyanReader/simulation.txt.
extension AppDelegate {
    func runUsageSimulation() async -> String {
        // Its lookups are made up: keep them out of the reader's history.
        Log.paused = true
        defer { Log.paused = false }
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            lines.append((ok ? "PASS " : "FAIL ") + what)
            if !ok { failures += 1 }
        }
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        // The drag checks post real mouse events, which macOS allows only with Accessibility
        // access; an ad-hoc rebuild can lose it until the app is re-added in System Settings.
        lines.append("  accessibility \(AXIsProcessTrusted() ? "allowed" : "NOT allowed"), posting events \(CGPreflightPostEventAccess() ? "allowed" : "NOT allowed")")
        func waitForAnswer(_ state: LookupState?, timeout: Double = 12) async {
            var t = 0.0
            while let state, state.phase == .choosing, t < timeout { await wait(0.1); t += 0.1 }
        }

        let savedModel = UserDefaults.standard.string(forKey: "senseModel")
        let savedStyle = UserDefaults.standard.string(forKey: "cardStyle")
        let savedAppearance = UserDefaults.standard.string(forKey: "appearance")
        let savedZoom = UserDefaults.standard.object(forKey: CardLayout.zoomKey)
        UserDefaults.standard.removeObject(forKey: CardLayout.zoomKey)
        let sizeKeys = ["card.width.word", "card.width.phrase", "card.height.word", "card.height.phrase"]
        let savedSizes = sizeKeys.map { UserDefaults.standard.object(forKey: $0) }
        sizeKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let savedPin = CardPin.shared.isOn, savedSpot = CardPin.shared.topLeft
        CardPin.shared.isOn = false
        popup.ignoresOutsideInput = true
        defer {
            popup.ignoresOutsideInput = false
            CardPin.shared.isOn = savedPin
            CardPin.shared.topLeft = savedSpot
            if let savedModel { LocalModel.select(savedModel) } else { UserDefaults.standard.removeObject(forKey: "senseModel") }
            UserDefaults.standard.set(savedStyle, forKey: "cardStyle")
            UserDefaults.standard.set(savedAppearance, forKey: "appearance")
            if let savedZoom { UserDefaults.standard.set(savedZoom, forKey: CardLayout.zoomKey) } else { UserDefaults.standard.removeObject(forKey: CardLayout.zoomKey) }
            for (key, value) in zip(sizeKeys, savedSizes) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
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

        // 2a2. A lone character shows the word it's part of; a word of several meanings gets its
        //      meaning from the model after the character's, and opening it reuses that answer.
        show(word("修车已经彻底没戏了。", 4), near: anchor)
        let part = lastLookupState
        await waitForAnswer(part)
        for _ in 0..<40 where part?.partOf?.meaning == nil { await wait(0.1) }
        check(part?.partOf?.word == "彻底" && part?.partOf?.meaning != nil,
              "a character shows the word it's in (\(part?.partOf?.word ?? "none"): \(part?.partOf?.meaning ?? "no meaning"))")
        part?.openPartOf()
        await wait(0.1)
        check(lastLookupState?.context.word == "彻底" && lastLookupState?.choice != nil,
              "opening that word shows its card with the meaning ready")
        show(word("撬了把门的合页。", 3), near: anchor)
        check(lastLookupState?.partOf == nil, "门 in 把门的合页 isn't shown as part of 把门")

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
        check(GrammarWords.entry("了", in: Array("受得了"), at: 2)?.reading == "liao3", "了 in 受得了 reads liǎo")
        check(GrammarWords.entry("了", in: Array("他得了感冒"), at: 2)?.reading == "le5", "了 after 他得 reads le")
        if let dict {
            check(Segmenter.word(at: 1, in: Array("他得了感冒。"), dict: dict)?.word == "得",
                  "得 in 他得了感冒 isn't joined into 得了 \"all right\"")
            check(Segmenter.word(at: 1, in: Array("他长得很高。"), dict: dict)?.word == "长得", "长得 still joins")
        }
        check(Gloss.readable("also pr. [di4] or [di5] in poetry and songs") == "also pronounced dì or di in poetry and songs",
              "pronunciation notes keep their pinyin")
        check(Gloss.short("(not) at all") == "(not) at all" && Gloss.short("absolutely (not)") == "absolutely (not)",
              "short meanings keep their \"(not)\" (\(Gloss.short("(not) at all")))")
        check(Gloss.short("(to say the) least") == "to say the least", "a bracket that starts the phrase is unwrapped")
        check(Gloss.short("opposite: passive 被動|被动[bei4 dong4]") == "not passive", "an opposite note reads as a meaning")
        check(Gloss.short("(physics) energy") == "energy", "labels in brackets still go")

        // 2d. Every meaning is on offer; a short list always includes the one chosen.
        if let dict {
            let opposite = Segmenter.phrase(0..<9, in: Array("我住在银行斜对面。"), dict: dict).map(\.text)
            check(opposite.contains("斜对面") && dict.contains("眼里"),
                  "words CC-CEDICT lacks (extra-words.u8) are found and kept whole (\(opposite.joined(separator: " ")))")
            let stale = SenseOrder.shared.filter { dict.senses(for: $0.key, handOrdered: false).count != $0.value.count }.map(\.key)
            check(stale.isEmpty, "every sense-order.tsv line matches the dictionary (stale: \(stale.sorted().joined()))")
            let yan = dict.senses(for: "眼")
            check(yan.first?.gloss.hasPrefix("eye") == true && !yan.forModel.contains { $0.gloss.contains("salient") }
                  && yan.contains { $0.gloss.contains("salient") },
                  "眼 leads with eye; its rare sense is listed but not offered to the model")
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
            // A short card, so the open row makes it scroll: no scroll bar may take width, and
            // the bottom edge fades instead.
            let fullHeight = popup.currentLayout?.maxHeight ?? 640
            popup.currentLayout?.maxHeight = 200
            withAnimation(.smooth(duration: 0.25)) { phrase.toggle(a) }
            await watch(2.5)
            check(!popup.scrollBarTakesWidth, "a phrase card that scrolls shows no scroll bar")
            check(popup.currentLayout?.moreBelow == true, "a card with more below fades at the bottom")
            popup.saveImage(to: Log.directory.appendingPathComponent("simulation-fade.png"))
            popup.currentLayout?.maxHeight = fullHeight
            popup.currentLayout?.objectWillChange.send()   // maxHeight isn't published
            popup.currentLayout?.onChange(false)
            await watch(0.5)
            let shown = popup.currentLayout.map { "content \(Int($0.contentHeight)), max \(Int($0.maxHeight))" } ?? "no card"
            if let l = popup.currentLayout, l.contentHeight <= l.maxHeight {
                check(l.moreBelow == false, "a card showing all its content doesn't fade (\(shown))")
            } else {
                // The open row is taller than this screen allows: close it, so the card fits.
                withAnimation(.smooth(duration: 0.25)) { phrase.toggle(a) }
                await watch(0.6)
                let after = popup.currentLayout.map { "content \(Int($0.contentHeight)), max \(Int($0.maxHeight))" } ?? "no card"
                check(popup.currentLayout?.moreBelow == false, "a card showing all its content doesn't fade (\(after), row closed)")
            }
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
                let long = Array("然而次日是清明节，和周六、周日调休连成了三天假期，也就是说我又要再等三天。")
                let start = long.count - 12
                let inSentence = Segmenter.phrase(start..<(start + 11), in: long, dict: dict)
                if await LocalModel.isAvailable(), let deng = inSentence.first(where: { $0.text == "等" }) {
                    let picks = await PhraseState.resolve(inSentence, in: long, dict: dict)
                    check(picks[deng.id].map { dict.senses(for: "等")[$0.senseNumber - 1].gloss.contains("wait") } ?? false,
                          "a selection within a longer sentence is read on its own terms (再等三天: to wait)")
                }
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

        // 5d. A selection that cuts a word in half reads as the whole word.
        if let dict {
            let cut = word("到了电商平台大促时，我们", 5, 4).wholeWords(dict: dict)
            check(cut.text == "平台大促时", "a selection cut mid-word widens to the word (\(cut.text))")
            let deliberate = word("科学家研究生命的起源。", 3, 2).wholeWords(dict: dict)
            check(deliberate.text == "研究", "a selection on a word boundary stays as made (\(deliberate.text))")
        }

        // 6. Rapid lookups leave exactly one card on screen.
        for i in 0..<6 {
            show(word("这本书很有意思。", i % 4 + 1), near: anchor)
            await wait(0.05)
        }
        await wait(0.6)
        check(PopupController.visibleCardWindows == 1, "rapid lookups leave one card (found \(PopupController.visibleCardWindows))")

        // 7. A pinned card stays where it is while new lookups replace it, a hint opens
        //    beside it rather than in its place, and Copy has the card's text.
        show(word("这本书很有意思。", 2), near: anchor)
        await wait(0.8)
        popup.togglePin()
        let pinnedFrame = popup.windowFrame
        let far = anchor.offsetBy(dx: -260, dy: -180)
        show(word("他们的关系很好。", 3, 2), near: far)
        await waitForAnswer(lastLookupState)
        await wait(0.8)
        let swappedFrame = popup.windowFrame
        lines.append("  pinned card top-left \(pinnedFrame.map { "\($0.minX), \($0.maxY)" } ?? "none") → \(swappedFrame.map { "\($0.minX), \($0.maxY)" } ?? "none")")
        check(pinnedFrame != nil && pinnedFrame?.minX == swappedFrame?.minX && pinnedFrame?.maxY == swappedFrame?.maxY,
              "a pinned card's next lookup opens in the same place")
        check(PopupController.visibleCardWindows == 1, "a pinned card is replaced, not stacked (found \(PopupController.visibleCardWindows))")
        hint("Highlight some Chinese text first", near: far)
        await wait(0.6)
        check(popup.isShowing && popup.kind == .word && PopupController.visibleCardWindows == 2,
              "a hint opens beside a pinned card, not in its place (\(PopupController.visibleCardWindows) cards, main \(popup.kind?.rawValue ?? "none"))")
        await wait(2.0)
        check(popup.isShowing && PopupController.visibleCardWindows == 1, "the pinned card outlasts the hint")
        check(lastLookupState?.copyText == "关系", "Copy on a word card copies just the word")
        if let phrase = lastPhraseState {
            check(phrase.copyText == phrase.selection.text, "Copy on a phrase card copies just the highlighted text")
        }

        // 8. The side edges set the width (the text keeps its size and the height follows
        //    the content); the corners scale the card, text and all; pinching zooms too.
        if let l = popup.currentLayout, l.placedBelow {
            func rect() -> NSRect { popup.cardScreenRect ?? .zero }
            func drag(_ e: CardLayout.Edges, _ dx: CGFloat, _ dy: CGFloat) async {
                let r = rect()
                let from = NSPoint(x: e.contains(.left) ? r.minX : r.maxX, y: e.contains(.top) ? r.maxY : r.minY)
                popup.resize(e, to: from)
                popup.resize(e, to: NSPoint(x: from.x + dx, y: from.y + dy))
                popup.resize(e, to: nil)
                await wait(0.4)
            }
            func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.6 }
            let z0 = l.zoom
            var r0 = rect()
            await drag([.right], 40, 0)
            var r = rect()
            check(near(r.width, r0.width + 40) && near(r.minX, r0.minX) && near(r.maxY, r0.maxY) && l.zoom == z0
                  && near(r.height, l.contentHeight),
                  "the right edge widens the card, the text keeps its size and the height fits it (\(Int(r0.width)) → \(Int(r.width)))")
            r0 = rect()
            await drag([.left], -30, 0)
            r = rect()
            check(near(r.width, r0.width + 30) && near(r.maxX, r0.maxX) && near(r.minX, r0.minX - 30), "the left edge widens the card to the left")
            await drag([.right], -200, 0)
            check(near(rect().height, l.contentHeight), "a narrower card grows downward to fit its content (\(Int(rect().height)))")
            l.resetSize()
            await wait(0.4)
            r0 = rect()
            var z = l.zoom
            await drag([.bottom, .right], r0.width * 0.2, -r0.height * 0.2)
            r = rect()
            check(abs(l.zoom - z * 1.2) < 0.001 && near(r.width, r0.width * 1.2) && near(r.minX, r0.minX) && near(r.maxY, r0.maxY)
                  && near(r.height, l.contentHeight),
                  "the bottom-right corner scales the card and its text (zoom \(String(format: "%.2f", z)) → \(String(format: "%.2f", l.zoom)))")
            r0 = rect()
            z = l.zoom
            await drag([.top, .left], r0.width * 0.1, -r0.height * 0.1)
            r = rect()
            check(abs(l.zoom - z * 0.9) < 0.001 && near(r.maxX, r0.maxX) && abs(r.minY - r0.minY) < 2,
                  "the top-left corner scales it down, the opposite corner staying put")
            l.resetSize([.bottom, .right], zoomToo: true)
            await wait(0.4)
            check(l.zoom == 1 && l.width == l.baseWidth, "double-clicking a corner restores the actual size")
            let w2 = l.width
            l.magnify(by: 1.2)
            l.endMagnify()
            check(abs(l.zoom - 1.2) < 0.001 && abs(l.width - w2 * 1.2) < 0.5, "pinching zooms the text and the card with it")
            l.resetSize(zoomToo: true)
            await wait(0.4)
        }
        // Real drags on the edges and a corner resize the card rather than moving it.
        if let height = NSScreen.screens.first?.frame.height {
            let back = NSEvent.mouseLocation
            func post(_ type: CGEventType, _ p: NSPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: p.x, y: height - p.y), mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            func drag(from: NSPoint, by d: CGVector) async {
                post(.mouseMoved, from); await wait(0.15)
                post(.leftMouseDown, from); await wait(0.08)
                for step in 1...8 {
                    post(.leftMouseDragged, NSPoint(x: from.x + d.dx * CGFloat(step) / 8, y: from.y + d.dy * CGFloat(step) / 8))
                    await wait(0.02)
                }
                post(.leftMouseUp, NSPoint(x: from.x + d.dx, y: from.y + d.dy)); await wait(0.4)
            }
            // Just outside each edge, where a window's resize area also reaches.
            for (name, at, d) in [("right edge", { (r: NSRect) in NSPoint(x: r.maxX + 2, y: r.midY) }, CGVector(dx: 36, dy: 0)),
                                  ("left edge", { (r: NSRect) in NSPoint(x: r.minX - 2, y: r.midY) }, CGVector(dx: -36, dy: 0))] {
                guard let card = popup.cardScreenRect, let l = popup.currentLayout, l.placedBelow else { break }
                await drag(from: at(card), by: d)
                let after = popup.cardScreenRect ?? .zero
                check(abs(after.width - (card.width + abs(d.dx))) < 1 && after.maxY == card.maxY
                      && (d.dx > 0 ? after.minX == card.minX : after.maxX == card.maxX),
                      "a real drag on the \(name) resizes the card in place (\(Int(card.width))×\(Int(card.height)) → \(Int(after.width))×\(Int(after.height)))")
                l.resetSize()
                await wait(0.4)
            }
            if let card = popup.cardScreenRect, let l = popup.currentLayout, l.placedBelow {
                let z = l.zoom
                await drag(from: NSPoint(x: card.maxX + 1, y: card.minY - 1), by: CGVector(dx: card.width * 0.15, dy: -card.height * 0.15))
                let after = popup.cardScreenRect ?? .zero
                check(l.zoom > z * 1.1 && after.width > card.width * 1.1 && after.minX == card.minX && after.maxY == card.maxY,
                      "a real drag on the bottom-right corner scales the card in place (zoom \(String(format: "%.2f", z)) → \(String(format: "%.2f", l.zoom)))")
                l.resetSize([.bottom, .right], zoomToo: true)
                await wait(0.4)
            }
            // The bottom-right corner reaches well into the card, and stops where moving starts.
            if let card = popup.cardScreenRect, let l = popup.currentLayout, l.placedBelow {
                let z = l.zoom
                let deep = ResizeHandles.bigCorner - ResizeHandles.outside - 3
                await drag(from: NSPoint(x: card.maxX - deep, y: card.minY + deep), by: CGVector(dx: card.width * 0.15, dy: -card.height * 0.15))
                let after = popup.cardScreenRect ?? .zero
                check(l.zoom > z * 1.1 && after.minX == card.minX && after.maxY == card.maxY,
                      "a drag \(Int(deep)) pt inside the bottom-right corner still scales the card (zoom \(String(format: "%.2f", z)) → \(String(format: "%.2f", l.zoom)))")
                l.resetSize([.bottom, .right], zoomToo: true)
                await wait(0.4)
            }
            if let card = popup.cardScreenRect, let l = popup.currentLayout, l.placedBelow {
                let z = l.zoom
                let past = ResizeHandles.bigCorner - ResizeHandles.outside + 6
                await drag(from: NSPoint(x: card.maxX - past, y: card.minY + past), by: CGVector(dx: 30, dy: -20))
                let after = popup.cardScreenRect ?? .zero
                check(l.zoom == z && after.size == card.size && abs(after.minX - card.minX - 30) < 1,
                      "a drag just past the corner (\(Int(past)) pt in) moves the card instead")
                await drag(from: NSPoint(x: after.maxX - past, y: after.minY + past), by: CGVector(dx: -30, dy: 20))
            }
            post(.mouseMoved, back)
        }
        popup.togglePin()
        check(!CardPin.shared.isOn, "unpinning")

        popup.close()
        await wait(0.3)
        check(PopupController.visibleCardWindows == 0, "closing leaves no card windows")
        lines.insert("Usage simulation: \(failures == 0 ? "all passed" : "\(failures) failed")", at: 0)
        return lines.joined(separator: "\n")
    }
}
#endif
