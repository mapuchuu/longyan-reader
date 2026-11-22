import AppKit

/// What a card adds to Anki. Fields are plain text; `sentence` may mark the word with 【】.
struct AnkiNote {
    var chinese: String
    var pinyin = ""
    var meaning: String
    var sentence = ""
    var dictionary = ""
    var note = ""
}

/// Adds cards to Anki through AnkiConnect, the add-on that answers on 127.0.0.1:8765 while
/// Anki is open. There's nothing to set up: a card shows its Anki button only while
/// AnkiConnect answers, and the first card added creates the note type and the deck. Nothing
/// leaves the Mac.
@MainActor
final class AnkiLink {
    static let shared = AnkiLink()

    static let noteType = "Longyan Reader"
    static let defaultDeck = "Longyan Reader"
    private static let deckKey = "ankiDeck"
    static var deck: String {
        get { UserDefaults.standard.string(forKey: deckKey) ?? defaultDeck }
        set { UserDefaults.standard.set(newValue, forKey: deckKey); shared.ready = false }   // the new deck may not exist yet
    }

    /// Whether AnkiConnect answered the last check. A card takes this when it opens, so its
    /// buttons never shift while it's up.
    private(set) var available = false
    /// Anki's decks, from the last check, for the Anki Deck menu.
    private(set) var decks: [String] = []
    private var lastCheck = Date.distantPast
    private var checking = false
    /// Set once the note type and deck are known to exist this session.
    private var ready = false

    /// Asks AnkiConnect whether it's there: at launch, when the eye appears and when the menu
    /// opens, at most every 10 s. Without Anki the connection is refused at once.
    func check() {
        guard !checking, Date().timeIntervalSince(lastCheck) > 10 else { return }
        checking = true
        lastCheck = Date()
        Task {
            let names = try? await Self.call("deckNames", timeout: 2) as? [String]
            available = names != nil
            if !available { ready = false }
            decks = (names ?? []).sorted()
            checking = false
        }
    }

    /// The note already in the deck for this Chinese, if there is one.
    func existing(_ chinese: String) async -> Int? {
        let ids = try? await Self.call("findNotes", ["query": Self.query(chinese)]) as? [Int]
        return ids?.first
    }

    /// Adds the note, or finds the one already there, and returns its id.
    func add(_ note: AnkiNote) async throws -> Int {
        if let id = await existing(note.chinese) { return id }
        do {
            try await prepare()
            return try await addNote(note)
        } catch AnkiError.anki(let message) where message.contains("model") || message.contains("deck") {
            // The note type or deck was deleted in Anki since: make them again, once.
            ready = false
            try await prepare()
            return try await addNote(note)
        }
    }

    /// Opens Anki's browser on the note.
    func show(_ id: Int) {
        Task { _ = try? await Self.call("guiBrowse", ["query": "nid:\(id)"]) }
    }

    private func addNote(_ note: AnkiNote) async throws -> Int {
        let fields = [
            "Chinese": Self.html(note.chinese),
            "Pinyin": Self.html(note.pinyin),
            "Meaning": Self.html(note.meaning),
            // The word in bold where it is in the sentence, not wherever it first appears.
            "Sentence": Self.html(note.sentence).replacingOccurrences(of: "【" + Self.html(note.chinese) + "】",
                                                                      with: "<b>" + Self.html(note.chinese) + "</b>"),
            "Dictionary": Self.html(note.dictionary),
            "Note": Self.html(note.note),
        ]
        let params: [String: Any] = ["note": [
            "deckName": Self.deck, "modelName": Self.noteType, "fields": fields, "tags": ["longyan"],
            "options": ["allowDuplicate": false, "duplicateScope": "deck"],
        ]]
        guard let id = try await Self.call("addNote", params) as? Int else { throw AnkiError.badReply }
        return id
    }

    /// Makes the note type and the deck if they aren't there yet.
    private func prepare() async throws {
        guard !ready else { return }
        let types = try await Self.call("modelNames") as? [String] ?? []
        if !types.contains(Self.noteType) {
            _ = try await Self.call("createModel", [
                "modelName": Self.noteType,
                "inOrderFields": ["Chinese", "Pinyin", "Meaning", "Sentence", "Dictionary", "Note"],
                "css": Self.css,
                "cardTemplates": [["Name": "Recognition", "Front": Self.front, "Back": Self.back]],
            ])
        }
        _ = try await Self.call("createDeck", ["deck": Self.deck])   // returns the existing deck if there is one
        ready = true
    }

