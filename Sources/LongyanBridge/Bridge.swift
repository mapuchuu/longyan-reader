import Foundation
import LongyanCore
import Observation

// A C interface over the shared core, for apps not written in Swift (the Windows app, in C#).
//
// Every function is called on the app's main thread, which is also the thread the core's main
// actor runs on: the app drains the main dispatch queue from its own message loop
// (windows/LongyanReader/Core.cs). Results come back through the callback given to
// `ly_start`, on that same thread, as UTF-8 JSON:
//
//   {"event":"ready", "entries":N, "model":"…"}       the dictionary is loaded
//   {"event":"failed", "message":"…"}                 it couldn't be
//   {"event":"card", "id":N, "card":{…}}              a card's contents, again on every change
//   {"event":"hint", "id":N, "message":"…"}           no card for that selection, and why
//   {"event":"model", "model":"…"}                    "ready", "unloadable" (the file won't load),
//                                                     "no-memory", or why the model can't pick: after
//                                                     ly_refresh, and whenever a load fails or recovers
//
// Text offsets are UTF-16 code units, as C# strings count them.

public typealias LyCallback = @convention(c) (UnsafePointer<CChar>) -> Void

@MainActor private var callback: LyCallback?
@MainActor private var dict: CEDict?
/// Why the dictionary didn't load, when it didn't.
@MainActor private var startFailure: String?
@MainActor var cards: [Int64: Card] = [:]   // also read by BridgeAnki.swift
/// Each word card's sense picks. One can be shared with a card opened after it ("part of").
@MainActor private var cardPicks: [Int64: [Task<SenseChoice, Error>]] = [:]
/// Work started by `ly_prepare`, before the reader clicks. A word card's "part of" pick is
/// kept in wordPrep too, so opening that word doesn't ask again.
@MainActor private var wordPrep: (key: String, task: Task<SenseChoice, Error>)?
@MainActor private var phrasePrep: PhrasePrep?
private let idLock = NSLock()
nonisolated(unsafe) private var lastID: Int64 = 0
private func newID() -> Int64 { idLock.withLock { lastID += 1; return lastID } }

/// Runs `body` on the main actor, after whatever the app asked before. Entry points don't
/// assume they're already on it: on Windows the main actor is whatever thread drains the main
/// queue, and the app does that from its own message loop.
private func onMain(_ body: @escaping @MainActor () -> Void) { Task { @MainActor in body() } }

@MainActor enum Card {
    case word(LookupState, whole: WordInContext?, tasks: [Task<Void, Never>])
    case phrase(PhraseState, PhrasePrep, task: Task<Void, Never>)
}

@MainActor private func send(_ object: [String: Any]) {
    guard let callback, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    text.withCString { callback($0) }
}

/// Loads the dictionary and the platform's services. `resources` is the folder holding the
/// core's data files; `model` the reading model's file (or NULL for none).
@_cdecl("ly_start")
public func ly_start(_ resources: UnsafePointer<CChar>, _ model: UnsafePointer<CChar>?, _ cb: LyCallback) {
    let dir = URL(fileURLWithPath: String(cString: resources), isDirectory: true)
    let modelPath = model.map { String(cString: $0) }
    onMain {
        callback = cb
        LocalModel.ollamaAllowed = false
        // The core reads its data files from Resources/ under the working directory when it
        // isn't in an app bundle.
        FileManager.default.changeCurrentDirectoryPath(dir.deletingLastPathComponent().path)
        // Only the app's own model file: not one another app put elsewhere on this computer.
        EmbeddedModel.pathOverride = modelPath ?? ""
        LocalModel.problemChanged = { _ in onMain { send(["event": "model", "model": modelStatus()]) } }
        Task { @MainActor in
            let loaded = await Task.detached { () -> Result<CEDict, Error> in
                let breaker = TaggerWordBreaker(weights: dir.appendingPathComponent("splitter.tsv"),
                                                cedict: dir.appendingPathComponent("cedict_ts.u8"))
                guard breaker.isLoaded else {
                    return .failure(NSError(domain: "Longyan", code: 1, userInfo: [NSLocalizedDescriptionKey: "splitter.tsv is missing"]))
                }
                Platform.wordBreaker = breaker
                PartOfSpeech.loadTable(dir.appendingPathComponent("parts-of-speech.tsv"))
                return Result { try CEDict.load() }
            }.value
            switch loaded {
            case .success(let d):
                dict = d
                _ = await LocalModel.isAvailable()
                send(["event": "ready", "entries": d.entryCount, "model": modelStatus()])
            case .failure(let e):
                startFailure = String(describing: e)
                send(["event": "failed", "message": startFailure!])
            }
        }
    }
}

