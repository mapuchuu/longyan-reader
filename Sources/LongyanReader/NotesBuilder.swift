import Foundation

/// Build-time nuance notes, written by Claude through the Message Batches API.
///
///   --notes-select <jieba dict.txt> <out.json> [count]   choose the pilot words
///   --notes-submit <selection.json> <batch.json>         submit the batch
///   --notes-status <batch.json>                          processing status
///   --notes-fetch  <batch.json> <notes.json> <review.md> download, validate, write review
///
/// The API key is read from the macOS keychain (service "longyan-anthropic") or
/// ANTHROPIC_API_KEY, and never printed.
enum NotesBuilder {
    static let model = "claude-opus-5-5"

    // MARK: Selection

    struct PilotWord: Codable {
        let word: String
        let rank: Int
        let kind: String            // "frequent" or "idiom"
        let senses: [PilotSense]
    }
    struct PilotSense: Codable {
        let index: Int
        let pinyin: String          // numbered, as in CC-CEDICT
        let gloss: String
    }

    /// Frequent words sampled evenly across the top 30,000 (so the pilot sees common
    /// and mid-frequency words), plus the most frequent idioms. Proper nouns, particles,
    /// single-sense cross-references and non-dictionary words are skipped.
    static func select(frequencyFile: URL, dict: CEDict, count: Int) throws -> [PilotWord] {
        var ranked: [String] = []
        for line in try String(contentsOf: frequencyFile, encoding: .utf8).split(separator: "\n") {
            let word = String(line.split(separator: " ").first ?? "")
            guard !word.isEmpty, word.allSatisfy(isCJK), dict.contains(word) else { continue }
            ranked.append(word)
        }
        // jieba's file is not sorted by frequency; sort by its count column.
        var freq: [String: Int] = [:]
        for line in try String(contentsOf: frequencyFile, encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, let n = Int(parts[1]) { freq[String(parts[0])] = n }
        }
        ranked = Array(Set(ranked)).sorted { (freq[$0] ?? 0) > (freq[$1] ?? 0) }

        func pilot(_ word: String, rank: Int, kind: String) -> PilotWord? {
            let senses = dict.senses(for: word, limit: CEDict.modelSenseLimit)
            guard !senses.isEmpty, !particleWords.contains(word),
                  !(dict.entries(for: word).allSatisfy(\.isProperNoun)) else { return nil }
            return PilotWord(word: word, rank: rank, kind: kind,
                             senses: senses.enumerated().map { PilotSense(index: $0.offset + 1, pinyin: $0.element.pinyin, gloss: $0.element.gloss) })
        }

        let idiomTarget = count / 5
        var idioms: [PilotWord] = []
        for (i, w) in ranked.enumerated() where w.count == 4 && idioms.count < idiomTarget {
            if dict.entries(for: w).contains(where: { $0.definitions.contains { $0.contains("(idiom)") } }),
               let p = pilot(w, rank: i + 1, kind: "idiom") { idioms.append(p) }
        }

        let frequentTarget = count - idioms.count
        let pool = Array(ranked.prefix(30_000).enumerated())
        let step = max(1, pool.count / (frequentTarget * 2))
        var frequent: [PilotWord] = []
        var seen = Set(idioms.map(\.word))
        for (i, w) in pool where i % step == 0 && frequent.count < frequentTarget && !seen.contains(w) {
            if let p = pilot(w, rank: i + 1, kind: "frequent") { frequent.append(p); seen.insert(w) }
        }
        return frequent + idioms
    }