    // MARK: AnkiConnect

    nonisolated private static let endpoint = URL(string: "http://127.0.0.1:8765")!
    /// No cookies, no cache: nothing about these requests is kept.
    nonisolated private static let session = URLSession(configuration: .ephemeral)

    nonisolated private static func call(_ action: String, _ params: [String: Any] = [:], timeout: TimeInterval = 4) async throws -> Any? {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
        let (data, _) = try await session.data(for: request)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AnkiError.badReply }
        if let error = reply["error"] as? String { throw AnkiError.anki(error) }
        return reply["result"]
    }

    /// Notes of this type in the deck whose Chinese is exactly `chinese`.
    private static func query(_ chinese: String) -> String {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_") + "\""
        }
        return [quoted("deck:" + deck), quoted("note:" + noteType), quoted("Chinese:" + html(chinese))].joined(separator: " ")
    }

    private static func html(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
    }

    // MARK: The note type

    /// The Chinese on the front; on the back its pinyin, the meaning it had, the sentence with
    /// the word in bold, the note and the dictionary's wording: the export's cards, laid out.
    private static let front = #"<div class="zh">{{Chinese}}</div>"#
    private static let back = """
        {{FrontSide}}
        <hr id="answer">
        {{#Pinyin}}<div class="py">{{Pinyin}}</div>{{/Pinyin}}
        <div class="meaning">{{Meaning}}</div>
        {{#Sentence}}<div class="sentence">{{Sentence}}</div>{{/Sentence}}
        {{#Note}}<div class="note">{{Note}}</div>{{/Note}}
        {{#Dictionary}}<div class="dict">{{Dictionary}}</div>{{/Dictionary}}
        """
    private static let css = """
        .card { font-family: -apple-system, "PingFang SC", "Helvetica Neue", sans-serif; font-size: 18px;
          line-height: 1.45; text-align: center; color: #1d1d1f; background: #fff; }
        .card.nightMode { color: #f2f2f2; background: #1f1f21; }
        .zh { font-size: 44px; font-weight: 500; }
        .py { font-size: 20px; color: #6e6e73; }
        .meaning { margin-top: 4px; font-size: 22px; font-weight: 600; }
        .sentence { margin-top: 16px; font-size: 20px; }
        .note { max-width: 30em; margin: 16px auto 0; font-size: 15px; color: #6e6e73; text-align: left; }
        .dict { margin-top: 12px; font-size: 13px; color: #8e8e93; }
        .nightMode .py, .nightMode .note { color: #a1a1a6; }
        """
}

enum AnkiError: Error {
    case badReply
    case anki(String)
}

/// One card's Anki button: whether its word is in Anki yet, and adding it.
@MainActor
final class AnkiButtonModel: ObservableObject {
    enum State: Equatable { case ready, adding, added(Int), failed(String) }
    @Published private(set) var state = State.ready
    /// The note as the card stands at the click, so a meaning the reader picked goes in.
    let note: () -> AnkiNote?
    private var reset: Task<Void, Never>?

    init(note: @escaping () -> AnkiNote?) {
        self.note = note
        // Already in the deck: the button opens as "In Anki".
        guard let chinese = note()?.chinese else { return }
        Task { if let id = await AnkiLink.shared.existing(chinese), state == .ready { state = .added(id) } }
    }

    func click() {
        switch state {
        case .adding: return
        case .added(let id): AnkiLink.shared.show(id)
        case .ready, .failed:
            state = .adding
            Task {
                do {
                    // A phrase's translation may still be on its way: wait for it, up to 20 s.
                    var note = note(), waited = 0
                    while let n = note, n.meaning.isEmpty, waited < 100 {
                        try await Task.sleep(for: .milliseconds(200))
                        note = self.note()
                        waited += 1
                    }
                    guard let note, !note.meaning.isEmpty else { state = .ready; return }
                    state = .added(try await AnkiLink.shared.add(note))
                } catch {
                    if case AnkiError.anki(let message) = error { state = .failed("Anki said: \(message)") }
                    else { state = .failed("Anki didn't answer. Is it open?") }
                    reset?.cancel()
                    reset = Task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if case .failed = state { state = .ready }
                    }
                }
            }
        }
    }
}
