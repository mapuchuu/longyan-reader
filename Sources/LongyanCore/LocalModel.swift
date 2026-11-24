import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, outside Apple's systems
#endif

/// A sense picker and translator backed by a local Qwen model: run inside the app with
/// llama.cpp when the model file is present (EmbeddedModel), otherwise served by Ollama
/// (http://127.0.0.1:11434) if that's running. Stronger than Apple's on-device 3B model at
/// telling close senses apart; without either, the app falls back to Apple's.
package enum LocalModel {
    package enum Backend { case embedded, ollama }
    /// LONGYAN_BACKEND=ollama forces Ollama (for comparing the two).
    package static var backend: Backend {
        if ProcessInfo.processInfo.environment["LONGYAN_BACKEND"] == "ollama" { return .ollama }
        return EmbeddedModel.modelPath != nil ? .embedded : .ollama
    }

    /// Which model to use: LONGYAN_MODEL, else the "senseModel" default, else qwen3.5:4b.
    /// "apple" turns it off. On the tests the 4B matched the 9B (51/52) with one wrong note
    /// to the 9B's none, at ~0.4 s and 2.9 GB instead of ~0.6 s and 4.5 GB.
    package static var name: String {
        ProcessInfo.processInfo.environment["LONGYAN_MODEL"]
            ?? UserDefaults.standard.string(forKey: "senseModel") ?? "qwen3.5:4b"
    }
    package static let choices: [(id: String, label: String)] = [
        ("qwen3.5:4b", "Qwen 3.5 4B (2.7 GB)"),
        ("apple", "Apple's Model Only"),
    ]

    package static func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: "senseModel")
        lastCheck = nil
    }
    package static var enabled: Bool { name != "apple" }

    private static let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    /// Whether Ollama answers and has the model, checked at most every 30 seconds. Checked
    /// from background tasks and read on the main thread, so the cache sits behind a lock.
    private static let lock = NSLock()
    private static var _lastCheck: (at: Date, ok: Bool)?
    private static var lastCheck: (at: Date, ok: Bool)? {
        get { lock.withLock { _lastCheck } }
        set { lock.withLock { _lastCheck = newValue } }
    }
    /// False where the app runs only its own copy of the model (Windows): no Ollama.
    nonisolated(unsafe) package static var ollamaAllowed = true

    package static func isAvailable() async -> Bool {
        guard enabled else { return false }
        // Too slow (Windows only): as if there were no model, without loading it.
        if !ollamaAllowed && EmbeddedModel.tooSlow {
            lastCheck = (Date(), false); note(EmbeddedModel.emulated ? .needsArm64 : .tooSlow); return false
        }
        if backend == .ollama && !ollamaAllowed { lastCheck = (Date(), false); return false }
        if backend == .embedded {
            let ok = !EmbeddedModel.fileUnloadable
            lastCheck = (Date(), ok); return ok
        }
        if let c = lastCheck, Date().timeIntervalSince(c.at) < 30 { return c.ok }
        var ok = false
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        req.timeoutInterval = 2   // a local server answers at once or not at all
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [[String: Any]] {
            ok = models.contains { ($0["name"] as? String) == name || ($0["model"] as? String) == name }
        }
        lastCheck = (Date(), ok)
        return ok
    }

    /// The last check's answer, without waiting: for deciding at once whether a card can
    /// expect a model pick. The app checks at launch, on Refresh and on each selection.
    static var lastKnownAvailable: Bool { enabled && lastCheck?.ok == true }

    /// Loads the model in the background (Ollama unloads it after five idle minutes), so a
    /// lookup that follows soon doesn't wait several seconds. Called when Chinese text is
    /// selected, while the reader moves to click.
    private static var _lastWarmUp: Date?
    package static func warmUp() {
        guard enabled else { return }
        guard ollamaAllowed || !EmbeddedModel.tooSlow else { return }
        if backend == .embedded {
            // A pick's instructions, then a translation's (where prefixes are primed: Windows).
            EmbeddedModel.shared.warmUp(systems: [chooseAllInstructions, translationInstructions + (promptV2 ? " " + keepWords : "")])
            checkWarmUp(); return
        }
        guard ollamaAllowed else { return }
        let due = lock.withLock {
            if let last = _lastWarmUp, Date().timeIntervalSince(last) < 60 { return false }
            _lastWarmUp = Date()
            return true
        }
        guard due else { return }
        Task.detached(priority: .utility) {
            guard await isAvailable() else { return }
            var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": name, "keep_alive": "5m", "options": ["num_ctx": 2048],
            ])
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    // MARK: Whether the built-in model works

    /// Why the built-in model can't run, as last seen: its file wouldn't load, or there was no
    /// memory for a context (the model tries again a minute later). Nil when it worked or
    /// hasn't been tried. Or this PC is too slow for it (Windows only), so it's never loaded;
    /// or it's an ARM PC running the x64 app, which needs the ARM version for the model.
    package enum Problem: String, Sendable {
        case unloadable, noMemory = "no-memory", tooSlow = "too-slow", needsArm64 = "needs-arm64"
        /// Why cards use dictionary order, when it's the PC.
        package var reason: String? {
            switch self {
            case .tooSlow: return "this PC is too slow for the reading model"
            case .needsArm64: return "the reading model needs the ARM version of Longyan Reader"
            default: return nil
            }
        }
    }
    private static var _problem: Problem?
    package static var problem: Problem? { lock.withLock { _problem } }
    /// Told of each change of `problem`, on any thread. Set by the Windows bridge.
    nonisolated(unsafe) package static var problemChanged: (@Sendable (Problem?) -> Void)?
    private static var checkingWarmUp = false

    /// After a new download: forget the last problem, without telling.
    package static func forgetProblem() { lock.withLock { _problem = nil } }

    private static func note(_ p: Problem?) {
        let changed = lock.withLock { () -> Bool in
            guard _problem != p else { return false }
            _problem = p
            return true
        }
        // A file that won't load stays that way: cards stop waiting for it.
        if p == .unloadable { lastCheck = (Date(), false) }
        if changed { problemChanged?(p) }
    }

    /// A request to the built-in model failed: was it the load?
    private static func note(_ error: Error) {
        let e = error as NSError
        guard e.domain == "LongyanReader", e.code == 7 else { return }
        if EmbeddedModel.fileUnloadable || e.localizedDescription.contains("couldn't load") { note(.unloadable) }
        else if e.localizedDescription.contains("couldn't create a context") { note(.noMemory) }
    }

    /// Whether a warm-up loaded the model, once it's done. memoryState() waits for the model's
    /// queue, so this waits on a dispatch thread, not one of Swift's. Only when someone listens.
    private static func checkWarmUp() {
        guard problemChanged != nil else { return }
        let start = lock.withLock { () -> Bool in
            if checkingWarmUp { return false }
            checkingWarmUp = true
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .utility).async {
            let loaded = EmbeddedModel.shared.memoryState().loaded
            lock.withLock { checkingWarmUp = false }
            if loaded { note(nil) }
            else if EmbeddedModel.tooSlow { note(EmbeddedModel.emulated ? .needsArm64 : .tooSlow) }
            else if EmbeddedModel.fileUnloadable { note(.unloadable) }
            else if EmbeddedModel.modelPath != nil { note(.noMemory) }
        }
    }

    /// A noted sense's plain definition (a note's first sentence). Glosses like "objection" or
    /// "rational" are too terse for the model to recognise 有意见 or 这不科学.
    static func noteHint(_ word: String, _ s: Sense) -> String {
        guard NotesStore.hasExactNote(word, s), let note = NotesStore.note(word, s)?.note else { return "" }
        return " (" + (note.split(whereSeparator: { ".?!".contains($0) }).first.map(String.init) ?? note) + ")"
    }

    /// Picks the sense of several words in one passage with a single request. Ollama serves
    /// one request at a time, so this is much quicker than asking word by word; the answer is
    /// just the sense numbers, in order, streamed so each word can be shown as soon as it's
    /// picked (`onPick` gets the word's position in `words` and its 1-based sense number).
    /// A word's pick is nil when the model gave no usable number for it (missing, or outside
    /// the list): that word is left unsettled rather than forced onto a sense.
    package static func chooseAll(passage: String, selectionMarked: Bool = false, words: [(word: String, senses: [Sense])],
                          onPick: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> [Int?] {
        guard !words.isEmpty else { return [] }
        let words = capped(words)
        // Answer time is nearly all output tokens (~14 ms each; reading the prompt is a few
        // tens of ms once cached), so the reply is one plain line, 等=2 和=1, about a third of
        // the tokens of the JSON object below (which Ollama pretty-prints). Writing each word
        // before its number matters: a bare [2, 1] array was as quick but scored 118/140
        // against 130/140 on real reading. The JSON form is the fallback when a line won't parse.
        // (A phrase of six words: 0.86 s → 0.31 s.)
        if ProcessInfo.processInfo.environment["LONGYAN_PICK_FORMAT"] != "keys" {
            do {
                return try await chooseAllOnOneLine(passage: passage, selectionMarked: selectionMarked, words: words, onPick: onPick)
            } catch {
                // A newer card cancelled this one: don't start the longer request too.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
            }
        }
        return try await chooseAllAsJSON(passage: passage, selectionMarked: selectionMarked, words: words, onPick: onPick)
    }

    private static let chooseAllInstructions = pickTerse ? """
    Pick each Chinese word's sense in the passage: give the number of the matching dictionary sense. Never invent one.
    """ : """
    You help an English speaker read Chinese. You get a Chinese passage and some of its words, each with numbered dictionary senses. \
    For each word, decide what it means in this passage and give the number of the matching sense. Never invent a sense.
    """

    // MARK: EXPERIMENT (exp/faster-picks): shorter pick prompts and rows one at a time.
    private static let env = ProcessInfo.processInfo.environment
    /// LONGYAN_PICK_SENSES=N: offer the model only a word's first N senses (dictionary order,
    /// which the card already uses), so numbering still matches the full list.
    static let pickSenseCap = env["LONGYAN_PICK_SENSES"].flatMap(Int.init)
    /// LONGYAN_PICK_NOEX=1: no example sentence after a sense.
    static let pickNoExamples = env["LONGYAN_PICK_NOEX"] == "1"
    /// LONGYAN_PICK_GLOSS=N: glosses cut to their first N "; "-separated parts.
    static let pickGlossParts = env["LONGYAN_PICK_GLOSS"].flatMap(Int.init)
    /// LONGYAN_PICK_CLEAN=1: no "(bound form)", "(Tw)" or pinyin cross-references like [yao4 shi5].
    static let pickClean = env["LONGYAN_PICK_CLEAN"] == "1"
    /// LONGYAN_PICK_PINYIN=auto: pinyin only on words whose senses don't all share it.
    static let pickPinyinAuto = env["LONGYAN_PICK_PINYIN"] == "auto"
    /// LONGYAN_PICK_PINYIN=change: pinyin only on a sense whose reading differs from the one before.
    static let pickPinyinChange = env["LONGYAN_PICK_PINYIN"] == "change"
    /// LONGYAN_PICK_TERSE=1: shorter instructions and lead-in.
    static let pickTerse = env["LONGYAN_PICK_TERSE"] == "1"
    /// LONGYAN_PICK_NONOTE=1: no note hint after a noted sense.
    static let pickNoNote = env["LONGYAN_PICK_NONOTE"] == "1"
    /// LONGYAN_PICK_PROGRESSIVE=1: the passage is read once, then each word is asked with its
    /// own short ending, from the saved state after the passage (EmbeddedModel.pickEach).
    static let pickProgressive = env["LONGYAN_PICK_PROGRESSIVE"] == "1"
    /// LONGYAN_PICK_PROGRESSIVE=chain: one request, but a turn per word: each word's senses are
    /// read only after the word before it is picked, so row 1 waits for the start and one word,
    /// and each later word still sees the earlier words and their answers.
    static let pickChain = env["LONGYAN_PICK_PROGRESSIVE"] == "chain"

    static func capped(_ words: [(word: String, senses: [Sense])]) -> [(word: String, senses: [Sense])] {
        guard let n = pickSenseCap, n > 0 else { return words }
        return words.map { ($0.word, Array($0.senses.prefix(n))) }
    }

    static func shortGloss(_ g: String) -> String {
        var g = g
        if pickClean {
            for p in [#"\[[^\]]*\]"#, #"\((bound form|Tw|Taiwan pr\.[^)]*)\)\s*"#] {
                g = g.replacingOccurrences(of: p, with: "", options: .regularExpression)
            }
            g = g.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        guard let n = pickGlossParts, n > 0 else { return g }
        let parts = g.components(separatedBy: "; ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? g : parts.prefix(n).joined(separator: "; ")
    }

    /// The request's text: the passage, then each word under its label with its numbered senses.
    private static func chooseAllPrompt(_ passage: String, _ selectionMarked: Bool, _ words: [(word: String, senses: [Sense])],
                                        labels: [String]) -> String {
        chooseAllLead(passage, selectionMarked) + words.enumerated().map { n, w in wordBlock(w, label: labels[n]) }.joined(separator: "\n\n")
    }

    /// The part of a pick's request before the words: the same for every word of a card.
    static func chooseAllLead(_ passage: String, _ selectionMarked: Bool) -> String {
        if pickTerse {
            return "Passage: \(passage)\n" + (selectionMarked ? "Selected: the part in 【】.\n" : "") + "\n"
        }
        return "Passage: \(passage)\n" + (selectionMarked ? "The reader selected the part in 【】.\n" : "")
            + "For each word, give the number of the sense it has in this passage.\n\n"
    }

    static func wordBlock(_ w: (word: String, senses: [Sense]), label: String) -> String {
        let onePinyin = pickPinyinAuto && Set(w.senses.map { $0.pinyin.lowercased() }).count == 1
        let list = w.senses.enumerated().map { i, s -> String in
            let sameAsBefore = pickPinyinChange && i > 0 && w.senses[i - 1].pinyin.lowercased() == s.pinyin.lowercased()
            var line = "  \(i + 1). " + (onePinyin || sameAsBefore ? "" : "[\(Pinyin.marked(s.pinyin))] ") + shortGloss(s.gloss)
                + (pickNoNote ? "" : noteHint(w.word, s))
            let ex = pickNoExamples ? [] : ExamplesStore.examples(w.word, s).prefix(1)
            if !ex.isEmpty { line += "  e.g. " + ex.joined(separator: " ") }
            return line
        }
        return "\(label): \(w.word)\n" + list.joined(separator: "\n")
    }

    private static func chooseAllBody(_ user: String, options: [String: Any], format: [String: Any]? = nil) -> [String: Any] {
        var body: [String: Any] = [
            "model": name, "think": false, "options": options, "keep_alive": "5m",
            "messages": [["role": "system", "content": chooseAllInstructions], ["role": "user", "content": user]],
        ]
        if let format { body["format"] = format }
        return body
    }

    private static func unexpected(_ text: String) -> NSError {
        NSError(domain: "LongyanReader", code: 5, userInfo: [NSLocalizedDescriptionKey: "local model: unexpected reply \(text.prefix(200))"])
    }

    private static func chooseAllOnOneLine(passage: String, selectionMarked: Bool, words: [(word: String, senses: [Sense])],
                                           onPick: @MainActor (Int, Int) -> Void) async throws -> [Int?] {
        let labels = words.indices.map { "w\($0 + 1)" }
        let user = chooseAllPrompt(passage, selectionMarked, words, labels: labels)
            + (pickTerse ? "\n\nReply on one line, like: " : "\n\nReply on one line with each word and its sense number, in order, like: ")
            + words.prefix(2).enumerated().map { "\($1.word)=\($0 + 1)" }.joined(separator: " ")
        if env["LONGYAN_PICK_DUMP"] == "1" { FileHandle.standardError.write(Data("PROMPT\n\(user)\nEND\n".utf8)) }
        // A cap, so a reply that wanders off can't run on.
        let body = chooseAllBody(user, options: ["temperature": 0, "num_ctx": 2048, "num_predict": 8 * words.count + 8])
        // Each word, then its number, read in order from where the last one ended. A number
        // still being written (nothing after it yet) isn't taken until the reply is complete.
        // Returns, per word, nil until its number is read, then .some(nil) for a number
        // outside the list or .some(n) for a sense.
        func read(_ text: String, final: Bool) -> [Int??] {
            var out = [Int??](repeating: nil, count: words.count)
            var rest = Substring(text)
            for (i, w) in words.enumerated() {
                guard let r = rest.range(of: w.word) else { break }
                let after = rest[r.upperBound...].drop { $0 == "=" || $0 == " " || $0 == ":" }
                let digits = after.prefix { $0.isNumber }
                guard !digits.isEmpty, final || digits.endIndex < after.endIndex, let n = Int(digits) else { break }
                out[i] = .some((1...w.senses.count).contains(n) ? n : nil)
                rest = after[digits.endIndex...]
            }
            return out
        }
        if usesScoring && pickChain {
            let reply = { (w: String) in pickTerse ? "\n\nReply like: \(w)=1" : "\n\nReply on one line with each word and its sense number, in order, like: \(w)=1" }
            let first = chooseAllLead(passage, selectionMarked) + wordBlock(words[0], label: "w1") + reply(words[0].word)
            let messages = [["role": "system", "content": chooseAllInstructions], ["role": "user", "content": first]]
            let steps = words.enumerated().map { i, w -> String in
                i == 0 ? w.word + "=" : "<|im_end|>\n<|im_start|>user\n" + wordBlock(w, label: "w1") + reply(w.word)
                    + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n" + w.word + "="
            }
            return try await pickByScoring(["messages": messages], words: words, steps: steps, onPick: onPick)
        }
        if usesScoring && pickProgressive {
            return try await pickProgressively(passage: passage, selectionMarked: selectionMarked, words: words, onPick: onPick)
        }
        if usesScoring {
            return try await pickByScoring(body, words: words,
                                           steps: words.enumerated().map { ($0 == 0 ? "" : " ") + $1.word + "=" },
                                           onPick: onPick)
        }
        var picked = [Bool](repeating: false, count: words.count)
        let text = try await stream(body) { text in
            for (i, n) in read(text, final: false).enumerated() where !picked[i] {
                if let n { picked[i] = true; if let n { onPick(i, n) } }
            }
        }
        let picks = read(text, final: true)
        guard picks.allSatisfy({ $0 != nil }) else { throw unexpected(text) }
        // The last number has nothing after it, so it's only certain now.
        for (i, n) in picks.enumerated() where !picked[i] { if let n = n! { await onPick(i, n) } }
        return picks.map { $0! }
    }

    private static func chooseAllAsJSON(passage: String, selectionMarked: Bool, words: [(word: String, senses: [Sense])],
                                        onPick: @MainActor (Int, Int) -> Void) async throws -> [Int?] {
        // Zero-padded so that sorted keys (in `stream`) keep the words in order: w01, w02, … w10.
        let keys = words.indices.map { String(format: "w%02d", $0 + 1) }
        var props: [String: Any] = [:]
        for k in keys { props[k] = ["type": "integer"] }
        let body = chooseAllBody(chooseAllPrompt(passage, selectionMarked, words, labels: keys),
                                 options: ["temperature": 0, "num_ctx": 2048],
                                 format: ["type": "object", "properties": props, "required": keys])
        // Laid out the way the model writes it: {\n  "w01": 3\n}
        if usesScoring {
            return try await pickByScoring(body, words: words,
                                           steps: keys.enumerated().map { ($0 == 0 ? "{\n  \"" : ",\n  \"") + $1 + "\": " },
                                           onPick: onPick)
        }
        func valid(_ i: Int, _ n: Int?) -> Int? { n.flatMap { (1...words[i].senses.count).contains($0) ? $0 : nil } }
        var picks = [Int?](repeating: nil, count: words.count)
        let text = try await stream(body) { text in
            // A number is complete once something follows it.
            for m in text.matches(of: #/"w(\d+)"\s*:\s*(\d+)\s*[,}\s]/#) {
                guard let k = Int(m.1), words.indices.contains(k - 1), picks[k - 1] == nil,
                      let pick = valid(k - 1, Int(m.2)) else { continue }
                picks[k - 1] = pick
                onPick(k - 1, pick)
            }
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw unexpected(text) }
        return words.indices.map { i in picks[i] ?? valid(i, parsed[keys[i]] as? Int) }
    }

    /// With the built-in model, picks are read from the model's odds instead of a written
    /// reply (EmbeddedModel.pick): the same prompt and answer format, one model pass per word
    /// instead of one per token. LONGYAN_PICK=generate writes the reply, for comparison.
    static var usesScoring: Bool {
        backend == .embedded && ProcessInfo.processInfo.environment["LONGYAN_PICK"] != "generate"
    }

    private static func pickByScoring(_ body: [String: Any], words: [(word: String, senses: [Sense])], steps: [String],
                                      onPick: @MainActor (Int, Int) -> Void) async throws -> [Int?] {
        var picks: [Int?] = []
        let messages = body["messages"] as? [[String: String]] ?? []
        do {
            for try await p in EmbeddedModel.shared.pick(messages: messages, steps: zip(steps, words).map { ($0, $1.senses.count) }) {
                try Task.checkCancellation()
                let i = picks.count
                record(words[i].word, p.number, p.confidence)
                picks.append(p.number)
                await onPick(i, p.number)
            }
        } catch { note(error); throw error }
        note(nil)
        guard picks.count == words.count else { throw unexpected("\(picks.count) of \(words.count) picks") }
        return picks
    }

    /// EXPERIMENT: each word asked on its own, as a one-word pick that shares the card's start
    /// (instructions and passage), which is read once. Row 1 waits for that start and its own
    /// ending only; each later row for its own ending.
    private static func pickProgressively(passage: String, selectionMarked: Bool, words: [(word: String, senses: [Sense])],
                                          onPick: @MainActor (Int, Int) -> Void) async throws -> [Int?] {
        let system = "<|im_start|>system\n\(chooseAllInstructions)<|im_end|>\n"
        // LONGYAN_PICK_WORDLIST=1: the start also names every word the card asks about.
        let list = env["LONGYAN_PICK_WORDLIST"] == "1" && words.count > 1
            ? "Words: " + words.map(\.word).joined(separator: " ") + "\n\n" : ""
        let prefix = system + "<|im_start|>user\n" + chooseAllLead(passage, selectionMarked) + list
        let items = words.map { w -> (text: String, count: Int) in
            let ending = wordBlock(w, label: "w1") + (pickTerse ? "\n\nReply like: \(w.word)=1"
                : "\n\nReply on one line with each word and its sense number, in order, like: \(w.word)=1")
            return (ending + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n" + w.word + "=", w.senses.count)
        }
        var picks: [Int?] = []
        do {
            for try await p in EmbeddedModel.shared.pickEach(prefix: prefix, systemEnd: system, items: items) {
                try Task.checkCancellation()
                let i = picks.count
                record(words[i].word, p.number, p.confidence)
                picks.append(p.number)
                await onPick(i, p.number)
            }
        } catch { note(error); throw error }
        note(nil)
        guard picks.count == words.count else { throw unexpected("\(picks.count) of \(words.count) picks") }
        return picks
    }

    /// How sure the model was of its latest pick for each word (0…1), for the evals' calibration
    /// lines. Only scoring picks have one.
    private static var confidences: [String: (number: Int, confidence: Double)] = [:]
    private static func record(_ word: String, _ n: Int, _ p: Double) { lock.withLock { confidences[word] = (n, p) } }
    package static func confidence(_ word: String, picked n: Int) -> Double? {
        lock.withLock { confidences[word].flatMap { $0.number == n ? $0.confidence : nil } }
    }

    static let translationInstructions = """
    You translate Chinese into natural, idiomatic English for a learner. Keep the meaning, tone and any slang or idiom \
    (translate its sense, not its characters). Reply with the English translation only.
    """

    /// EXPERIMENT (LONGYAN_PROMPT2=1): small words small models drop, and the subject they guess.
    static let promptV2 = ProcessInfo.processInfo.environment["LONGYAN_PROMPT2"] == "1"
    static let keepWords = "Keep the small words that change the meaning, such as 才 (only then), 都 (even, all), 又 (again), 却 (yet) and 也 (also). If the part has no subject, take it from the surrounding text; don't assume I or you."

    private static func contextPrompt(_ context: String, _ part: String) -> String {
        "Surrounding text: \(context)\nTranslate only this part of it: \(part)"
    }

    /// Fragments cut mid-clause, answered with just the fragment's English.
    private static let contextExamples = [
        ("他说话很客气，不过脾气很差，大家都怕他。", "不过脾气", "but his temper"),
        ("我们到了以后，经理让我们各自填一张表。", "经理让我们各自", "the manager had each of us"),
    ]

    /// A natural English translation, streamed: `partial` gets the text so far. Better than
    /// Apple's translator on slang and idioms (内卷 "involution", not "internal entanglement";
    /// 小意思 "a small token", not "a little interesting").
    /// `context` is the text the selection sits in; given it, only the selection is translated,
    /// but read the way the sentence means it (a clipped 别办入职 was "gender certificate").
    /// With `dict`, the built-in model can't use English words that only the sentence's other
    /// words mean (OutsideWords), and stops where its next word would be one once the
    /// selection is all said: 4B kept finishing the clause (卷了，我想 "…I want to lie flat").
    /// The card shows the translation as plain text, so markdown the model adds (it puts
    /// *…* round a 《》 title) would show as asterisks: they go, unless the Chinese had them
    /// too. A sentence that ends in 。 doesn't end its English on a comma.
    static func tidied(_ english: String, source: String, final: Bool) -> String {
        var t = english
        if !source.contains("*") {
            t = t.replacingOccurrences(of: #"\*\*(?=\S)([^*\n]+?)(?<=\S)\*\*"#, with: "$1", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "$1", options: .regularExpression)
        }
        if !source.contains("_") {
            t = t.replacingOccurrences(of: #"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#, with: "$1", options: .regularExpression)
        }
        if final, source.range(of: #"[。！？!?.]["”’」』）)]*\s*$"#, options: .regularExpression) != nil {
            t = t.replacingOccurrences(of: #",(["”’]?)\s*$"#, with: ".$1", options: .regularExpression)
        }
        return t
    }

    package static func translate(_ text: String, context: String? = nil, dict: CEDict? = nil,
                          partial: @MainActor (String) -> Void = { _ in }) async throws -> String {
        var messages = [["role": "system", "content": translationInstructions + (promptV2 ? " " + keepWords : "")]]
        if let context {
            // Told only to translate the part, the 4B model still translated the whole sentence
            // about a third of the time; two worked examples stop that (real reading: 22/52 →
            // 44/52), and cost almost nothing, since Ollama reuses the cached prompt prefix.
            for (c, part, english) in contextExamples {
                messages.append(["role": "user", "content": contextPrompt(c, part)])
                messages.append(["role": "assistant", "content": english])
            }
            var prompt = contextPrompt(context, text)
            if let note = IdiomHints.note(for: text, dict: dict) { prompt += "\n" + note }   // EXPERIMENT
            messages.append(["role": "user", "content": prompt])
        } else {
            messages.append(["role": "user", "content": text])
        }
        let ended = StopFlag()
        var outsideWords: Set<String> = []
        var body: [String: Any] = [
            "model": name, "think": false,
            "options": ["temperature": 0, "num_ctx": 2048],
            "keep_alive": "5m",
            "messages": messages,
        ]
        if let context, let dict, ProcessInfo.processInfo.environment["LONGYAN_NO_BAN"] == nil {
            let (banned, outside) = OutsideWords.lists(part: text, context: context, dict: dict)
            outsideWords = outside
            if ProcessInfo.processInfo.environment["LONGYAN_BAN_LOG"] == "1" {
                FileHandle.standardError.write(Data("ban \(text): \(banned.joined(separator: " "))\n".utf8))
            }
            body["banned"] = banned
            let covers = OutsideWords.coverage(part: text, dict: dict), cut = ended
            body["endsAt"] = { @Sendable (s: String) -> Bool in
                guard covers(s) else { return false }
                cut.set()
                return true
            }
        }
        let banning = !(body["banned"] as? [String] ?? []).isEmpty
        let out = try await stream(body) { partial(tidied(banning ? clipped($0, cut: false) : $0.trimmingCharacters(in: .whitespacesAndNewlines), source: text, final: false)) }
        let t = tidied(banning ? clipped(out, cut: ended.isSet, outside: outsideWords) : out.trimmingCharacters(in: .whitespacesAndNewlines), source: text, final: true)
        guard !t.isEmpty else { throw NSError(domain: "LongyanReader", code: 6, userInfo: [NSLocalizedDescriptionKey: "empty translation"]) }
        // With context it now and then answers in Chinese (胜任或轻视这份工作); alone it doesn't.
        if context != nil, t.contains(where: isCJK) { return try await translate(text, partial: partial) }
        return t
    }

    /// A reply written around kept-out words, tidied: its first line only (blocked from its
    /// next word, the model now and then starts over on a new line), and no word left hanging
    /// at the end: an article; a joining word when it stopped at a kept-out word (东西又便宜
    /// "the items are both cheap and", the "delicious" being 好吃's); a word only the outside
    /// words' glosses have, then the "to" before it (催我早点 "urged me to get", the "married"
    /// being 结婚's).
    static func clipped(_ reply: String, cut: Bool, outside: Set<String> = []) -> String {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let nl = t.firstIndex(where: \.isNewline) { t = String(t[..<nl]) }
        var dangling: Set<String> = cut ? ["a", "an", "the", "and", "but", "or"] : ["a", "an", "the"]
        var words = t.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while words.count > 1, let last = words.last?.lowercased() {
            if outside.contains(OutsideWords.stem(last)) { dangling.insert("to") }
            else if !dangling.contains(last) { break }
            words.removeLast()
        }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Runs a chat request with streaming on; `onText` gets the reply so far after each piece.
    private static func stream(_ body: [String: Any], onText: @MainActor (String) -> Void) async throws -> String {
        if backend == .embedded {
            let options = body["options"] as? [String: Any] ?? [:]
            let keys = (body["format"] as? [String: Any])?["required"] as? [String]
            var text = ""
            do {
                for try await t in EmbeddedModel.shared.stream(messages: body["messages"] as? [[String: String]] ?? [],
                                                               maxTokens: options["num_predict"] as? Int,
                                                               grammar: keys.map(EmbeddedModel.jsonGrammar),
                                                               banned: body["banned"] as? [String] ?? [],
                                                               endsAt: body["endsAt"] as? @Sendable (String) -> Bool) {
                    try Task.checkCancellation()
                    if t != text { text = t; await onText(text) }
                }
            } catch { note(error); throw error }
            note(nil)
            return text
        }
        #if canImport(Darwin)
        var body = body
        body["stream"] = true
        body["banned"] = nil; body["endsAt"] = nil   // built-in model only
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // Sorted keys keep schema properties in order, so the model answers them in order.
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        req.timeoutInterval = 60
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "LongyanReader", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "local model: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
        }
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let piece = (obj["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                text += piece
                await onText(text)
            }
            if obj["done"] as? Bool == true {
                // LONGYAN_TIMING=1: where a request's time went (prompt reading vs. answering).
                if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
                    let ms = { (k: String) in ((obj[k] as? Double) ?? 0) / 1_000_000 }
                    FileHandle.standardError.write(Data(String(format: "timing: prompt %d tok %.0f ms, answer %d tok %.0f ms, total %.0f ms\n",
                        obj["prompt_eval_count"] as? Int ?? 0, ms("prompt_eval_duration"),
                        obj["eval_count"] as? Int ?? 0, ms("eval_duration"), ms("total_duration")).utf8))
                }
                break
            }
        }
        return text
        #else
        // Streaming a reply needs URLSession's byte stream, which only Apple's Foundation has.
        throw NSError(domain: "LongyanReader", code: 5, userInfo: [NSLocalizedDescriptionKey: "Ollama isn't supported on this platform"])
        #endif
    }

    /// One word's sense, asked the way a phrase card asks: on casual uses this picked better
    /// than a dedicated prompt with the model's own wording first (27/30 against 22/30). The
    /// passage marks the word and keeps the text around it, which can decide the sense.
    static func choose(_ context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        // The JSON form here: for one word the one-line reply saves only ~0.1 s, and the card
        // is prepared while the reader moves to click, while JSON scored a little better
        // (real reading 36/39 against 34/39).
        guard let n = try await chooseAllAsJSON(passage: context.markedPassage, selectionMarked: false,
                                                words: capped([(context.word, senses)]), onPick: { _, _ in }).first ?? nil
        else { throw NoSenseFits() }
        return SenseChoice(senseNumber: n, meaningHere: headlineGloss(senses[n - 1]))
    }
}

/// The model answered, but with no sense from the list: the word is left in dictionary order
/// rather than matched some other way.
package struct NoSenseFits: LocalizedError {
    package var errorDescription: String? { "none of the dictionary's meanings was picked" }
}
