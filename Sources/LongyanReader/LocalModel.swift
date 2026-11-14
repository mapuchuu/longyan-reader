import Foundation

/// A sense picker backed by a local model served by Ollama (http://127.0.0.1:11434).
/// Stronger than Apple's on-device 3B model at telling close senses apart; used when
/// Ollama is running and the model is installed, otherwise the app falls back.
enum LocalModel {
    /// Which model to use: LONGYAN_MODEL, else the "senseModel" default, else qwen3.5:4b.
    /// "apple" turns it off. On the tests the 4B matched the 9B (51/52) with one wrong note
    /// to the 9B's none, at ~0.4 s and 2.9 GB instead of ~0.6 s and 4.5 GB.
    static var name: String {
        ProcessInfo.processInfo.environment["LONGYAN_MODEL"]
            ?? UserDefaults.standard.string(forKey: "senseModel") ?? "qwen3.5:4b"
    }
    static let choices: [(id: String, label: String)] = [
        ("qwen3.5:4b", "Qwen 3.5 4B: lighter (2.9 GB, ~0.4 s)"),
        ("apple", "Apple on-device model only"),
    ]

    static func select(_ id: String) {
        UserDefaults.standard.set(id, forKey: "senseModel")
        lastCheck = nil
    }
    static var enabled: Bool { name != "apple" }

    private static let endpoint = URL(string: "http://127.0.0.1:11434/api/chat")!