@MainActor private func modelStatus() -> String {
    if let p = LocalModel.problem { return p.rawValue }
    return SenseChooser.canChoose ? "ready" : SenseChooser.noPickerReason
}

/// Starts loading the model, so a lookup that follows soon doesn't wait: call it when the
/// shortcut is pressed or text is selected.
@_cdecl("ly_warm_up")
public func ly_warm_up() { LocalModel.warmUp() }

/// Checks again for the model file (after a download), with the answer as a "model" event.
/// A file that failed to load is tried again: loaded now, so a failure shows at once.
@_cdecl("ly_refresh")
public func ly_refresh(_ model: UnsafePointer<CChar>?) {
    let path = model.map { String(cString: $0) }
    onMain {
        if let path { EmbeddedModel.pathOverride = path }
        EmbeddedModel.shared.forgetLoadFailure()
        LocalModel.forgetProblem()
        Task { @MainActor in
            _ = await LocalModel.isAvailable()
            send(["event": "model", "model": modelStatus()])
            if EmbeddedModel.modelPath != nil { LocalModel.warmUp() }
        }
    }
}

/// Quitting: stops the model's work and frees it, after a load or reply in progress (a reply
/// stops at its next token). It can wait seconds for a load, so call it off the main thread.
@_cdecl("ly_shutdown")
public func ly_shutdown() { EmbeddedModel.shared.shutdown() }

/// Opens a card for `passage`'s text from `start` to `end`. Returns the card's id: its
/// contents arrive as "card" events, or one "hint" event when there's nothing to show.
@_cdecl("ly_lookup")
public func ly_lookup(_ passage: UnsafePointer<CChar>, _ start: Int32, _ end: Int32) -> Int64 {
    let text = String(cString: passage)
    let id = newID()
    onMain {
        @MainActor func hint(_ message: String) { send(["event": "hint", "id": id, "message": message]) }
        guard let dict else {
            hint(startFailure == nil ? "Dictionary still loading…" : "The dictionary didn't load. Exit Longyan Reader and open it again.")
            return
        }
        let range = characterRange(text, Int(start), Int(end))
        var selection = Selection(passage: Array(text), range: range, bounds: nil, source: .accessibility, appName: nil).trimmed()
        guard !selection.range.isEmpty, selection.hasChinese else { hint("No Chinese text in the selection"); return }
        guard selection.range.count <= 400 else { hint("That's a lot of text: select a sentence or two"); return }
        selection = selection.wholeWords(dict: dict)
        if selection.isOneWord(dict: dict) {
            openWord(id, Segmenter.context(for: selection.range, in: selection.passage), alone: selection.isAlone)
        } else {
            openPhrase(id, selection)
        }
    }
    return id
}

/// Starts the work of a card for `passage`'s text from `start` to `end` before the reader
/// asks for it: call it when the selection button appears. Sends no events; a ly_lookup of the
/// same text then uses the work already started.
@_cdecl("ly_prepare")
public func ly_prepare(_ passage: UnsafePointer<CChar>, _ start: Int32, _ end: Int32) {
    let text = String(cString: passage)
    onMain {
        guard let dict else { return }
        let range = characterRange(text, Int(start), Int(end))
        var selection = Selection(passage: Array(text), range: range, bounds: nil, source: .accessibility, appName: nil).trimmed()
        guard !selection.range.isEmpty, selection.hasChinese, selection.range.count <= 400 else { return }
        selection = selection.wholeWords(dict: dict)
        if selection.isOneWord(dict: dict) {
            let context = Segmenter.context(for: selection.range, in: selection.passage)
            let key = wordKey(context)
            let senses = dict.senses(for: context.word)
            guard wordPrep?.key != key, SenseChooser.canChoose, !senses.isEmpty,
                  GrammarWords.entry(context.word, in: context.passage, at: context.wordRange.lowerBound) == nil else { return }
            release(wordPrep?.task)
            phrasePrep?.cancel()
            phrasePrep = nil
            wordPrep = (key, Task { try await SenseChooser.choose(for: context, senses: senses) })
            return
        }
        if phrasePrep?.matches(selection) == true { return }
        release(wordPrep?.task)
        wordPrep = nil
        phrasePrep?.cancel()
        phrasePrep = PhrasePrep(selection, dict: dict)
    }
}

