import Foundation
import llama
#if os(Windows)
import WinSDK
#endif

/// The local model run inside the app with llama.cpp (Metal), in place of a separate Ollama
/// server. Takes the same chat messages LocalModel sends Ollama and streams the reply text.
/// One generation at a time, like Ollama: requests queue on one thread.
package final class EmbeddedModel: @unchecked Sendable {
    package static let shared = EmbeddedModel()

    /// Where the model file is: LONGYAN_GGUF, else the app's downloaded copy, else (on a
    /// machine that has it) Ollama's copy of the same Qwen 3.5 4B Q4_K_M file.
    package static let fileName = "qwen3.5-4b-q4_k_m.gguf"
    package static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LongyanReader/models")
    }
    /// Set by an app that keeps the model somewhere of its own (the Windows app).
    nonisolated(unsafe) package static var pathOverride: String?
    package static var modelPath: String? {
        if let p = ProcessInfo.processInfo.environment["LONGYAN_GGUF"] { return p }
        if let p = pathOverride { return FileManager.default.fileExists(atPath: p) ? p : nil }
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
    package static var fileUnloadable: Bool { brokenFlag.isSet }
    private static let brokenFlag = StopFlag()
    private static let exiting = StopFlag()
    /// After a new download: try the file again.
    package func forgetLoadFailure() { Self.brokenFlag.clear(); queue.async { self.loadError = nil } }
    /// The tokens now in the context, so a request that starts the same way (the system
    /// prompt, the worked examples) only reads what's new.
    private var cached: [llama_token] = []
    /// A saved state, in pages of its own that go straight back to the system when it's dropped.
    /// (In Swift arrays, freed 58 MB blocks stayed with the process: 4 kept states grew to ~700 MB.)
    private final class Snapshot {
        let tokens: [llama_token]
        let count: Int
        let bytes: UnsafeMutableRawPointer
        init?(tokens: [llama_token], count: Int) {
            #if os(Windows)
            guard let p = VirtualAlloc(nil, SIZE_T(count), DWORD(MEM_COMMIT | MEM_RESERVE), DWORD(PAGE_READWRITE)) else { return nil }
            #else
            guard let p = mmap(nil, count, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), p != MAP_FAILED else { return nil }
            #endif
            self.tokens = tokens; self.count = count; bytes = p
        }
        #if os(Windows)
        deinit { VirtualFree(bytes, 0, DWORD(MEM_RELEASE)) }
        #else
        deinit { munmap(bytes, count) }
        #endif
    }
    private var snapshots: [Snapshot] = []
    /// Each is 58–81 MB (Qwen 3.5 4B's recurrent state is ~53 MB, plus ~0.03 MB a prompt token).
    /// In every test, each reuse was of the latest one; two cover a card's pick and translation.
    private static let maxSnapshots = 2
    /// The states after each kind of prompt's fixed start (a pick's, a translation's).
    private var prefixes: [Snapshot] = []
    private static let maxPrefixes = 2
    static let contextSize: UInt32 = 2048
    /// Like Ollama, the model (about 3 GB) is let go after five idle minutes; the next lookup,
    /// or selecting Chinese text (warmUp), loads it again in about a second.
    /// LONGYAN_IDLE_UNLOAD=seconds changes it (--pressure's wait turns it off with 0).
    private static let idleUnload: TimeInterval = {
        guard let v = ProcessInfo.processInfo.environment["LONGYAN_IDLE_UNLOAD"].flatMap(Double.init) else { return 300 }
        return v > 0 ? v : .infinity
    }()
    private var lastUse = Date()
    private var backendReady = false
    private var exitHandlerSet = false
    #if canImport(Darwin)
    private var pressure: DispatchSourceMemoryPressure?
    #endif
    private var contextFailedAt: Date?
    #if os(Windows)
    /// The loaded model runs on the GPU.
    private var onGPU = false
    #endif

    private init() {}

    /// The tokens the model may write (Resources/output-tokens.txt, scripts/make-output-tokens.py):
    /// English words and pieces, ASCII and the control tokens, 68k of Qwen 3.5's 248k. Only
    /// their rows of the output table are kept (patches/llama.cpp-output-tokens.patch), so the
    /// rest, ~380 MB of the 4B's 521 MB table, is never read. Picks only read digits; replies
    /// are English. LONGYAN_TRIM=0 keeps the whole table; so does LONGYAN_PICK=generate, whose
    /// replies repeat the Chinese words.
    private static let outputTokens: [llama_token]? = {
        let env = ProcessInfo.processInfo.environment
        guard env["LONGYAN_TRIM"] != "0", env["LONGYAN_PICK"] != "generate",
              let url = Bundle.main.url(forResource: "output-tokens", withExtension: "txt")
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/Resources/output-tokens.txt") as URL?,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let ids = text.split(separator: "\n").compactMap { llama_token($0) }
        return ids.isEmpty ? nil : ids
    }()

    /// Loads the model if needed (about a second from a warm disk cache). Safe to call often.
    /// `systems` are the instructions that start each kind of request: where prefixes are
    /// primed (`primesPrefixes`), their state is read in now, so a card reads only its own part.
    func warmUp(systems: [String] = []) {
        queue.async {
            guard (try? self.loadIfNeeded()) != nil, Self.primesPrefixes else { return }
            for text in systems { if !self.prime(text) { break } }
        }
    }

    /// Requests queued and not yet started: priming gives way to them.
    private let waitingLock = NSLock()
    private var waiting = 0
    private func queued() { waitingLock.withLock { waiting += 1 } }
    private func started() { waitingLock.withLock { waiting -= 1 } }

    /// On a CPU, where reading a prompt is most of a card's time, the state after each kind of
    /// request's instructions is kept even when they're short, and made ahead of the first card
    /// (warmUp), and a prompt reuses the longest kept start it begins with. On the Mac's GPU those
    /// ~50 tokens take ~15 ms, so it keeps its own rule (only starts of 64 tokens or more).
    /// Reading the instructions apart from the rest changes the last digits of the numbers on
    /// the CPU, and with them a near tie now and then, but toward the Mac's answers: in the speed
    /// job 1 of 27 bridge cards and 2 of 184 eval picks differ from the Mac's with it, 3 and 3
    /// without. LONGYAN_PRIME=0 turns it off.
    #if os(Windows)
    static let primesPrefixes = ProcessInfo.processInfo.environment["LONGYAN_PRIME"] != "0"
    #else
    static let primesPrefixes = ProcessInfo.processInfo.environment["LONGYAN_PRIME"] == "1"
    #endif

    /// Reads in one system turn and keeps its state as a prefix. False when a request is waiting.
    private func prime(_ system: String) -> Bool {
        guard let ctx, let model, llama_model_is_hybrid(model) || llama_model_is_recurrent(model) else { return false }
        if waitingLock.withLock({ waiting }) > 0 { return false }
        let tokens = tokenize("<|im_start|>system\n\(system)<|im_end|>\n")
        guard tokens.count >= Self.prefixMin, !prefixes.contains(where: { $0.tokens == tokens }) else { return true }
        let started = Date()
        llama_memory_clear(llama_get_memory(ctx), true)
        cached = []
        do { try decode(tokens, startingAt: 0) } catch { cached = []; return false }
        if let p = save(tokens) {
            prefixes.append(p)
            if prefixes.count > Self.maxPrefixes { prefixes.removeFirst() }
        }
        llama_memory_clear(llama_get_memory(ctx), true)
        cached = []
        if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
            FileHandle.standardError.write(Data(String(format: "timing: primed %d tokens, %.0f ms\n", tokens.count, Date().timeIntervalSince(started) * 1000).utf8))
        }
        return true
    }

    private func loadIfNeeded() throws {
        // Quitting: a request queued behind the exit handler's free must not load it again.
        if Self.exiting.isSet { throw CancellationError() }
        if ctx != nil { return }
        if let loadError { throw loadError }
        // A context that couldn't be made (short on memory) is tried again a minute later,
        // not on every selection: each try reads the whole 2.7 GB file.
        if let at = contextFailedAt, Date().timeIntervalSince(at) < 60 { throw Self.error("couldn't create a context") }
        guard let path = Self.modelPath else { throw Self.error("no model file") }
        #if os(Windows)
        _ = Self.cpu
        if Self.tooSlow { throw Self.error("too slow on this CPU") }
        #endif
        if !backendReady {
            if ProcessInfo.processInfo.environment["LONGYAN_LLAMA_LOG"] != "1" { llama_log_set({ _, _, _ in }, nil) }
            llama_backend_init()
            backendReady = true
        }
        let loadStarted = Date()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        #if os(Windows)
        // Exit (shutdown()) during a first load stops it instead of waiting for the whole file.
        mp.progress_callback = { _, _ in !EmbeddedModel.exiting.isSet }
        // The GPU only when the self-test (or LONGYAN_GPU=1) chose it, and only that one device;
        // otherwise no devices at all, so nothing but the CPU is used.
        let gpu = Self.gpuDevice()
        let devices = UnsafeMutablePointer<OpaquePointer?>.allocate(capacity: 2)
        defer { devices.deallocate() }
        devices[0] = gpu?.device; devices[1] = nil
        mp.devices = devices
        mp.n_gpu_layers = gpu.map { $0.layers } ?? 0
        if gpu != nil { Self.markGPU(true) }
        #endif
        // Trimmed, the full word table (and the small norm just before it in the file) loads on the
        // CPU side, outside the GPU's mapped range, which Metal keeps wired. Only the rows the input
        // looks up are then read; the kept output rows get a GPU copy of their own.
        let trim = Self.outputTokens != nil
        // With repacking on (LONGYAN_REPACK=1), the output table stays plain too: its kept rows are
        // copied out of it, which a repacked buffer can't give back.
        let repack = ProcessInfo.processInfo.environment["LONGYAN_REPACK"] == "1"
        let pattern = strdup(repack ? "^(token_embd|output_norm|output)\\.weight$" : "^(token_embd|output_norm)\\.weight$")
        defer { releaseCString(pattern) }
        var overrides = [llama_model_tensor_buft_override(pattern: pattern, buft: ggml_backend_cpu_buffer_type()),
                         llama_model_tensor_buft_override(pattern: nil, buft: nil)]
        let loaded = overrides.withUnsafeMutableBufferPointer { o -> OpaquePointer? in
            if trim {
                mp.tensor_buft_overrides = UnsafePointer(o.baseAddress)
                mp.use_extra_bufts = false   // else the CPU side repacks the whole table into a copy of its own
            }
            if let r = ProcessInfo.processInfo.environment["LONGYAN_REPACK"] { mp.use_extra_bufts = r == "1" }
            return llama_model_load_from_file(path, mp)
        }
        guard let m = loaded else {
            if Self.exiting.isSet { throw CancellationError() }
            #if os(Windows)
            // On the GPU: likely short of its memory. The CPU instead, at once.
            if gpu != nil { Self.markGPU(false); Self.gpuFailed("the model didn't load on the GPU"); return try loadIfNeeded() }
            #endif
            Self.brokenFlag.set()
            loadError = Self.error("couldn't load \(path)"); throw loadError!
        }
        let modelMs = Date().timeIntervalSince(loadStarted) * 1000
        if let ids = Self.outputTokens {
            let ok = ids.withUnsafeBufferPointer { llama_model_set_output_tokens(m, $0.baseAddress, Int32($0.count)) }
            if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
                FileHandle.standardError.write(Data("output rows: \(ok ? "\(ids.count) kept" : "couldn't trim")\n".utf8))
            }
        }
        var cp = llama_context_default_params()
        cp.n_ctx = Self.contextSize
        cp.n_batch = Self.contextSize
        // Only the last token's next-word odds are ever read. By default the work buffer is sized
        // for odds at every token of a batch (~250k numbers each), about 0.5 GB with nothing in it.
        cp.n_outputs_max = 1
        cp.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        cp.n_threads_batch = cp.n_threads
        #if os(Windows)
        // On the CPU every thread counts: the fast cores' threads, hyperthreads included, less one
        // for the app (with all of them, the card missed an Esc in the UI check), and only the
        // fast cores on a chip that also has slow ones. On CI's 2 cores and 4 threads, 3 write a
        // reply 1.3x as fast as 2; on a 4-core Arm, 3 make a word card 19 s -> 13 s.
        if let n = Self.fastThreads() {
            cp.n_threads = Int32(max(1, min(n - 1, 8))); cp.n_threads_batch = Int32(max(1, min(n - 1, 16)))
        }
        #endif
        let env = ProcessInfo.processInfo.environment
        if let t = env["LONGYAN_THREADS"].flatMap(Int32.init) { cp.n_threads = t; cp.n_threads_batch = t }
        if let t = env["LONGYAN_THREADS_BATCH"].flatMap(Int32.init) { cp.n_threads_batch = t }
        if let u = env["LONGYAN_UBATCH"].flatMap(UInt32.init) { cp.n_ubatch = u }
        if let f = env["LONGYAN_FA"].flatMap(Int32.init) { cp.flash_attn_type = llama_flash_attn_type(rawValue: f) }
        guard let c = llama_init_from_model(m, cp) else {
            llama_model_free(m)
            #if os(Windows)
            if gpu != nil { Self.markGPU(false); Self.gpuFailed("no context on the GPU"); return try loadIfNeeded() }
            #endif
            contextFailedAt = Date(); throw Self.error("couldn't create a context")
        }
        #if os(Windows)
        onGPU = gpu != nil
        if let gpu {
            Self.gpuNote(String(format: "loaded on the GPU: %@, %d of %d layers, %.0f ms", gpu.name, min(Int(gpu.layers), Int(llama_model_n_layer(m)) + 1),
                                Int(llama_model_n_layer(m)) + 1, Date().timeIntervalSince(loadStarted) * 1000))
        }
        #endif
        if env["LONGYAN_TIMING"] == "1" {
            FileHandle.standardError.write(Data(String(format: "timing: load %.0f ms (model %.0f ms), threads %d/%d, ubatch %d, repack %@, flash attention %d, %d logical CPUs\n",
                Date().timeIntervalSince(loadStarted) * 1000, modelMs, cp.n_threads, cp.n_threads_batch, cp.n_ubatch,
                mp.use_extra_bufts ? "on" : "off", cp.flash_attn_type.rawValue, ProcessInfo.processInfo.activeProcessorCount).utf8))
            #if os(Windows)
            FileHandle.standardError.write(Data("timing: \(Self.fastThreads().map(String.init) ?? "?") fast threads\n".utf8))
            #endif
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
        // On an 8 GB Mac the model is most of what the app uses. When memory runs short the
        // saved states go first (up to ~230 MB); if it's critical the model goes too, and the
        // next lookup loads it again. The handler runs on the queue, so never mid-request.
        // (Apple's systems only: other platforms' apps call `relieve` from their own signal.)
        #if canImport(Darwin)
        if pressure == nil {
            let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            src.setEventHandler { [unowned self, unowned src] in
                self.relieve(critical: src.data.contains(.critical))
            }
            src.resume()
            pressure = src
        }
        #endif
        noteUse()
    }

    /// Memory is short: the saved states go; if it's critical, the model too.
    private func relieve(critical: Bool) {
        if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
            FileHandle.standardError.write(Data("memory pressure: \(critical ? "critical" : "warning") at \(Date().formatted(date: .omitted, time: .standard))\n".utf8))
        }
        snapshots = []; prefixes = []
        if critical, ctx != nil { free() }
    }

    /// For --pressure: what the handler would do, run as if macOS had sent it.
    package func simulatePressure(critical: Bool) { queue.sync { relieve(critical: critical) } }

    /// For --pressure: whether the model is loaded, and the saved states it holds.
    package func memoryState() -> (loaded: Bool, states: Int, stateMB: Double) {
        queue.sync { (ctx != nil, snapshots.count + prefixes.count, Double((snapshots + prefixes).reduce(0) { $0 + $1.count }) / 1e6) }
    }

    /// Quitting: waits out a load or request in progress (a request stops at its next token),
    /// then frees the model, before exit() starts tearing down ggml. The exit handler only
    /// exists once a load has finished, so a quit during the first load needs this.
    package func shutdown() {
        Self.exiting.set()
        if DispatchQueue.getSpecific(key: Self.onQueue) != nil { free() } else { queue.sync { free() } }
    }

    /// Called on the queue after each load and request.
    private func noteUse() {
        lastUse = Date()
        guard Self.idleUnload.isFinite else { return }
        queue.asyncAfter(deadline: .now() + Self.idleUnload + 1) {
            if self.ctx != nil, Date().timeIntervalSince(self.lastUse) >= Self.idleUnload { self.free() }
        }
    }

    private func free() {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; vocab = nil; cached = []; snapshots = []; prefixes = []
        #if os(Windows)
        if onGPU { onGPU = false; Self.markGPU(false) }
        #endif
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
            queued()
            queue.async {
                self.started()
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

    private func save(_ tokens: [llama_token]) -> Snapshot? {
        guard let ctx else { return nil }
        let size = llama_state_seq_get_size(ctx, 0)
        guard let snap = Snapshot(tokens: tokens, count: size),
              llama_state_seq_get_data(ctx, snap.bytes.assumingMemoryBound(to: UInt8.self), size, 0) == size else { return nil }
        return snap
    }

    private func restore(_ snap: Snapshot) -> Bool {
        guard let ctx else { return false }
        return llama_state_seq_set_data(ctx, snap.bytes.assumingMemoryBound(to: UInt8.self), snap.count, 0) > 0
    }

    /// Reads a prompt into the context, reusing what's already there, and leaves the logits
    /// for what comes after its last token. Returns how many tokens were reused.

    private var imStart: llama_token { tokenize("<|im_start|>").first ?? -1 }
    /// The shortest fixed start worth keeping a state for.
    private static let prefixMin: Int = ProcessInfo.processInfo.environment["LONGYAN_PREFIX_MIN"].flatMap(Int.init)
        ?? (primesPrefixes ? 16 : 64)

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
            let timing = ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1"
            if let i = snapshots.firstIndex(where: { $0.tokens == body }), restore(snapshots[i]) {
                if timing { FileHandle.standardError.write(Data("snapshot hit: \(snapshots.count - 1 - i) back\n".utf8)) }
                snapshots.append(snapshots.remove(at: i))   // most recently used last
                cached = body
                keep = body.count
            } else {
                // The fixed start of the prompt (the instructions and worked examples, up to the
                // last user turn) is the same for every lookup of a kind, so its state is kept
                // too, and a new passage reads only its own turn.
                let starts = body.indices.filter { body[$0] == imStart }
                let cut = starts.count >= 2 ? starts[starts.count - 2] : 0
                // Where prefixes are primed, the system turn alone may be kept, and a prompt with
                // worked examples after it starts from that.
                let fits: (Snapshot) -> Bool = Self.primesPrefixes
                    ? { $0.tokens.count <= cut && body.starts(with: $0.tokens) }
                    : { $0.tokens.count == cut && body.starts(with: $0.tokens) }
                let found = prefixes.indices.filter { fits(prefixes[$0]) }.max { prefixes[$0].tokens.count < prefixes[$1].tokens.count }
                if cut >= Self.prefixMin, let i = found, restore(prefixes[i]) {
                    prefixes.append(prefixes.remove(at: i))
                    cached = prefixes.last!.tokens
                    keep = cached.count
                    if timing { FileHandle.standardError.write(Data("prefix hit: \(keep) tokens\n".utf8)) }
                } else if cut >= Self.prefixMin {
                    llama_memory_clear(memory, true)
                    try decode(Array(body[..<cut]), startingAt: 0)
                    if let p = save(Array(body[..<cut])) {
                        prefixes.append(p)
                        if prefixes.count > Self.maxPrefixes { prefixes.removeFirst() }
                    }
                } else {
                    llama_memory_clear(memory, true)
                }
                try decode(Array(body[cached.count...]), startingAt: cached.count)
                if let snap = save(body) {
                    snapshots.append(snap)
                    if snapshots.count > Self.maxSnapshots { snapshots.removeFirst() }
                    if timing {
                        let all = snapshots + prefixes
                        FileHandle.standardError.write(Data(String(format: "snapshot: %d tokens, %.1f MB; %d kept, %.1f MB\n", body.count,
                            Double(snap.count) / 1e6, all.count, Double(all.reduce(0) { $0 + $1.count }) / 1e6).utf8))
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
            queued()
            queue.async {
                self.started()
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
                    let promptMs = Date().timeIntervalSince(started) * 1000
                    var pending: [llama_token] = []
                    for (i, step) in steps.enumerated() {
                        if stop.isSet || Self.exiting.isSet { throw CancellationError() }
                        if i > 0 { try self.decode(pending + self.tokenize(step.text), startingAt: self.cached.count) }
                        let (pick, rest) = try self.readNumber(upTo: step.count, digits: digits.map { $0[0] })
                        pending = rest
                        continuation.yield(pick)
                    }
                    if ProcessInfo.processInfo.environment["LONGYAN_TIMING"] == "1" {
                        FileHandle.standardError.write(Data(String(format: "timing: pick, prompt %d tok (%d new) %.0f ms, %d numbers, %.0f ms\n",
                            tokens.count, tokens.count - keep, promptMs, steps.count, Date().timeIntervalSince(started) * 1000).utf8))
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

    private func decode(_ tokens: [llama_token], startingAt pos: Int, allLogits: Bool = false) throws {
        guard let ctx, !tokens.isEmpty else { return }
        guard decodeRaw(ctx, tokens, at: pos, allLogits: allLogits) else {
            cached = []
            #if os(Windows)
            // A GPU that fails mid-card: the next request loads the model on the CPU.
            if onGPU { Self.gpuFailed("a decode failed on the GPU"); queue.async { self.free() } }
            #endif
            throw Self.error("decode failed")
        }
        cached += tokens
    }

    private func decodeRaw(_ ctx: OpaquePointer, _ tokens: [llama_token], at pos: Int, allLogits: Bool = false) -> Bool {
        guard !tokens.isEmpty else { return true }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (i, t) in tokens.enumerated() {
            batch.token[i] = t
            batch.pos[i] = Int32(pos + i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = allLogits || i == tokens.count - 1 ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        return llama_decode(ctx, batch) == 0
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

/// A thread-safe yes/no: stop a decode, or note that a reply was cut short.
package final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
    var isSet: Bool { lock.withLock { value } }
}

/// The C library's free, for a string from strdup.
private func releaseCString(_ p: UnsafeMutablePointer<CChar>?) {
    #if canImport(Darwin)
    Darwin.free(p)
    #else
    free(p)
    #endif
}

#if os(Windows)
extension EmbeddedModel {
    nonisolated(unsafe) private static var backendLog = ""

    /// The logical processors of the CPU's cores; on a chip with performance and efficiency
    /// cores, of the performance ones.
    fileprivate static func fastThreads() -> Int? {
        var length: DWORD = 0
        _ = GetLogicalProcessorInformationEx(RelationProcessorCore, nil, &length)
        guard length > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(length), alignment: 8)
        defer { buffer.deallocate() }
        guard GetLogicalProcessorInformationEx(RelationProcessorCore, buffer.assumingMemoryBound(to: SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX.self), &length) else { return nil }
        var cores: [(efficiency: UInt8, threads: Int)] = []
        var offset = 0
        while offset < Int(length) {
            let info = (buffer + offset).assumingMemoryBound(to: SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX.self)
            let mask = UInt64(info.pointee.Processor.GroupMask.Mask)
            cores.append((info.pointee.Processor.EfficiencyClass, max(1, mask.nonzeroBitCount)))
            offset += Int(info.pointee.Size)
        }
        guard let top = cores.map(\.efficiency).max() else { return nil }
        let n = cores.filter { $0.efficiency == top }.reduce(0) { $0 + $1.threads }
        return n > 0 ? n : nil
    }

    /// The CPU kernels are ggml-cpu-*.dll beside the app, one per kind of CPU (x64 and sse42 up
    /// to AVX-512 with VNNI). ggml loads the best one this CPU runs, so a laptop without AVX2
    /// gets the SSE 4.2 kernels instead of an illegal instruction. LONGYAN_CPU=sse42 (or another
    /// variant's name) loads that one instead, if this CPU can run it. LONGYAN_BACKEND_LOG=file
    /// adds a line there saying what was loaded.
    fileprivate static func loadCPUBackend() -> (loaded: Bool, features: Set<String>) {
        let env = ProcessInfo.processInfo.environment
        backendLog = ""
        llama_log_set({ _, text, _ in
            if let text { EmbeddedModel.backendLog += String(cString: text) }
        }, nil)
        if let v = env["LONGYAN_CPU"], !v.isEmpty,
           let dir = Bundle.main.executableURL?.deletingLastPathComponent() {
            _ = dir.appendingPathComponent("ggml-cpu-\(v).dll").withUnsafeFileSystemRepresentation { p in
                p.flatMap { ggml_backend_load($0) }
            }
        }
        if ggml_backend_reg_count() == 0 { ggml_backend_load_all() }
        llama_log_set(nil, nil)

        // The DLL ggml took, and the features it was built with.
        let from = backendLog.split(whereSeparator: \.isNewline)
            .first { $0.contains("loaded CPU backend from") }
            .map { String($0.split(separator: "\\").last ?? "") } ?? "none"
        var features: [String] = []
        if let reg = ggml_backend_reg_by_name("CPU"),
           let fn = ggml_backend_reg_get_proc_address(reg, "ggml_backend_get_features") {
            let get = unsafeBitCast(fn, to: ggml_backend_get_features_t.self)
            var f = get(reg)
            while let name = f?.pointee.name {
                features.append(String(cString: name)); f = f?.successor()
            }
        }
        let cpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU).flatMap { ggml_backend_dev_description($0) }
            .map { String(cString: $0) } ?? "?"
        let line = "llama.cpp CPU backend: \(from) (\(features.joined(separator: " "))) on \(cpu)\n"
        log(line)
        return (from != "none", Set(features))
    }

    /// A line for LONGYAN_BACKEND_LOG's file (and stderr with LONGYAN_TIMING=1).
    fileprivate static func log(_ line: String) {
        let env = ProcessInfo.processInfo.environment
        if env["LONGYAN_TIMING"] == "1" { FileHandle.standardError.write(Data(line.utf8)) }
        if let path = env["LONGYAN_BACKEND_LOG"], let h = FileHandle(forWritingAtPath: path) ?? {
            FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil
        }() {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        }
    }

    // MARK: The GPU

    /// The GPU backends ship in the app's gpu folder (ggml-vulkan.dll on x64, ggml-opencl.dll on
    /// ARM64), out of the folder ggml_backend_load_all reads, so they load only when asked for:
    /// a missing or broken driver can't take the app down unless the self-test passed on it.
    package static var defaultGPUBackend: String {
        #if arch(arm64)
        return "opencl"
        #else
        return "vulkan"
        #endif
    }

    /// Set by the app from the self-test's choice: the backend and how many layers go on the GPU.
    /// nil: the CPU only. LONGYAN_GPU=0 keeps the CPU whatever this says; LONGYAN_GPU=1 uses the
    /// GPU without the test (LONGYAN_GPU_BACKEND, LONGYAN_GPU_LAYERS, default all layers).
    nonisolated(unsafe) package static var gpuChoice: (backend: String, layers: Int32)?
    /// Called with each GPU line for the app's log, and when the GPU failed in this process.
    nonisolated(unsafe) package static var onGPUNote: ((String) -> Void)?
    nonisolated(unsafe) package static var onGPUFailure: ((String) -> Void)?
    /// The GPU failed in this process: the CPU from now on.
    private static let gpuBroken = StopFlag()
    nonisolated(unsafe) private static var selfTesting = false
    nonisolated(unsafe) private static var gpuRegs: [String: OpaquePointer] = [:]
    nonisolated(unsafe) private static var gpuLoadLog: [String: String] = [:]

    /// Uses the GPU from the next load on (the model loaded now is let go). nil: the CPU.
    package func useGPU(_ choice: (backend: String, layers: Int32)?) {
        queue.async {
            let old = Self.gpuChoice
            Self.gpuChoice = choice
            if choice != nil { Self.gpuBroken.clear() }
            if old?.backend != choice?.backend || old?.layers != choice?.layers, self.ctx != nil { self.free() }
        }
    }

    /// The device to load the model on, and how many layers, or nil for the CPU.
    fileprivate static func gpuDevice() -> (device: OpaquePointer, layers: Int32, name: String)? {
        let env = ProcessInfo.processInfo.environment
        if env["LONGYAN_GPU"] == "0" || gpuBroken.isSet { return nil }
        var choice = gpuChoice
        if env["LONGYAN_GPU"] == "1", !selfTesting {
            choice = (env["LONGYAN_GPU_BACKEND"] ?? defaultGPUBackend, env["LONGYAN_GPU_LAYERS"].flatMap(Int32.init) ?? 99)
        }
        guard let choice else { return nil }
        switch device(choice.backend) {
        case .success(let d): return (d.device, choice.layers, d.name)
        case .failure(let why): gpuFailed(why.message); return nil
        }
    }

    struct GPUProblem: Error { let message: String }
    struct GPUDevice { let device: OpaquePointer; let name: String; let integrated: Bool }

    /// Loads gpu\ggml-<backend>.dll once and finds its device: a discrete GPU first, else an
    /// integrated one (llama.cpp's own order).
    fileprivate static func device(_ backend: String) -> Result<GPUDevice, GPUProblem> {
        // The CPU kernels first: they load only while no other backend is registered.
        _ = cpu
        let reg: OpaquePointer
        if let r = gpuRegs[backend] {
            reg = r
        } else {
            guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return .failure(GPUProblem(message: "no app folder")) }
            let file = dir.appendingPathComponent("gpu").appendingPathComponent("ggml-\(backend).dll")
            guard FileManager.default.fileExists(atPath: file.path) else { return .failure(GPUProblem(message: "no gpu\\ggml-\(backend).dll")) }
            backendLog = ""
            llama_log_set({ _, text, _ in
                if let text { EmbeddedModel.backendLog += String(cString: text) }
            }, nil)
            let loaded = file.withUnsafeFileSystemRepresentation { p in p.flatMap { ggml_backend_load($0) } }
            if ProcessInfo.processInfo.environment["LONGYAN_LLAMA_LOG"] == "1" { llama_log_set(nil, nil) } else { llama_log_set({ _, _, _ in }, nil) }
            let lines = backendLog.split(whereSeparator: \.isNewline).map(String.init)
                .filter { $0.contains("ggml_") || $0.contains("load") || $0.contains("Vulkan") || $0.contains("OpenCL") }
            gpuLoadLog[backend] = lines.prefix(12).joined(separator: " | ")
            guard let r = loaded else {
                return .failure(GPUProblem(message: "\(backend) didn't load (no driver?): " + (gpuLoadLog[backend] ?? "")))
            }
            gpuRegs[backend] = r
            reg = r
        }
        var integrated: GPUDevice?
        for i in 0..<ggml_backend_reg_dev_count(reg) {
            guard let dev = ggml_backend_reg_dev_get(reg, i) else { continue }
            let type = ggml_backend_dev_type(dev)
            let name = ggml_backend_dev_description(dev).map { String(cString: $0) } ?? "?"
            if type == GGML_BACKEND_DEVICE_TYPE_GPU { return .success(GPUDevice(device: dev, name: name, integrated: false)) }
            if type == GGML_BACKEND_DEVICE_TYPE_IGPU, integrated == nil { integrated = GPUDevice(device: dev, name: name, integrated: true) }
        }
        if let integrated { return .success(integrated) }
        return .failure(GPUProblem(message: "no \(backend) GPU on this PC" + ((gpuLoadLog[backend] ?? "").isEmpty ? "" : ": " + gpuLoadLog[backend]!)))
    }

    /// %LOCALAPPDATA%\LongyanReader\gpu-in-use, there while the app's model is on the GPU. Still
    /// there after a crash, so the app's next start blames the GPU and keeps the CPU.
    fileprivate static func markGPU(_ on: Bool) {
        guard !selfTesting, let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"] else { return }
        let path = base + "\\LongyanReader\\gpu-in-use"
        if on { FileManager.default.createFile(atPath: path, contents: Data((gpuChoice?.backend ?? "gpu").utf8)) }
        else { try? FileManager.default.removeItem(atPath: path) }
    }

    fileprivate static func gpuNote(_ line: String) {
        log("gpu: " + line + "\n")
        onGPUNote?(line)
    }

    fileprivate static func gpuFailed(_ why: String) {
        gpuBroken.set()
        gpuNote("the CPU instead: " + why)
        onGPUFailure?(why)
    }

    /// A pick read from scratch (no kept states), timed. On the queue.
    private func timedPick(_ messages: [[String: String]], _ steps: [(text: String, count: Int)]) throws -> (numbers: [Int], confidence: [Double], ms: Double, tokens: Int) {
        snapshots = []; prefixes = []; cached = []
        if let ctx { llama_memory_clear(llama_get_memory(ctx), true) }
        let started = Date()
        let digits = (0...9).map { tokenize(String($0)) }
        guard digits.allSatisfy({ $0.count == 1 }), let first = steps.first else { throw Self.error("digits aren't single tokens") }
        let tokens = tokenize(Self.render(messages) + first.text)
        _ = try read(tokens)
        var pending: [llama_token] = []
        var numbers: [Int] = [], confidence: [Double] = []
        for (i, step) in steps.enumerated() {
            if i > 0 { try decode(pending + tokenize(step.text), startingAt: cached.count) }
            let (pick, rest) = try readNumber(upTo: step.count, digits: digits.map { $0[0] })
            pending = rest
            numbers.append(pick.number); confidence.append((pick.confidence * 1000).rounded() / 1000)
        }
        return (numbers, confidence, (Date().timeIntervalSince(started) * 1000).rounded(), tokens.count)
    }

    /// The GPU self-test, run in a process of its own (LongyanReader.exe --gpu-test) so a broken
    /// driver can only take that one down. The GPU's device first (none: done), then the pick on
    /// the CPU, then on the GPU twice (the
    /// first run builds the GPU's shaders); the GPU is kept only if it gives the same numbers and
    /// is faster. An integrated GPU shares the PC's memory: when the device has less free than
    /// the model needs, only as many layers as fit go on it; when a load fails, half as many.
    package static func gpuSelfTest(backend: String, messages: [[String: String]], steps: [(text: String, count: Int)]) -> [String: Any] {
        selfTesting = true
        let m = shared
        return m.queue.sync { () -> [String: Any] in
            var r: [String: Any] = ["backend": backend, "use": false]
            func finish(_ why: String, use: Bool = false) -> [String: Any] {
                m.free(); gpuChoice = nil
                r["use"] = use; r["why"] = why
                if let l = gpuLoadLog[backend], !l.isEmpty { r["log"] = l }
                return r
            }
            // The device first: on a PC without one, that's the whole test.
            let dev: GPUDevice
            switch device(backend) {
            case .success(let d): dev = d
            case .failure(let why): return finish(why.message)
            }
            r["device"] = dev.name; r["integrated"] = dev.integrated
            gpuChoice = nil
            do { try m.loadIfNeeded() } catch { return finish("the model didn't load on the CPU: \(error.localizedDescription)") }
            guard let model = m.model else { return finish("no model") }
            let layerCount = Int(llama_model_n_layer(model)) + 1   // and the output layer
            r["layerCount"] = layerCount
            let cpu: (numbers: [Int], confidence: [Double], ms: Double, tokens: Int)
            do { cpu = try m.timedPick(messages, steps) } catch { return finish("the pick failed on the CPU: \(error.localizedDescription)") }
            r["cpuMs"] = cpu.ms; r["cpuPicks"] = cpu.numbers; r["cpuConfidence"] = cpu.confidence; r["promptTokens"] = cpu.tokens
            m.free()

            var free = 0, total = 0
            ggml_backend_dev_memory(dev.device, &free, &total)
            r["freeMB"] = free >> 20; r["totalMB"] = total >> 20
            let fileBytes = (modelPath.flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int }) ?? 0
            // Room for the context, the work buffers and the shaders beside the weights.
            let spare = 768 << 20
            var layers = layerCount
            if free > 0, fileBytes > 0, free < fileBytes + spare {
                layers = max(0, Int(Double(free - spare) / (Double(fileBytes) / Double(layerCount))))
            }
            if let l = ProcessInfo.processInfo.environment["LONGYAN_GPU_LAYERS"].flatMap(Int.init) { layers = min(l, layerCount) }
            if layers < max(1, layerCount / 4) && ProcessInfo.processInfo.environment["LONGYAN_GPU_LAYERS"] == nil {
                return finish("not enough GPU memory: \(free >> 20) MB free, the model is \(fileBytes >> 20) MB")
            }
            var tries = [layers]
            if layers / 2 >= max(1, layerCount / 4) { tries.append(layers / 2) }
            var why = ""
            for l in tries {
                gpuBroken.clear()
                gpuChoice = (backend, Int32(l))
                do { try m.loadIfNeeded() } catch { why = "the model didn't load on the GPU: \(error.localizedDescription)"; m.free(); continue }
                guard m.onGPU else { why = "the model didn't load on the GPU with \(l) layers"; m.free(); continue }
                r["layers"] = l
                do {
                    let first = try m.timedPick(messages, steps)
                    let gpu = try m.timedPick(messages, steps)
                    r["gpuFirstMs"] = first.ms; r["gpuMs"] = gpu.ms; r["gpuPicks"] = gpu.numbers; r["gpuConfidence"] = gpu.confidence
                    r["speedup"] = gpu.ms > 0 ? (cpu.ms / gpu.ms * 10).rounded() / 10 : 0
                    if gpu.numbers != cpu.numbers || first.numbers != cpu.numbers {
                        return finish("the GPU's answer differs from the CPU's (\(gpu.numbers) against \(cpu.numbers))")
                    }
                    if gpu.ms >= cpu.ms * 0.9 {
                        return finish(String(format: "the GPU is no faster (%.0f ms against %.0f ms on the CPU)", gpu.ms, cpu.ms))
                    }
                    return finish(String(format: "the same answer, %.1fx as fast", cpu.ms / max(gpu.ms, 1)), use: true)
                } catch {
                    why = "the pick failed on the GPU: \(error.localizedDescription)"
                    m.free()
                    if gpuBroken.isSet { continue }
                    break
                }
            }
            return finish(why.isEmpty ? "the GPU didn't work" : why)
        }
    }

    // MARK: Too slow for the model

    /// The CPU kernels, loaded once (a few DLLs, no model): what they say decides `tooSlow`.
    private static let cpu: (loaded: Bool, features: Set<String>) = {
        let c = EmbeddedModel.loadCPUBackend()
        #if arch(x86_64)
        let fast = c.features.contains("AVX2") && c.features.contains("FMA")
        if c.loaded { EmbeddedModel.log("too slow for the model by CPU features: \(fast ? "no" : "yes")\(EmbeddedModel.emulated ? " (x64 emulated on ARM64)" : "")\n") }
        #else
        if c.loaded { EmbeddedModel.log("too slow for the model: no (not x64, no CPU feature rule)\n") }
        #endif
        return c
    }()

    /// Set by the app from its settings ("allowSlowModel"): use the model however slow.
    /// LONGYAN_ALLOW_SLOW=1 does the same.
    nonisolated(unsafe) package static var allowSlow = false

    /// This x64 build runs under emulation on an ARM PC (Snapdragon): it gets the SSE 4.2
    /// kernels and is too slow, though the PC isn't. A native ARM64 build would be fast.
    package static let emulated: Bool = {
        var process: USHORT = 0, native: USHORT = 0
        guard IsWow64Process2(GetCurrentProcess(), &process, &native) else { return false }
        return native == 0xAA64   // IMAGE_FILE_MACHINE_ARM64
    }()

    /// Whether this PC is too slow for the model, so it isn't loaded at all and cards use
    /// dictionary order. On x64 it needs AVX2 and FMA. On the CI runner (4 cores), word cards
    /// took 15 to 17 s on the AVX2 kernels and 28 to 33 s on the AVX-only ones (prompts read at
    /// 28 and 13 tokens a second); on SSE 4.2, 1 token a second, so a card never settles.
    package static var tooSlow: Bool {
        if allowSlow || ProcessInfo.processInfo.environment["LONGYAN_ALLOW_SLOW"] == "1" { return false }
        #if arch(x86_64)
        return cpu.loaded && !(cpu.features.contains("AVX2") && cpu.features.contains("FMA"))
        #else
        // A native ARM64 build: its kernels are NEON, never AVX2, and it is fast enough.
        _ = cpu
        return false
        #endif
    }
}
#endif

#if !os(Windows)
extension EmbeddedModel {
    /// Only checked on Windows: every Mac the app runs on is fast enough.
    package static var tooSlow: Bool { false }
    package static var emulated: Bool { false }
}
#endif
