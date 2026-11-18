import Foundation
import llama

/// The local model run inside the app with llama.cpp (Metal), in place of a separate Ollama
/// server. Takes the same chat messages LocalModel sends Ollama and streams the reply text.
/// One generation at a time, like Ollama: requests queue on one thread.
final class EmbeddedModel: @unchecked Sendable {
    static let shared = EmbeddedModel()

    /// Where the model file is: LONGYAN_GGUF, else the app's downloaded copy, else (on a
    /// machine that has it) Ollama's copy of the same Qwen 3.5 4B Q4_K_M file.
    static let fileName = "qwen3.5-4b-q4_k_m.gguf"
    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LongyanReader/models")
    }
    static var modelPath: String? {
        if let p = ProcessInfo.processInfo.environment["LONGYAN_GGUF"] { return p }
        let candidates = [
            modelsDirectory.appendingPathComponent(fileName).path,
            NSHomeDirectory() + "/.ollama/models/blobs/sha256-00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private let queue: DispatchQueue = {
        let q = DispatchQueue(label: "com.mapuchuu.longyanreader.llama", qos: .userInitiated)
        q.setSpecific(key: EmbeddedModel.onQueue, value: ())
        return q
    }()
    private static let onQueue = DispatchSpecificKey<Void>()
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadError: Error?
    /// The model file wouldn't load (damaged, or not a model). Lookups then fall back, the
    /// menu offers the download again, and a new download clears it.
    static var fileUnloadable: Bool { brokenFlag.isSet }
    private static let brokenFlag = StopFlag()
    private static let exiting = StopFlag()
    /// After a new download: try the file again.
    func forgetLoadFailure() { Self.brokenFlag.clear(); queue.async { self.loadError = nil } }
    /// The tokens now in the context, so a request that starts the same way (the system
    /// prompt, the worked examples) only reads what's new.
    private var cached: [llama_token] = []
    private struct Snapshot { let tokens: [llama_token]; let data: [UInt8] }
    private var snapshots: [Snapshot] = []
    /// Each is 58–81 MB (Qwen 3.5 4B's recurrent state is ~53 MB, plus ~0.03 MB a prompt token).
    /// In every test, each reuse was of the latest one; two cover a card's pick and translation.
    private static let maxSnapshots = 2
    static let contextSize: UInt32 = 2048
    /// Like Ollama, the model (about 3 GB) is let go after five idle minutes; the next lookup,
    /// or selecting Chinese text (warmUp), loads it again in about a second.
    private static let idleUnload: TimeInterval = 300
    private var lastUse = Date()
    private var backendReady = false
    private var exitHandlerSet = false
    private var contextFailedAt: Date?

    private init() {}

    /// Loads the model if needed (about a second from a warm disk cache). Safe to call often.
    func warmUp() { queue.async { _ = try? self.loadIfNeeded() } }

    private func loadIfNeeded() throws {
        // Quitting: a request queued behind the exit handler's free must not load it again.
        if Self.exiting.isSet { throw CancellationError() }
        if ctx != nil { return }
        if let loadError { throw loadError }
        // A context that couldn't be made (short on memory) is tried again a minute later,
        // not on every selection: each try reads the whole 2.7 GB file.
        if let at = contextFailedAt, Date().timeIntervalSince(at) < 60 { throw Self.error("couldn't create a context") }
        guard let path = Self.modelPath else { throw Self.error("no model file") }
        if !backendReady {
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            backendReady = true
        }
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(path, mp) else {
            Self.brokenFlag.set()
            loadError = Self.error("couldn't load \(path)"); throw loadError!
        }
        var cp = llama_context_default_params()
        cp.n_ctx = Self.contextSize
        cp.n_batch = Self.contextSize
        cp.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads_batch = cp.n_threads
        let env = ProcessInfo.processInfo.environment
        if let t = env["LONGYAN_THREADS"].flatMap(Int32.init) { cp.n_threads = t; cp.n_threads_batch = t }
        if let f = env["LONGYAN_FA"].flatMap(Int32.init) { cp.flash_attn_type = llama_flash_attn_type(rawValue: f) }
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m); contextFailedAt = Date(); throw Self.error("couldn't create a context")
        }
        model = m; ctx = c; vocab = llama_model_get_vocab(m)
        // ggml frees its Metal device at exit and asserts nothing still uses it, so the context
        // and model must go first. Exit handlers run newest first, and ggml registers its own
        // when the device is first used (during the load above), so ours is registered after.
        // Quitting mid-lookup: the request stops at its next token, then the free runs on the
        // queue after it, so it never frees what a decode is using.
        if !exitHandlerSet {
            atexit {
                EmbeddedModel.exiting.set()
                let m = EmbeddedModel.shared
                // exit() called from the queue itself (a CLI path) would deadlock on sync.
                if DispatchQueue.getSpecific(key: EmbeddedModel.onQueue) != nil { m.free() } else { m.queue.sync { m.free() } }
            }
            exitHandlerSet = true
        }
        noteUse()
    }

    /// Quitting: waits out a load or request in progress (a request stops at its next token),
    /// then frees the model, before exit() starts tearing down ggml. The exit handler only
    /// exists once a load has finished, so a quit during the first load needs this.
    func shutdown() {
        Self.exiting.set()
        if DispatchQueue.getSpecific(key: Self.onQueue) != nil { free() } else { queue.sync { free() } }
    }

    /// Called on the queue after each load and request.
    private func noteUse() {
        lastUse = Date()
        queue.asyncAfter(deadline: .now() + Self.idleUnload + 1) {
            if self.ctx != nil, Date().timeIntervalSince(self.lastUse) >= Self.idleUnload { self.free() }
        }
    }

    private func free() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; cached = []; snapshots = []
    }

    /// Streams a chat reply. `messages` are role/content pairs as sent to Ollama; `grammar`
    /// (GBNF) constrains the reply; `maxTokens` caps it. Cancelling the consuming task stops
    /// generation at the next token.
    /// `banned` are English words the reply can't use (OutsideWords). When the model's next
    /// word would be one of them and `endsAt` says the reply so far is enough, it ends there.
    func stream(messages: [[String: String]], maxTokens: Int?, grammar: String?, banned: [String] = [],
                endsAt: (@Sendable (String) -> Bool)? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let stop = StopFlag()
            continuation.onTermination = { _ in stop.set() }
            queue.async {
                do {
                    // Cancelled while queued (a newer selection): skip the prompt read entirely.
                    if stop.isSet { throw CancellationError() }
                    try self.loadIfNeeded()
                    try self.generate(prompt: Self.render(messages), maxTokens: maxTokens ?? 512, grammar: grammar,
                                      banned: self.wordTokens(banned), endsAt: endsAt, stop: stop) { continuation.yield($0) }
                    self.noteUse()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Qwen's ChatML, rendered the way Ollama renders it with thinking off: an empty think
    /// block opens the answer.
    static func render(_ messages: [[String: String]]) -> String {
        var s = ""
        for m in messages { s += "<|im_start|>\(m["role"] ?? "user")\n\(m["content"] ?? "")<|im_end|>\n" }
        return s + "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Reads a prompt into the context, reusing what's already there, and leaves the logits
    /// for what comes after its last token. Returns how many tokens were reused.
    private func read(_ tokens: [llama_token]) throws -> Int {
        guard let ctx, let model else { throw Self.error("not loaded") }
        // Reuse what's already been read. A plain transformer keeps its cache up to where this
        // prompt departs from the last one. Qwen 3.5 is a hybrid model, whose recurrent state
        // can't be cut back to a shared prefix, so instead the state at the end of each recent
        // prompt (less its last token, whose logits are needed) is saved, and a prompt seen
        // again (the same passage asked about another word, a card prepared then opened)
        // restores it: an 860-token prompt then costs ~15 ms instead of ~230.
        let memory = llama_get_memory(ctx)
        var keep = 0
        let body = Array(tokens.dropLast())
        if !llama_model_is_recurrent(model) && !llama_model_is_hybrid(model) {
            while keep < min(cached.count, tokens.count - 1) && cached[keep] == tokens[keep] { keep += 1 }
            if keep == 0 { llama_memory_clear(memory, true) } else { _ = llama_memory_seq_rm(memory, 0, Int32(keep), -1) }
            cached = Array(tokens[..<keep])
            try decode(Array(tokens[keep...]), startingAt: keep)
        } else {
            llama_memory_clear(memory, true)
            cached = []
            if let i = snapshots.firstIndex(where: { $0.tokens == body }),
               snapshots[i].data.withUnsafeBufferPointer({ llama_state_seq_set_data(ctx, $0.baseAddress, $0.count, 0) }) > 0 {
                if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
                    FileHandle.standardError.write(Data("snapshot hit: \(snapshots.count - 1 - i) back\n".utf8))
                }
                snapshots.append(snapshots.remove(at: i))   // most recently used last
                cached = body
                keep = body.count
            } else {
                llama_memory_clear(memory, true)
                try decode(body, startingAt: 0)
                let size = llama_state_seq_get_size(ctx, 0)
                var data = [UInt8](repeating: 0, count: size)
                if data.withUnsafeMutableBufferPointer({ llama_state_seq_get_data(ctx, $0.baseAddress, size, 0) }) == size {
                    snapshots.append(Snapshot(tokens: body, data: data))
                    if snapshots.count > Self.maxSnapshots { snapshots.removeFirst() }
                    if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
                        FileHandle.standardError.write(Data(String(format: "snapshot: %d tokens, %.1f MB; %d kept, %.1f MB\n", body.count,
                            Double(size) / 1e6, snapshots.count, Double(snapshots.reduce(0) { $0 + $1.data.count }) / 1e6).utf8))
                    }
                }
            }
            try decode([tokens.last!], startingAt: cached.count)
        }
        return keep
    }

    /// The single tokens that spell each word or a plain inflection of it, with or without a
    /// leading space and capital: " flat", "Flat", " lies". A word that takes several tokens
    /// isn't kept out (its first piece is often the start of other words).
    private func wordTokens(_ words: [String]) -> Set<llama_token> {
        var out = Set<llama_token>()
        for w in words {
            for form in [w, w + "s", w + "es", w + "ed", w + "d", w + "ing"] {
                for v in [form, form.prefix(1).uppercased() + form.dropFirst()] {
                    for t in [v, " " + v] { let ids = tokenize(t); if ids.count == 1 { out.insert(ids[0]) } }
                }
            }
        }
        return out
    }

    private func generate(prompt: String, maxTokens: Int, grammar: String?, banned: Set<llama_token> = [],
                          endsAt: ((String) -> Bool)? = nil, stop: StopFlag, onText: (String) -> Void) throws {
        guard let ctx, let vocab, let model else { throw Self.error("not loaded") }
        let started = Date()
        let tokens = tokenize(prompt)
        guard tokens.count + maxTokens < Int(Self.contextSize) else { throw Self.error("prompt too long (\(tokens.count) tokens)") }
        let keep = try read(tokens)
        let promptMs = Date().timeIntervalSince(started) * 1000

        // Greedy (temperature 0). With a grammar, the top token is checked alone first and the
        // whole vocabulary is masked only when it's rejected: masking all ~250k tokens every
        // step made a JSON pick ~0.1 s slower, and the result is the same token either way.
        var g: UnsafeMutablePointer<llama_sampler>?
        if let grammar {
            guard let s = llama_sampler_init_grammar(vocab, grammar, "root") else { throw Self.error("bad grammar") }
            g = s
        }
        defer { if let g { llama_sampler_free(g) } }
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var candidates = [llama_token_data](repeating: llama_token_data(), count: nVocab)
        var bytes: [UInt8] = []
        func next() -> llama_token? {
            let logits = llama_get_logits_ith(ctx, -1)!
            var best = 0
            for i in 1..<nVocab where logits[i] > logits[best] { best = i }
            if banned.contains(llama_token(best)) {
                if endsAt?(Self.completeUTF8(bytes)) == true { return nil }
                for t in banned { logits[Int(t)] = -.infinity }
                best = 0
                for i in 1..<nVocab where logits[i] > logits[best] { best = i }
            }
            guard let g else { return llama_token(best) }
            var one = llama_token_data(id: llama_token(best), logit: logits[best], p: 0)
            let allowed = withUnsafeMutablePointer(to: &one) { p -> Bool in
                var arr = llama_token_data_array(data: p, size: 1, selected: -1, sorted: false)
                llama_sampler_apply(g, &arr)
                return p.pointee.logit.isFinite
            }
            if allowed { return llama_token(best) }
            for i in 0..<nVocab { candidates[i] = llama_token_data(id: llama_token(i), logit: logits[i], p: 0) }
            return candidates.withUnsafeMutableBufferPointer { buf -> llama_token in
                var arr = llama_token_data_array(data: buf.baseAddress, size: nVocab, selected: -1, sorted: false)
                llama_sampler_apply(g, &arr)
                var top = 0
                for i in 1..<arr.size where arr.data[i].logit > arr.data[top].logit { top = i }
                return arr.data[top].id
            }
        }

        var produced = 0
        let answerStart = Date()
        while produced < maxTokens {
            if stop.isSet || Self.exiting.isSet { throw CancellationError() }
            guard let t = next() else { break }
            if let g { llama_sampler_accept(g, t) }
            if llama_vocab_is_eog(vocab, t) { break }
            produced += 1
            bytes += piece(t)
            onText(Self.completeUTF8(bytes))
            try decode([t], startingAt: cached.count)
        }
        if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
            FileHandle.standardError.write(Data(String(format: "timing: prompt %d tok (%d new%@) %.0f ms, answer %d tok %.0f ms: %@\n",
                tokens.count, tokens.count - keep, llama_model_is_hybrid(model) ? ", hybrid" : "", promptMs, produced,
                Date().timeIntervalSince(answerStart) * 1000, Self.completeUTF8(bytes).debugDescription).utf8))
        }
    }

    struct Pick: Sendable { let number: Int; let confidence: Double }

    /// Numbers picked without writing a reply. Each step is the answer's text up to a number
    /// (`等=`, then ` 和=`) and how many numbers it may be (1…count). The model's odds for the
    /// next token, over the digits, give the number and how sure it is (its share of the odds
    /// of all the allowed numbers); the number and the next step's text are then read in
    /// together. That's one model pass per number, where writing the reply took one per token.
    func pick(messages: [[String: String]], steps: [(text: String, count: Int)]) -> AsyncThrowingStream<Pick, Error> {
        AsyncThrowingStream { continuation in
            let stop = StopFlag()
            continuation.onTermination = { _ in stop.set() }
            queue.async {
                do {
                    // Cancelled while queued (a newer selection): skip the prompt read entirely.
                    if stop.isSet { throw CancellationError() }
                    try self.loadIfNeeded()
                    let started = Date()
                    let digits = (0...9).map { self.tokenize(String($0)) }
                    guard digits.allSatisfy({ $0.count == 1 }), let first = steps.first else { throw Self.error("digits aren't single tokens") }
                    let tokens = self.tokenize(Self.render(messages) + first.text)
                    let stepTokens = steps.dropFirst().reduce(2 * steps.count) { $0 + self.tokenize($1.text).count }
                    guard tokens.count + stepTokens < Int(Self.contextSize) else { throw Self.error("prompt too long (\(tokens.count) tokens)") }
                    let keep = try self.read(tokens)
                    var pending: [llama_token] = []
                    for (i, step) in steps.enumerated() {
                        if stop.isSet || Self.exiting.isSet { throw CancellationError() }
                        if i > 0 { try self.decode(pending + self.tokenize(step.text), startingAt: self.cached.count) }
                        let (pick, rest) = try self.readNumber(upTo: step.count, digits: digits.map { $0[0] })
                        pending = rest
                        continuation.yield(pick)
                    }
                    if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
                        FileHandle.standardError.write(Data(String(format: "timing: pick, prompt %d tok (%d new), %d numbers, %.0f ms\n",
                            tokens.count, tokens.count - keep, steps.count, Date().timeIntervalSince(started) * 1000).utf8))
                    }
                    self.noteUse()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Reads the number (1…count) the logits point to. Above 9 numbers, a leading 1 may be
    /// 1 or 10…count, so the 1 is read in and the next token decides: a digit, or anything
    /// else (the number ended). Returns the pick and the tokens of the number not yet read in.
    private func readNumber(upTo count: Int, digits: [llama_token]) throws -> (Pick, [llama_token]) {
        guard let ctx, let vocab else { throw Self.error("not loaded") }
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        // Each digit's probability, and the rest (any other token), from the full softmax.
        func odds() -> (digit: [Double], other: Double) {
            let logits = llama_get_logits_ith(ctx, -1)!
            var top = logits[0]
            for i in 1..<nVocab where logits[i] > top { top = logits[i] }
            var z = 0.0
            for i in 0..<nVocab { z += exp(Double(logits[i] - top)) }
            let d = digits.map { exp(Double(logits[Int($0)] - top)) / z }
            return (d, max(0, 1 - d.reduce(0, +)))
        }
        func best(_ p: [Double]) -> (Int, Double) {
            let total = p.reduce(0, +)
            let i = p.indices.max { p[$0] < p[$1] }!
            return (i, total > 0 ? p[i] / total : 0)
        }
        let o = odds()
        let firsts = Array(1...min(9, max(count, 1)))
        let (i, share) = best(firsts.map { o.digit[$0] })
        let lead = firsts[i]
        guard count >= 10, lead == 1 else { return (Pick(number: lead, confidence: share), [digits[lead]]) }
        try decode([digits[1]], startingAt: cached.count)
        let o2 = odds()
        // 0: the number ends at 1; then 10, 11, … up to count.
        let (j, share2) = best([o2.other] + (0...(count - 10)).map { o2.digit[$0] })
        return (Pick(number: j == 0 ? 1 : 9 + j, confidence: share * share2), j == 0 ? [] : [digits[j - 1]])
    }

    private func decode(_ tokens: [llama_token], startingAt pos: Int) throws {
        guard let ctx, !tokens.isEmpty else { return }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (i, t) in tokens.enumerated() {
            batch.token[i] = t
            batch.pos[i] = Int32(pos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = i == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        guard llama_decode(ctx, batch) == 0 else { cached = []; throw Self.error("decode failed") }
        cached += tokens
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var out = [llama_token](repeating: 0, count: utf8.count + 8)
        // parse_special: the ChatML markers are single special tokens.
        var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), false, true)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), false, true)
        }
        return Array(out.prefix(Int(max(n, 0))))
    }

    private func piece(_ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        let n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    /// The text so far, leaving out a character whose bytes haven't all arrived (a token can
    /// end partway through a Chinese character).
    static func completeUTF8(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        var i = bytes.count - 1
        while i >= 0 && i >= bytes.count - 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { i -= 1; continue }           // continuation byte
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if bytes.count - i < need { end = i }
            break
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// A grammar for a JSON object of the given integer keys, in order: what Ollama's
    /// `format` schema asks for in LocalModel.chooseAllAsJSON.
    static func jsonGrammar(keys: [String]) -> String {
        let fields = keys.map { #""\"\#($0)\"" ws ":" ws num"# }.joined(separator: #" "," ws "#)
        return """
        root ::= "{" ws \(fields) ws "}"
        num ::= [0-9] [0-9]?
        ws ::= [ \\t\\n]{0,8}
        """
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "LongyanReader", code: 7, userInfo: [NSLocalizedDescriptionKey: "embedded model: " + message])
    }
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
    var isSet: Bool { lock.withLock { value } }
}