/// Stops the work ly_prepare started, when the selection button went away without a click.
/// Work an open card is using carries on.
@_cdecl("ly_cancel_prepare")
public func ly_cancel_prepare() {
    onMain {
        release(wordPrep?.task)
        wordPrep = nil
        phrasePrep?.cancel()
        phrasePrep = nil
    }
}

/// The reader picks a meaning: `token` is the phrase row's id, or -1 on a word card.
@_cdecl("ly_pick")
public func ly_pick(_ id: Int64, _ token: Int32, _ sense: Int32) {
    onMain {
        switch cards[id] {
        case .word(let s, _, _)?: s.pick(Int(sense))
        case .phrase(let s, _, _)?: if let t = s.tokens.first(where: { $0.id == Int(token) }) { s.pick(t, sense: Int(sense)) }
        case nil: break
        }
    }
}

/// Back to the model's answer.
@_cdecl("ly_use_suggested")
public func ly_use_suggested(_ id: Int64, _ token: Int32) {
    onMain {
        switch cards[id] {
        case .word(let s, _, _)?: s.useSuggested()
        case .phrase(let s, _, _)?: if let t = s.tokens.first(where: { $0.id == Int(token) }) { s.useSuggested(t) }
        case nil: break
        }
    }
}

/// Show All / Show Fewer.
@_cdecl("ly_toggle_all")
public func ly_toggle_all(_ id: Int64, _ token: Int32) {
    onMain {
        switch cards[id] {
        case .word(let s, _, _)?: s.showAllSenses.toggle()
        case .phrase(let s, _, _)?:
            let t = Int(token)
            if s.showingAll.contains(t) { s.showingAll.remove(t) } else { s.showingAll.insert(t) }
        case nil: break
        }
    }
}

/// Opens or closes a phrase row.
@_cdecl("ly_toggle_row")
public func ly_toggle_row(_ id: Int64, _ token: Int32) {
    onMain {
        if case .phrase(let s, _, _)? = cards[id], let t = s.tokens.first(where: { $0.id == Int(token) }) { s.toggle(t) }
    }
}

/// Opens the card for the word a lone character belongs to, as a new card: returns its id.
@_cdecl("ly_open_part_of")
public func ly_open_part_of(_ id: Int64) -> Int64 {
    let new = newID()
    onMain {
        guard case .word(_, let whole?, _)? = cards[id] else { send(["event": "hint", "id": new, "message": "Nothing to open"]); return }
        openWord(new, whole, alone: false)
    }
    return new
}

/// The card was closed: its work stops and no more events come for it.
@_cdecl("ly_close")
public func ly_close(_ id: Int64) {
    onMain {
        let picks = cardPicks.removeValue(forKey: id) ?? []
        switch cards.removeValue(forKey: id) {
        case .word(_, _, let tasks)?: tasks.forEach { $0.cancel() }; picks.forEach(release)
        case .phrase(_, let prep, let task)?: prep.cancel(); task.cancel()
        case nil: break
        }
    }
}

// MARK: Cards

private func wordKey(_ context: WordInContext) -> String {
    "\(context.wordRange)|\(String(context.passage))"
}

/// Stops a pick no open card is using.
@MainActor private func release(_ task: Task<SenseChoice, Error>?) {
    guard let task, !cardPicks.values.contains(where: { $0.contains(task) }) else { return }
    task.cancel()
    if wordPrep?.task == task { wordPrep = nil }
}

@MainActor private func openWord(_ id: Int64, _ context: WordInContext, alone: Bool) {
    guard let dict else { return }
    let opening = LookupState.opening(context, dict: dict, alone: alone)
    let state = opening.state
    var tasks: [Task<Void, Never>] = []
    // Usually started when the text was selected (see `ly_prepare`); otherwise start now.
    let key = wordKey(context)
    let prepared = wordPrep.flatMap { $0.key == key ? $0.task : nil }
    let old = wordPrep?.task
    wordPrep = nil
    if prepared == nil { release(old) }
    phrasePrep?.cancel()
    phrasePrep = nil
    var picks: [Task<SenseChoice, Error>] = []
    if opening.modelReady {
        let senses = state.senses
        let pick = prepared ?? Task { try await SenseChooser.choose(for: context, senses: senses) }
        picks.append(pick)
        tasks.append(Task { @MainActor in
            do {
                let choice = try await pick.value
                guard !Task.isCancelled else { return }
                state.receive(choice)
            } catch is CancellationError {
            } catch {
                state.pickFailed(error)
            }
        })
    } else {
        release(prepared)
    }
    if let partPick = opening.partPick {
        let first = tasks.first
        tasks.append(Task { @MainActor in
            await first?.value
            guard !Task.isCancelled, cards[id] != nil else { return }
            // Kept as the word's prepared answer, so opening the word doesn't ask again.
            let pick = Task { try await SenseChooser.choose(for: partPick.context, senses: partPick.senses) }
            cardPicks[id, default: []].append(pick)
            let old = wordPrep?.task
            wordPrep = (wordKey(partPick.context), pick)
            release(old)
            guard let c = try? await pick.value, !Task.isCancelled else { return }
            state.receivePartOf(c, senses: partPick.senses)
        })
    }
    cards[id] = .word(state, whole: opening.whole, tasks: tasks)
    cardPicks[id] = picks
    observe(id) { wordCard(state) }
}