    /// Whether Ollama answers and has the model, checked at most every 30 seconds.
    private static var lastCheck: (at: Date, ok: Bool)?
    static func isAvailable() async -> Bool {
        guard enabled else { return false }
        if let c = lastCheck, Date().timeIntervalSince(c.at) < 30 { return c.ok }
        var ok = false
        if let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:11434/api/tags")!),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [[String: Any]] {
            ok = models.contains { ($0["name"] as? String) == name || ($0["model"] as? String) == name }
        }
        lastCheck = (Date(), ok)
        return ok
    }

    /// Loads the model in the background (Ollama unloads it after five idle minutes), so a
    /// lookup that follows soon doesn't wait several seconds. Called when Chinese text is
    /// selected, while the reader moves to click.
    private static var lastWarmUp: Date?
    static func warmUp() {
        guard enabled else { return }
        if let last = lastWarmUp, Date().timeIntervalSince(last) < 60 { return }
        lastWarmUp = Date()
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
    static func chooseAll(passage: String, selectionMarked: Bool = false, words: [(word: String, senses: [Sense])],
                          onPick: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> [Int] {
        guard !words.isEmpty else { return [] }
        // Answer time is nearly all output tokens (~14 ms each; reading the prompt is a few
        // tens of ms once cached), so the reply is one plain line, 等=2 和=1, about a third of
        // the tokens of the JSON object below (which Ollama pretty-prints). Writing each word
        // before its number matters: a bare [2, 1] array was as quick but scored 118/140
        // against 130/140 on real reading. The JSON form is the fallback when a line won't parse.
        // (A phrase of six words: 0.86 s → 0.31 s.)
        if ProcessInfo.processInfo.environment["LONGYAN_PICK_FORMAT"] != "keys",
           let picks = try? await chooseAllOnOneLine(passage: passage, selectionMarked: selectionMarked, words: words, onPick: onPick) {
            return picks
        }
        return try await chooseAllAsJSON(passage: passage, selectionMarked: selectionMarked, words: words, onPick: onPick)
    }

    private static let chooseAllInstructions = """
    You help an English speaker read Chinese. You get a Chinese passage and some of its words, each with numbered dictionary senses. \
    For each word, decide what it means in this passage and give the number of the matching sense. Never invent a sense.
    """

    /// The request's text: the passage, then each word under its label with its numbered senses.
    private static func chooseAllPrompt(_ passage: String, _ selectionMarked: Bool, _ words: [(word: String, senses: [Sense])],
                                        labels: [String]) -> String {
        let blocks = words.enumerated().map { n, w -> String in
            let list = w.senses.enumerated().map { i, s -> String in
                var line = "  \(i + 1). [\(Pinyin.marked(s.pinyin))] \(s.gloss)" + noteHint(w.word, s)
                let ex = ExamplesStore.examples(w.word, s).prefix(1)
                if !ex.isEmpty { line += "  e.g. " + ex.joined(separator: " ") }
                return line
            }
            return "\(labels[n]): \(w.word)\n" + list.joined(separator: "\n")
        }
        return "Passage: \(passage)\n" + (selectionMarked ? "The reader selected the part in 【】.\n" : "")
            + "For each word, give the number of the sense it has in this passage.\n\n" + blocks.joined(separator: "\n\n")
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
                                           onPick: @MainActor (Int, Int) -> Void) async throws -> [Int] {
        let labels = words.indices.map { "w\($0 + 1)" }
        let user = chooseAllPrompt(passage, selectionMarked, words, labels: labels)
            + "\n\nReply on one line with each word and its sense number, in order, like: "
            + words.prefix(2).enumerated().map { "\($1.word)=\($0 + 1)" }.joined(separator: " ")
        // A cap, so a reply that wanders off can't run on.
        let body = chooseAllBody(user, options: ["temperature": 0, "num_ctx": 2048, "num_predict": 8 * words.count + 8])
        // Each word, then its number, read in order from where the last one ended. A number
        // still being written (nothing after it yet) isn't taken until the reply is complete.
        func read(_ text: String, final: Bool) -> [Int?] {
            var out = [Int?](repeating: nil, count: words.count)
            var rest = Substring(text)
            for (i, w) in words.enumerated() {
                guard let r = rest.range(of: w.word) else { break }
                let after = rest[r.upperBound...].drop { $0 == "=" || $0 == " " || $0 == ":" }
                let digits = after.prefix { $0.isNumber }
                guard !digits.isEmpty, final || digits.endIndex < after.endIndex, let n = Int(digits) else { break }
                out[i] = min(max(n, 1), w.senses.count)
                rest = after[digits.endIndex...]
            }
            return out
        }
        var picked = [Bool](repeating: false, count: words.count)
        let text = try await stream(body) { text in
            for (i, n) in read(text, final: false).enumerated() where !picked[i] {
                if let n { picked[i] = true; onPick(i, n) }
            }
        }
        let picks = read(text, final: true)
        guard picks.allSatisfy({ $0 != nil }) else { throw unexpected(text) }
        // The last number has nothing after it, so it's only certain now.
        for (i, n) in picks.enumerated() where !picked[i] { await onPick(i, n!) }
        return picks.map { $0! }
    }

    private static func chooseAllAsJSON(passage: String, selectionMarked: Bool, words: [(word: String, senses: [Sense])],
                                        onPick: @MainActor (Int, Int) -> Void) async throws -> [Int] {
        // Zero-padded so that sorted keys (in `stream`) keep the words in order: w01, w02, … w10.
        let keys = words.indices.map { String(format: "w%02d", $0 + 1) }
        var props: [String: Any] = [:]
        for k in keys { props[k] = ["type": "integer"] }
        let body = chooseAllBody(chooseAllPrompt(passage, selectionMarked, words, labels: keys),
                                 options: ["temperature": 0, "num_ctx": 2048],
                                 format: ["type": "object", "properties": props, "required": keys])
        var picks = [Int?](repeating: nil, count: words.count)
        let text = try await stream(body) { text in
            // A number is complete once something follows it.
            for m in text.matches(of: #/"w(\d+)"\s*:\s*(\d+)\s*[,}\s]/#) {
                guard let k = Int(m.1), let n = Int(m.2), words.indices.contains(k - 1), picks[k - 1] == nil else { continue }
                let pick = min(max(n, 1), words[k - 1].senses.count)
                picks[k - 1] = pick
                onPick(k - 1, pick)
            }
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw unexpected(text) }
        return words.indices.map { i in
            picks[i] ?? min(max(parsed[keys[i]] as? Int ?? 1, 1), words[i].senses.count)
        }
    }

    static let translationInstructions = """
    You translate Chinese into natural, idiomatic English for a learner. Keep the meaning, tone and any slang or idiom \
    (translate its sense, not its characters). Reply with the English translation only.
    """

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
    static func translate(_ text: String, context: String? = nil,
                          partial: @MainActor (String) -> Void = { _ in }) async throws -> String {
        var messages = [["role": "system", "content": translationInstructions]]
        if let context {
            // Told only to translate the part, the 4B model still translated the whole sentence
            // about a third of the time; two worked examples stop that (real reading: 22/52 →
            // 44/52), and cost almost nothing, since Ollama reuses the cached prompt prefix.
            for (c, part, english) in contextExamples {
                messages.append(["role": "user", "content": contextPrompt(c, part)])
                messages.append(["role": "assistant", "content": english])
            }
            messages.append(["role": "user", "content": contextPrompt(context, text)])
        } else {
            messages.append(["role": "user", "content": text])
        }
        let body: [String: Any] = [
            "model": name, "think": false,
            "options": ["temperature": 0, "num_ctx": 2048],
            "keep_alive": "5m",
            "messages": messages,
        ]
        let out = try await stream(body) { partial($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw NSError(domain: "LongyanReader", code: 6, userInfo: [NSLocalizedDescriptionKey: "empty translation"]) }
        // With context it now and then answers in Chinese (胜任或轻视这份工作); alone it doesn't.
        if context != nil, t.contains(where: isCJK) { return try await translate(text, partial: partial) }
        return t
    }

    /// Runs a chat request with streaming on; `onText` gets the reply so far after each piece.
    private static func stream(_ body: [String: Any], onText: @MainActor (String) -> Void) async throws -> String {
        var body = body
        body["stream"] = true
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
    }

    /// One word's sense, asked the way a phrase card asks: on casual uses this picked better
    /// than a dedicated prompt with the model's own wording first (27/30 against 22/30). The
    /// passage marks the word and keeps the text around it, which can decide the sense.
    static func choose(_ context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        // The JSON form here: for one word the one-line reply saves only ~0.1 s, and the card
        // is prepared while the reader moves to click, while JSON scored a little better
        // (real reading 36/39 against 34/39).
        let n = try await chooseAllAsJSON(passage: context.markedPassage, selectionMarked: false,
                                          words: [(context.word, senses)], onPick: { _, _ in }).first ?? 1
        return SenseChoice(senseNumber: n, meaningHere: headlineGloss(senses[n - 1]))
    }
}