    /// Pilot words from a hand-written list: lines are words; a line "# idioms" switches
    /// the kind for the lines after it. Words the dictionary doesn't have are reported.
    static func fromList(_ text: String, dict: CEDict) -> (words: [PilotWord], missing: [String]) {
        var words: [PilotWord] = []
        var missing: [String] = []
        var kind = "frequent"
        var seen: Set<String> = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { if line.contains("idiom") { kind = "idiom" }; continue }
            for w in line.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init) where !w.isEmpty && !seen.contains(w) {
                seen.insert(w)
                let senses = dict.senses(for: w, limit: CEDict.modelSenseLimit)
                guard !senses.isEmpty, !dict.entries(for: w).allSatisfy(\.isProperNoun) else { missing.append(w); continue }
                words.append(PilotWord(word: w, rank: 0, kind: kind,
                                       senses: senses.enumerated().map { PilotSense(index: $0.offset + 1, pinyin: $0.element.pinyin, gloss: $0.element.gloss) }))
            }
        }
        return (words, missing)
    }

    // MARK: Prompt

    /// Adapted from the Longyan Chrome extension's note prompt, judged per dictionary sense.
    static let systemPrompt = """
    You write nuance notes for a Chinese reading tool used by English speakers. For a Chinese word, you get its numbered CC-CEDICT senses. For each sense, decide whether the English gloss loses something a reader needs.

    Set tag to "lost_in_translation" if the English cannot carry the full meaning or register of the Chinese in that sense (e.g. 掠夺 as "plunder" loses the implied organized violence; 有识之士 implies moral obligation, not just intelligence: if you see clearly, you are duty-bound to speak).
    Set tag to "cultural_context" if understanding that sense requires knowledge specific to Chinese history, politics, society or culture (e.g. 农民起义 is a Marxist historiographic category, not a neutral descriptor).
    Set tag to "none" for everything else. Do not over-tag: most senses of most words are "none", including most common words. A sense is not tagged just because it is Chinese, polite, formal, or has a near synonym.

    When tag is not "none", write the note in two parts: (1) a one-line plain-English definition; (2) one sentence on what a native speaker actually feels or pictures when using the word in this sense, present tense, first or second person. If the word carries a physical or emotional sensation, lead with that. Write like a knowledgeable friend whispering context, not a historian citing sources. At most two sentences in total. The register to aim for: "This isn't just 'isolationism'; it's a word Chinese people use when they're still a little embarrassed about what that era cost them."

    Never use em dashes. Never use the words "historiographic", "invokes" or "refers to". No meta-commentary about translation, language, English, or cultural gaps: don't say what the word does, say what it means to someone who grew up with it.

    When tag is "none", note is an empty string. Return one entry per sense, using the sense numbers given.
    """

    static func userPrompt(_ w: PilotWord) -> String {
        let senses = w.senses.map { "\($0.index). [\(Pinyin.marked($0.pinyin))] \($0.gloss)" }.joined(separator: "\n")
        return "Word: \(w.word)\nSenses:\n\(senses)"
    }

    static let outputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "senses": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "index": ["type": "integer"],
                        "tag": ["type": "string", "enum": ["none", "lost_in_translation", "cultural_context"]],
                        "note": ["type": "string"],
                    ],
                    "required": ["index", "tag", "note"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["senses"],
        "additionalProperties": false,
    ]

    // MARK: Batch API (raw HTTP: there is no official Swift SDK)

    static func apiKey() throws -> String {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "longyan-anthropic", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let key = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard p.terminationStatus == 0, !key.isEmpty else {
            throw NSError(domain: "LongyanReader", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "No API key: add one with  security add-generic-password -s longyan-anthropic -a api -w"])
        }
        return key
    }

    static func request(_ method: String, _ url: URL, body: Data? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(try apiKey(), forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body
        req.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NSError(domain: "LongyanReader", code: status, userInfo: [NSLocalizedDescriptionKey:
                "HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")"])
        }
        return data
    }

    static func submit(_ words: [PilotWord]) async throws -> [String: Any] {
        let system: [[String: Any]] = [["type": "text", "text": systemPrompt, "cache_control": ["type": "ephemeral"]]]
        let requests: [[String: Any]] = words.enumerated().map { i, w in
            [
                "custom_id": "w\(i)",
                "params": [
                    "model": model,
                    "max_tokens": 8000,
                    "system": system,
                    "output_config": ["effort": "medium", "format": ["type": "json_schema", "schema": outputSchema]],
                    "messages": [["role": "user", "content": userPrompt(w)]],
                ] as [String: Any],
            ]
        }
        let body = try JSONSerialization.data(withJSONObject: ["requests": requests])
        let data = try await request("POST", URL(string: "https://api.anthropic.com/v1/messages/batches")!, body: body)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func status(id: String) async throws -> [String: Any] {
        let data = try await request("GET", URL(string: "https://api.anthropic.com/v1/messages/batches/\(id)")!)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: Results

    struct Note: Codable {
        let word: String
        let pinyin: String
        let gloss: String
        let tag: String
        let note: String
        var problems: [String]
    }

    struct FetchReport {
        var notes: [Note] = []
        var errored: [String] = []
        var inputTokens = 0, outputTokens = 0, cacheReadTokens = 0, cacheWriteTokens = 0
        var sensesTotal = 0
    }

    /// Downloads results (JSONL, any order: keyed by custom_id) and checks each note.
    static func fetch(id: String, words: [PilotWord]) async throws -> FetchReport {
        let batch = try await status(id: id)
        guard batch["processing_status"] as? String == "ended", let urlString = batch["results_url"] as? String,
              let url = URL(string: urlString) else {
            throw NSError(domain: "LongyanReader", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "Batch not finished yet: \(batch["processing_status"] ?? "?")"])
        }
        let data = try await request("GET", url)
        var report = FetchReport()
        let byID = Dictionary(uniqueKeysWithValues: words.enumerated().map { ("w\($0.offset)", $0.element) })
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cid = row["custom_id"] as? String, let w = byID[cid],
                  let result = row["result"] as? [String: Any] else { continue }
            guard result["type"] as? String == "succeeded", let message = result["message"] as? [String: Any] else {
                report.errored.append("\(w.word): \(result["type"] ?? "?")")
                continue
            }
            if let usage = message["usage"] as? [String: Any] {
                report.inputTokens += usage["input_tokens"] as? Int ?? 0
                report.outputTokens += usage["output_tokens"] as? Int ?? 0
                report.cacheReadTokens += usage["cache_read_input_tokens"] as? Int ?? 0
                report.cacheWriteTokens += usage["cache_creation_input_tokens"] as? Int ?? 0
            }
            guard message["stop_reason"] as? String == "end_turn" else {
                report.errored.append("\(w.word): stop_reason \(message["stop_reason"] ?? "?")")
                continue
            }
            let text = (message["content"] as? [[String: Any]] ?? []).first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let senses = parsed["senses"] as? [[String: Any]] else {
                report.errored.append("\(w.word): unparseable output")
                continue
            }
            report.sensesTotal += w.senses.count
            for s in senses {
                guard let i = s["index"] as? Int, let sense = w.senses.first(where: { $0.index == i }),
                      let tag = s["tag"] as? String, tag != "none" else { continue }
                let note = (s["note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                report.notes.append(Note(word: w.word, pinyin: sense.pinyin, gloss: sense.gloss, tag: tag, note: note,
                                         problems: problems(in: note)))
            }
        }
        return report
    }

    /// Notes written by hand (or in a session) as TSV: word, sense number, L/C, note.
    static func fromTSV(_ text: String, words: [PilotWord]) -> FetchReport {
        var report = FetchReport()
        report.sensesTotal = words.map(\.senses.count).reduce(0, +)
        let byWord = Dictionary(words.map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard cols.count == 4, let w = byWord[cols[0]], let i = Int(cols[1]),
                  let sense = w.senses.first(where: { $0.index == i }) else {
                report.errored.append("unmatched line: \(line.prefix(40))")
                continue
            }
            let tag = cols[2] == "C" ? "cultural_context" : "lost_in_translation"
            report.notes.append(Note(word: w.word, pinyin: sense.pinyin, gloss: sense.gloss, tag: tag, note: cols[3],
                                     problems: problems(in: cols[3])))
        }
        return report
    }

    /// Copies each note onto the senses that are paraphrases of it (note-covers.tsv:
    /// word, noted sense, covered senses), so it shows whichever paraphrase is picked.
    static func applyCovers(_ text: String, to report: inout FetchReport, words: [PilotWord]) {
        let byWord = Dictionary(words.map { ($0.word, $0) }, uniquingKeysWith: { a, _ in a })
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count == 3, let w = byWord[cols[0]], let i = Int(cols[1]),
                  let noted = w.senses.first(where: { $0.index == i }),
                  let note = report.notes.first(where: { $0.word == w.word && $0.gloss == noted.gloss }) else {
                report.errored.append("unmatched cover: \(line.prefix(30))")
                continue
            }
            for j in cols[2].split(separator: ",").compactMap({ Int($0) }) {
                guard let sense = w.senses.first(where: { $0.index == j }),
                      !report.notes.contains(where: { $0.word == w.word && $0.gloss == sense.gloss }) else { continue }
                report.notes.append(Note(word: w.word, pinyin: sense.pinyin, gloss: sense.gloss, tag: note.tag,
                                         note: note.note, problems: note.problems))
            }
        }
    }

    /// Mechanical checks on a note; anything flagged is held back from the app.
    static func problems(in note: String) -> [String] {
        var out: [String] = []
        if note.isEmpty { out.append("empty") }
        if note.contains("—") || note.contains("–") { out.append("em dash") }
        // A sentence ends at . ! ? followed by a space and a capital, or the end ("9 a.m." isn't one).
        let enders = (try? NSRegularExpression(pattern: "[.!?](\\s+[A-Z\"“]|\\s*$)"))?
            .numberOfMatches(in: note, range: NSRange(note.startIndex..., in: note)) ?? 0
        if enders > 2 { out.append("\(enders) sentences") }
        if note.count > 320 { out.append("\(note.count) characters") }
        let lower = note.lowercased()
        for banned in ["historiographic", "invokes", "refers to", "translat", "in english", "english word"] where lower.contains(banned) {
            out.append("uses \"\(banned)\"")
        }
        return out
    }

    /// A Markdown page for reviewing the pilot by eye.
    static func review(_ r: FetchReport, words: [PilotWord]) -> String {
        let tagged = Set(r.notes.map(\.word))
        let clean = r.notes.filter { $0.problems.isEmpty }
        // Opus 5.5 batch pricing: half of $4 / $20 per million tokens.
        let cost = Double(r.inputTokens) * 2 / 1e6 + Double(r.cacheWriteTokens) * 2.5 / 1e6
            + Double(r.cacheReadTokens) * 0.1 / 1e6 + Double(r.outputTokens) * 10 / 1e6
        var md = """
        # Longyan nuance notes: pilot review

        - Written by: \(r.inputTokens == 0 ? "Claude in a Claude Code session (no API calls)" : "`\(model)` via the Message Batches API")
        - Words: \(words.count) (\(words.filter { $0.kind == "idiom" }.count) idioms), senses judged: \(r.sensesTotal)
        - Notes written: \(r.notes.count) across \(tagged.count) words; \(clean.count) pass the checks, \(r.notes.count - clean.count) flagged
        - Failed requests: \(r.errored.count)

        """
        if r.inputTokens > 0 {
            md += "- Tokens: \(r.inputTokens) input, \(r.cacheWriteTokens) cache write, \(r.cacheReadTokens) cache read, \(r.outputTokens) output (approx. $\(String(format: "%.2f", cost)))\n"
        }
        if !r.errored.isEmpty { md += "\n## Failed\n\n" + r.errored.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        let flagged = r.notes.filter { !$0.problems.isEmpty }
        if !flagged.isEmpty {
            md += "\n## Flagged by the checks\n\n"
            for n in flagged { md += "- **\(n.word)** [\(Pinyin.marked(n.pinyin))] \(n.gloss) — *\(n.tag)* (\(n.problems.joined(separator: ", "))): \(n.note)\n" }
        }
        md += "\n## Notes\n\n"
        for n in clean {
            md += "- **\(n.word)** [\(Pinyin.marked(n.pinyin))] *\(n.gloss)* · \(n.tag == "cultural_context" ? "cultural context" : "lost in translation")  \n  \(n.note)\n"
        }
        let untagged = words.filter { !tagged.contains($0.word) }.map(\.word)
        md += "\n## Words with no note (\(untagged.count))\n\n" + untagged.joined(separator: " ") + "\n"
        return md
    }
}
