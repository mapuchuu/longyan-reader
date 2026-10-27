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

    static let instructions = """
    You help an English speaker read Chinese. You get a Chinese passage with one word marked 【like this】 and that word's numbered dictionary senses, some with example sentences. \
    Decide what the marked word means in this passage, then pick the sense that matches. Never invent a sense.
    """

    static func prompt(_ context: WordInContext, senses: [Sense]) -> String {
        let list = senses.enumerated().map { i, s -> String in
            var line = "\(i + 1). [\(Pinyin.marked(s.pinyin))] \(s.gloss)"
            let ex = ExamplesStore.examples(context.word, s).prefix(2)
            if !ex.isEmpty { line += "  e.g. " + ex.joined(separator: " ") }
            return line
        }
        return "Passage: \(context.markedPassage)\nMarked word: \(context.word)\nSenses:\n" + list.joined(separator: "\n")
    }

    /// Picks the sense of several words in one passage with a single request. Ollama serves
    /// one request at a time, so this is much quicker than asking word by word; the answer is
    /// just the sense numbers, in order, streamed so each word can be shown as soon as it's
    /// picked (`onPick` gets the word's position in `words` and its 1-based sense number).
    static func chooseAll(passage: String, words: [(word: String, senses: [Sense])],
                          onPick: @MainActor (Int, Int) -> Void = { _, _ in }) async throws -> [Int] {
        guard !words.isEmpty else { return [] }
        // Zero-padded so that sorted keys (below) keep the words in order: w01, w02, … w10.
        let keys = words.indices.map { String(format: "w%02d", $0 + 1) }
        let blocks = words.enumerated().map { n, w -> String in
            let list = w.senses.enumerated().map { i, s -> String in
                var line = "  \(i + 1). [\(Pinyin.marked(s.pinyin))] \(s.gloss)"
                let ex = ExamplesStore.examples(w.word, s).prefix(1)
                if !ex.isEmpty { line += "  e.g. " + ex.joined(separator: " ") }
                return line
            }
            return "\(keys[n]): \(w.word)\n" + list.joined(separator: "\n")
        }
        let user = "Passage: \(passage)\n" + "For each word, give the number of the sense it has in this passage.\n\n" + blocks.joined(separator: "\n\n")
        // Just the numbers: asking for a short meaning before each one (as the single-word
        // request does) made a sentence take twice as long and scored no better.
        var props: [String: Any] = [:]
        for k in keys { props[k] = ["type": "integer"] }
        let body: [String: Any] = [
            "model": name, "think": false,
            "format": ["type": "object", "properties": props, "required": keys],
            "options": ["temperature": 0, "num_ctx": 2048],
            "keep_alive": "5m",
            "messages": [
                ["role": "system", "content": """
                You help an English speaker read Chinese. You get a Chinese passage and some of its words, each with numbered dictionary senses. \
                For each word, decide what it means in this passage and give the number of the matching sense. Never invent a sense.
                """],
                ["role": "user", "content": user],
            ],
        ]
        var picks = [Int?](repeating: nil, count: words.count)
        let text = try await stream(body) { text in
            // A number is complete once something follows it.
            let pattern = #/"w(\d+)"\s*:\s*(\d+)\s*[,}\s]/#
            for m in text.matches(of: pattern) {
                guard let k = Int(m.1), let n = Int(m.2), words.indices.contains(k - 1), picks[k - 1] == nil else { continue }
                let pick = min(max(n, 1), words[k - 1].senses.count)
                picks[k - 1] = pick
                onPick(k - 1, pick)
            }
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw NSError(domain: "LongyanReader", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "local model: unexpected reply \(text.prefix(200))"])
        }
        return words.indices.map { i in
            picks[i] ?? min(max(parsed[keys[i]] as? Int ?? 1, 1), words[i].senses.count)
        }
    }

    static let translationInstructions = """
    You translate Chinese into natural, idiomatic English for a learner. Keep the meaning, tone and any slang or idiom \
    (translate its sense, not its characters). Reply with the English translation only.
    """

    /// A natural English translation, streamed: `partial` gets the text so far. Better than
    /// Apple's translator on slang and idioms (内卷 "involution", not "internal entanglement";
    /// 小意思 "a small token", not "a little interesting").
    static func translate(_ text: String, partial: @MainActor (String) -> Void = { _ in }) async throws -> String {
        let body: [String: Any] = [
            "model": name, "think": false,
            "options": ["temperature": 0, "num_ctx": 2048],
            "keep_alive": "5m",
            "messages": [
                ["role": "system", "content": translationInstructions],
                ["role": "user", "content": text],
            ],
        ]
        let out = try await stream(body) { partial($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw NSError(domain: "LongyanReader", code: 6, userInfo: [NSLocalizedDescriptionKey: "empty translation"]) }
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
            if obj["done"] as? Bool == true { break }
        }
        return text
    }

    static func choose(_ context: WordInContext, senses: [Sense], brief: Bool = false) async throws -> SenseChoice {
        let brief = brief || ProcessInfo.processInfo.environment["LONGYAN_SENSE_ONLY"] == "1"
        let full: [String: Any] = [
            "type": "object",
            "properties": [
                "meaningHere": ["type": "string", "maxLength": 50,
                                "description": "In English only: what the marked word alone means here, 1 to 5 words. Never Chinese, never a translation or description of the sentence."],
                "senseNumber": ["type": "integer"],
            ],
            "required": ["meaningHere", "senseNumber"],
        ]
        let schema: [String: Any] = brief
            ? ["type": "object", "properties": ["senseNumber": ["type": "integer"]], "required": ["senseNumber"]]
            : full
        let body: [String: Any] = [
            "model": name,
            "stream": false,
            "think": false,
            "format": schema,
            // Prompts are under 1k tokens: a small context window keeps memory down, and the
            // model is unloaded after five idle minutes (the next lookup reloads it in seconds).
            "options": ["temperature": 0, "num_ctx": 2048],
            "keep_alive": "5m",
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt(context, senses: senses)],
            ],
        ]
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String,
              let parsed = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let n = parsed["senseNumber"] as? Int else {
            throw NSError(domain: "LongyanReader", code: 5, userInfo: [NSLocalizedDescriptionKey:
                "local model: unexpected reply \(String(decoding: data.prefix(200), as: UTF8.self))"])
        }
        return SenseChoice(senseNumber: min(max(n, 1), senses.count),
                           meaningHere: parsed["meaningHere"] as? String ?? shortGloss([senses[min(max(n, 1), senses.count) - 1]]))
    }
}
