import Foundation

/// A sense picker backed by a local model served by Ollama (http://127.0.0.1:11434).
/// Stronger than Apple's on-device 3B model at telling close senses apart; used when
/// Ollama is running and the model is installed, otherwise the app falls back.
enum LocalModel {
    /// Which model to use: LONGYAN_MODEL, else the "senseModel" default, else qwen3.5:9b.
    /// "apple" turns it off.
    static var name: String {
        ProcessInfo.processInfo.environment["LONGYAN_MODEL"]
            ?? UserDefaults.standard.string(forKey: "senseModel") ?? "qwen3.5:9b"
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

    static func choose(_ context: WordInContext, senses: [Sense]) async throws -> SenseChoice {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "meaningHere": ["type": "string", "description": "English for the marked word alone in this passage, 1 to 5 words"],
                "senseNumber": ["type": "integer"],
            ],
            "required": ["meaningHere", "senseNumber"],
        ]
        let body: [String: Any] = [
            "model": name,
            "stream": false,
            "think": false,
            "format": schema,
            "options": ["temperature": 0],
            "keep_alive": "30m",
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
