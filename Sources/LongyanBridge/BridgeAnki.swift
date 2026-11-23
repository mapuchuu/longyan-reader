import Foundation
import LongyanCore
import Observation

// Add to Anki for apps over the bridge, through the core's AnkiLink and AnkiButtonModel
// (LongyanCore/Anki.swift): the same requests to AnkiConnect on 127.0.0.1:8765, the same
// button states and messages as the Mac card. Called on the app's main thread, like the rest
// of the bridge. Events come back through the callback given to `ly_anki_start`, as UTF-8 JSON:
//
//   {"event":"anki", "available":B, "decks":[…], "deck":"…"}    after a check, when the answer changed
//   {"event":"anki-button", "id":N, "state":"…", "message":"…"} a card's button: "ready", "adding",
//                                                              "added", "failed" (message says why),
//                                                              or "none" (nothing to add)

@MainActor private var ankiCallback: LyCallback?
/// Each open card's button, by card id.
@MainActor private var ankiButtons: [Int64: AnkiButtonModel] = [:]

@MainActor private func ankiSend(_ object: [String: Any]) {
    guard let ankiCallback, let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    text.withCString { ankiCallback($0) }
}

@MainActor private func ankiStatus() {
    ankiSend(["event": "anki", "available": AnkiLink.shared.available, "decks": AnkiLink.shared.decks, "deck": AnkiLink.deck])
}

/// Starts Add to Anki: `cb` gets its events, `deck` is the deck the reader chose (empty for
/// the default), and AnkiConnect is asked at once whether it's there.
@_cdecl("ly_anki_start")
public func ly_anki_start(_ cb: LyCallback, _ deck: UnsafePointer<CChar>?) {
    let deck = deck.map { String(cString: $0) } ?? ""
    onAnkiMain {
        ankiCallback = cb
        let wanted = deck.isEmpty ? AnkiLink.defaultDeck : deck
        if AnkiLink.deck != wanted { AnkiLink.deck = wanted }
        AnkiLink.shared.check(force: true, changed: ankiStatus)
        ankiStatus()
    }
}

/// Asks AnkiConnect whether it's there, at most every 10 s unless `force`: call it when the
/// eye appears, when the menu or settings open, and after a card opens. An "anki" event
/// follows if the answer changed.
@_cdecl("ly_anki_check")
public func ly_anki_check(_ force: Int32) {
    onAnkiMain { AnkiLink.shared.check(force: force != 0, changed: ankiStatus) }
}

/// The deck cards go into from now on (the Mac's Anki Deck menu); empty for the default.
@_cdecl("ly_anki_set_deck")
public func ly_anki_set_deck(_ deck: UnsafePointer<CChar>) {
    let deck = String(cString: deck)
    onAnkiMain {
        AnkiLink.deck = deck.isEmpty ? AnkiLink.defaultDeck : deck
        ankiStatus()
    }
}

/// Gives card `id` its Anki button: call it as the card opens, while AnkiConnect answers.
/// The button's state follows as "anki-button" events, the first at once; a word already in
/// the deck turns to "added" when Anki says so.
@_cdecl("ly_anki_open")
public func ly_anki_open(_ id: Int64) {
    onAnkiMain { openAnkiButton(id, tries: 5) }
}

@MainActor private func openAnkiButton(_ id: Int64, tries: Int) {
    if let model = ankiButtons[id] { sendButton(id, model); return }
    guard cards[id] != nil else {
        // The card is made on a later turn than the lookup was asked for: wait for it.
        if tries > 0 { Task { @MainActor in openAnkiButton(id, tries: tries - 1) } }
        else { ankiSend(["event": "anki-button", "id": id, "state": "none", "message": ""]) }
        return
    }
    // A word with no dictionary entry, or a phrase whose translation failed: nothing to add.
    guard ankiNote(id) != nil else { ankiSend(["event": "anki-button", "id": id, "state": "none", "message": ""]); return }
    let model = AnkiButtonModel(note: { ankiNote(id) })
    ankiButtons[id] = model
    watchButton(id, model)
}

/// The note as the card stands now, with the meaning the reader sees.
@MainActor private func ankiNote(_ id: Int64) -> AnkiNote? {
    switch cards[id] {
    case .word(let s, _, _)?: return s.ankiNote
    case .phrase(let s, _, _)?: return s.ankiNote
    case nil: return nil
    }
}

/// Sends the button's state now, then again each time it changes, while the card is open.
@MainActor private func watchButton(_ id: Int64, _ model: AnkiButtonModel) {
    guard ankiButtons[id] === model else { return }
    _ = withObservationTracking { model.state } onChange: {
        Task { @MainActor in watchButton(id, model) }
    }
    sendButton(id, model)
}

@MainActor private func sendButton(_ id: Int64, _ model: AnkiButtonModel) {
    let (state, message): (String, String) = switch model.state {
    case .ready: ("ready", "")
    case .adding: ("adding", "")
    case .added: ("added", "")
    case .failed(let why): ("failed", why)
    }
    ankiSend(["event": "anki-button", "id": id, "state": state, "message": message])
}

/// The reader clicked the button: adds the note, or shows it in Anki once it's there.
@_cdecl("ly_anki_click")
public func ly_anki_click(_ id: Int64) {
    onAnkiMain { ankiButtons[id]?.click() }
}

/// The card closed: no more events for its button.
@_cdecl("ly_anki_close")
public func ly_anki_close(_ id: Int64) {
    onAnkiMain { ankiButtons[id] = nil }
}

private func onAnkiMain(_ body: @escaping @MainActor () -> Void) { Task { @MainActor in body() } }
