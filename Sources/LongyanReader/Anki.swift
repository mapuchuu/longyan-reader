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
    /// `changed` runs if the answer differs from the last one, so an open menu can catch up.
    func check(force: Bool = false, changed: (() -> Void)? = nil) {
        guard !checking, force || Date().timeIntervalSince(lastCheck) > 10 else { return }
        checking = true
        lastCheck = Date()
        Task {
            let names = try? await Self.call("deckNames", timeout: 2) as? [String]
            let before = (available, decks)
            available = names != nil
            if !available { ready = false }
            decks = Array((names ?? []).sorted().prefix(200))
            checking = false
            if before != (available, decks) { changed?() }
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
            do {
                try await prepare()
                return try await addNote(note)
            } catch AnkiError.anki(let message) where message.contains("model") || message.contains("deck") {
                // The note type or deck was deleted in Anki since: make them again, once.
                ready = false
                try await prepare()
                return try await addNote(note)
            }
        } catch let error as AnkiError where error.isDuplicate {
            // Anki compares the field without its formatting, so a note edited in Anki (a
            // trailing <br>, bold) is still the same word: find it that way.
            if let id = await edited(note.chinese) { return id }
            throw AnkiError.anki("it's already in the deck")
        }
    }

    /// The note for this Chinese whose field was edited in Anki: the same text once its
    /// formatting is taken off.
    private func edited(_ chinese: String) async -> Int? {
        let loose = [Self.quoted("deck:" + Self.deck), Self.quoted("note:" + Self.noteType),
                     "\"Chinese:*" + Self.escaped(Self.html(chinese)) + "*\""].joined(separator: " ")
        guard let ids = try? await Self.call("findNotes", ["query": loose]) as? [Int], !ids.isEmpty,
              let infos = try? await Self.call("notesInfo", ["notes": ids]) as? [[String: Any]] else { return nil }
        let target = Self.plain(Self.html(chinese))
        return infos.first { info in
            let fields = info["fields"] as? [String: [String: Any]]
            return (fields?["Chinese"]?["value"] as? String).map(Self.plain) == target
        }?["noteId"] as? Int
    }

    /// A field's text without tags, non-breaking spaces or surrounding space.
    private static func plain(_ field: String) -> String {
        field.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Older AnkiConnect answers a refused note (a duplicate) with no id and no error.
        guard let id = try await Self.call("addNote", params) as? Int else { throw AnkiError.notAdded }
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

    #if DEV_TOOLS
    /// Dev builds can talk to scripts/fake-ankiconnect.py on another port while Anki is open.
    nonisolated private static let endpoint = URL(string: "http://127.0.0.1:\(ProcessInfo.processInfo.environment["LONGYAN_ANKICONNECT_PORT"] ?? "8765")")!
    #else
    nonisolated private static let endpoint = URL(string: "http://127.0.0.1:8765")!
    #endif
    /// No cookies, no cache: nothing about these requests is kept.
    nonisolated private static let session = URLSession(configuration: .ephemeral)

    nonisolated private static func call(_ action: String, _ params: [String: Any] = [:], timeout: TimeInterval = 4) async throws -> Any? {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "version": 6, "params": params])
        let (data, _) = try await session.data(for: request)
        // Whatever answers on the port is only trusted so far: a reply this app could use is
        // small, and Anki's message is shown, so it's kept short.
        guard data.count < 1_000_000,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AnkiError.badReply }
        if let error = reply["error"] as? String { throw AnkiError.anki(String(error.prefix(160))) }
        return reply["result"]
    }

    /// Notes of this type in the deck whose Chinese is exactly `chinese`.
    private static func query(_ chinese: String) -> String {
        [quoted("deck:" + deck), quoted("note:" + noteType), quoted("Chinese:" + html(chinese))].joined(separator: " ")
    }

    /// A search term matched literally: quoted, with Anki's special characters escaped.
    private static func quoted(_ s: String) -> String { "\"" + escaped(s) + "\"" }
    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
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
    case notAdded
    case anki(String)

    var isDuplicate: Bool {
        switch self {
        case .notAdded: true
        case .anki(let message): message.contains("duplicate")
        case .badReply: false
        }
    }
}

/// One card's Anki button: whether its word is in Anki yet, and adding it.
@MainActor
final class AnkiButtonModel: ObservableObject {
    enum State: Equatable { case ready, adding, added(Int), failed(String) }
    @Published private(set) var state = State.ready
    /// The note as the card stands at the click, so a meaning the reader picked goes in.
    let note: () -> AnkiNote?
    private var reset: Task<Void, Never>?

    /// Shows why for 2.5 s, then the button is ready again.
    private func fail(_ why: String) {
        state = .failed(why)
        reset?.cancel()
        reset = Task {
            // A cancelled wait (a newer failure took over) must not clear that one's warning.
            guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
            if case .failed = state { state = .ready }
        }
    }

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
                    // No note at all means it failed: there's nothing to add.
                    var note = note(), waited = 0
                    while let n = note, n.meaning.isEmpty, waited < 100 {
                        try await Task.sleep(for: .milliseconds(200))
                        note = self.note()
                        waited += 1
                    }
                    guard let note, !note.meaning.isEmpty else { fail("There's no translation to add"); return }
                    state = .added(try await AnkiLink.shared.add(note))
                } catch AnkiError.anki(let message) {
                    fail("Anki said: \(message)")
                } catch {
                    fail("Anki didn't answer. Is it open?")
                }
            }
        }
    }
}