@MainActor private func openPhrase(_ id: Int64, _ selection: Selection) {
    guard let dict else { return }
    release(wordPrep?.task)
    wordPrep = nil
    // Usually started when the text was selected (see `ly_prepare`); otherwise start now.
    let prep = phrasePrep.flatMap { $0.matches(selection) ? $0 : nil } ?? PhrasePrep(selection, dict: dict)
    if phrasePrep !== prep { phrasePrep?.cancel() }
    phrasePrep = nil
    let state = PhraseState(selection: selection, dict: dict)
    state.resolving = !prep.done
    state.follow(prep)
    let task = Task { @MainActor in await prep.finished() }
    cards[id] = .phrase(state, prep, task: task)
    observe(id) { phraseCard(state) }
}

/// Sends the card now, then again each time something it read changes, while it's open.
@MainActor private func observe(_ id: Int64, _ build: @escaping @MainActor () -> [String: Any]) {
    guard cards[id] != nil else { return }
    let card = withObservationTracking { build() } onChange: {
        // Called before the change lands: read it on the next turn.
        Task { @MainActor in observe(id, build) }
    }
    send(["event": "card", "id": id, "card": card])
}

@MainActor private func status(_ phase: LookupState.Phase, viaTranslation: Bool) -> String? {
    switch phase {
    case .choosing: return "Reading the sentence…"
    case .dictionaryOnly(let why): return why == Gloss.notInDictionary ? "Not in the dictionary" : "Dictionary order · \(why)"
    case .failed: return "Dictionary order · couldn't tell which meaning fits here"
    case .chosen: return viaTranslation ? "Picked to match the translation" : nil
    }
}

@MainActor private func noteJSON(_ note: StoredNote?) -> Any {
    guard let note else { return NSNull() }
    return ["title": note.tag == "lost_in_translation" ? "Lost in translation" : "Cultural context", "text": note.shown]
}

@MainActor private func syllables(_ pinyin: String) -> [[String: Any]] {
    Pinyin.syllables(pinyin).map { ["text": $0.text, "tone": $0.tone] }
}

/// Meaning rows as the Mac card lists them: each reading's together, numbered as in the dictionary.
@MainActor private func senseRows(_ senses: [Sense], shown: [(offset: Int, element: Sense)], listed: [Sense]?,
                                  chosen: Int?, headed: Bool, word: String?, dimUnchosen: Bool) -> [[String: Any]] {
    var order: [String] = []
    for item in shown where !order.contains(item.element.pinyin) { order.append(item.element.pinyin) }
    let grouped = order.flatMap { r in shown.filter { $0.element.pinyin == r } }
    return grouped.enumerated().map { position, item in
        let (i, sense) = item
        var row: [String: Any] = [
            "index": i, "number": i + 1,
            "gloss": listed?.contains(sense) == true ? Gloss.short(sense.gloss) : Gloss.listed(sense.gloss),
            "tip": Gloss.readable(sense.gloss),
            "chosen": chosen == i, "dimmed": dimUnchosen && chosen != i,
            "hasNote": word.map { NotesStore.hasExactNote($0, sense) } ?? false,
        ]
        if let pos = PartOfSpeech.of(sense.gloss) { row["pos"] = pos.label }
        if headed && (position == 0 || grouped[position - 1].element.pinyin != sense.pinyin) {
            row["reading"] = Pinyin.marked(sense.pinyin)
        }
        return row
    }
}

@MainActor private func wordCard(_ state: LookupState) -> [String: Any] {
    let word = state.context.word
    let chosen = state.chosenIndex
    let all = Array(state.senses.enumerated())
    let listed = state.grammar?.listed(state.senses)
    let preview = state.senses.preview(chosen: chosen)
    let collapsed = all.filter { listed?.contains($0.element) ?? preview.contains($0.offset) || $0.offset == chosen }
    let shown = state.showAllSenses ? all : collapsed
    let showReading = Set(state.senses.map(\.pinyin)).count > 1
    var card: [String: Any] = [
        "kind": "word", "word": word, "pinyin": syllables(state.headerPinyin),
        "contextual": state.isContextual,
        "note": noteJSON(state.choice.flatMap { NotesStore.note(word, state.senses[safe: $0.senseNumber - 1]) }),
        "senses": senseRows(state.senses, shown: shown, listed: listed, chosen: chosen,
                            headed: showReading && (listed == nil || state.showAllSenses), word: word,
                            dimUnchosen: state.choice != nil),
        "alternatives": state.context.alternatives, "copy": word,
    ]
    if let c = state.choice { card["meaning"] = c.meaningHere }
    if let s = status(state.phase, viaTranslation: state.choice?.viaTranslation == true) { card["status"] = s }
    if state.userPicked, let s = state.suggested, s.senseNumber != state.choice?.senseNumber { card["back"] = s.meaningHere }
    if let p = state.partOf {
        var part: [String: Any] = ["word": p.word, "pinyin": Pinyin.marked(p.pinyin)]
        if let m = p.meaning { part["meaning"] = m }
        card["partOf"] = part
    }
    if state.senses.count > collapsed.count { card["more"] = state.showAllSenses ? "Show Fewer" : "Show All \(state.senses.count)" }
    return card
}

@MainActor private func phraseCard(_ state: PhraseState) -> [String: Any] {
    var card: [String: Any] = ["kind": "phrase", "text": state.selection.text, "copy": state.selection.text]
    if let t = state.translation { card["translation"] = t }
    else if let e = state.translationError { card["translationError"] = "No translation · \(e)" }
    let maxRows = 24
    card["rows"] = state.tokens.prefix(maxRows).map { token -> [String: Any] in
        let senses = state.senses[token.id] ?? []
        let shownSense = state.shownSense(token)
        let pending = state.pending(token)
        var row: [String: Any] = [
            "token": token.id, "text": token.text,
            "pinyin": syllables(senses[safe: shownSense ?? 0]?.pinyin ?? ""),
            "gloss": state.gloss(token), "pending": pending, "guess": state.isGuess(token),
            "dim": particleWords.contains(token.text),
            "opens": state.canOpen(token), "open": state.expanded == token.id,
            "hasNote": !pending && state.note(token) != nil,
        ]
        guard state.expanded == token.id else { return row }
        if pending || state.choosing.contains(token.id) { row["status"] = "Reading the sentence…" }
        else if let f = state.failures[token.id] { row["status"] = f }
        else if state.choices[token.id]?.viaTranslation == true { row["status"] = "Picked to match the translation" }
        else if let here = state.meaningHere(token) { row["here"] = here }
        if state.canUseSuggested(token), let m = state.suggestedMeaning(token) { row["back"] = m }
        row["note"] = noteJSON(state.note(token))
        let listed = state.grammarEntry(token)?.listed(senses)
        let all = state.showingAll.contains(token.id)
        let preview = senses.preview(chosen: shownSense)
        let enumerated = Array(senses.enumerated())
        let collapsed = enumerated.filter {
            (listed?.contains($0.element) ?? preview.contains($0.offset)) || (listed != nil && state.grammar(token) == nil && $0.offset == shownSense)
        }
        let shown = all ? enumerated : collapsed
        let chosen = state.grammar(token) == nil ? shownSense : nil
        row["senses"] = senseRows(senses, shown: shown, listed: listed, chosen: chosen,
                                  headed: Set(shown.map(\.element.pinyin)).count > 1, word: nil, dimUnchosen: true)
        if senses.count > collapsed.count { row["more"] = all ? "Show Fewer" : "Show All \(senses.count)" }
        if senses.isEmpty { row["status"] = "Not in the dictionary" }
        return row
    }
    if state.tokens.count > maxRows { card["hidden"] = "\(state.tokens.count - maxRows) more words not shown" }
    return card
}

/// UTF-16 offsets to a range of the text's Characters.
private func characterRange(_ text: String, _ start: Int, _ end: Int) -> Range<Int> {
    let u = text.utf16
    let lo = max(0, min(start, u.count)), hi = max(lo, min(end, u.count))
    let a = u.index(u.startIndex, offsetBy: lo), b = u.index(u.startIndex, offsetBy: hi)
    let first = text.distance(from: text.startIndex, to: a)
    return first..<(first + text[a..<b].count)
}
