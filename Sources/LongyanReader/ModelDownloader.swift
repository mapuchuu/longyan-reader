import CryptoKit
import Foundation

/// Downloads the local model (Qwen 3.5 4B, Q4_K_M, Apache 2.0) into
/// ~/Library/Application Support/LongyanReader/models/. Tries hf-mirror.com first (reachable
/// from mainland China), then huggingface.co; keeps the file only if its SHA-256 matches. It's
/// the same file Ollama's qwen3.5:4b uses, which the evals ran on.
///
/// The file comes in 32 MB pieces over several connections at once. On a bad link one
/// connection can crawl at 25 KB/s (more than a day for 2.7 GB) while others to the same host
/// run at 0.5 MB/s, so a piece that stalls is dropped and asked for again on a new connection:
/// 16 of them got 3 MB/s where one got 25 KB/s. Finished pieces are listed in a file beside
/// the download, with how far each unfinished one got, so a stop or quit costs at most a few
/// seconds of data.
@MainActor
final class ModelDownloader: NSObject {
    static let shared = ModelDownloader()

    /// LONGYAN_DOWNLOAD_TEST=folder: fetch Qwen 3.5 0.8B (0.5 GB) into that folder instead,
    /// to test the downloader (`--download`) without touching the real model.
    nonisolated static let testFolder = ProcessInfo.processInfo.environment["LONGYAN_DOWNLOAD_TEST"]
    nonisolated static let path = testFolder == nil
        ? "unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf"
        : "unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf"
    nonisolated static let hosts = ["https://hf-mirror.com/", "https://huggingface.co/"]
    nonisolated static let size: Int64 = testFolder == nil ? 2_740_937_888 : 532_517_120
    nonisolated static let sha256 = testFolder == nil
        ? "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
        : "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517"
    nonisolated static let pieceSize: Int64 = 32 << 20
    nonisolated static let pieceCount = Int((size + pieceSize - 1) / pieceSize)
    /// Connections at once. Each piece gets its own URLSession, so they're separate TCP
    /// connections and not streams sharing one HTTP/2 connection (which would crawl together).
    nonisolated static let connections = 8
    /// A piece slower than this over `stallWindow` is asked for again on a new connection.
    nonisolated static let stallRate = 50_000.0
    nonisolated static let stallWindow: TimeInterval = 20

    enum State: Equatable { case idle, downloading(Double), verifying, failed(String), done }
    private(set) var state: State = .idle { didSet { observers.forEach { $0() } } }
    private var observers: [() -> Void] = []
    /// Called on every state change: the menu and the welcome window both follow the download.
    func observe(_ f: @escaping () -> Void) { observers.append(f) }

    private var folder: URL { Self.testFolder.map { URL(fileURLWithPath: $0) } ?? EmbeddedModel.modelsDirectory }
    private var target: URL { folder.appendingPathComponent(EmbeddedModel.fileName) }
    private var partial: URL { target.appendingPathExtension("part") }
    /// The pieces already in the .part file, one number per line; an unfinished one has its
    /// next byte after the number.
    private var ledger: URL { target.appendingPathExtension("pieces") }

    /// One piece being fetched: its byte range, how far it has got, and its connection.
    private final class Piece {
        let index: Int
        let start: Int64, end: Int64      // inclusive
        var next: Int64                    // the next byte to write
        var session: URLSession?
        var host = 0
        var windowStart = Date(), windowBytes: Int64 = 0
        init(_ i: Int, from: Int64? = nil) {
            index = i
            start = Int64(i) * ModelDownloader.pieceSize
            end = min(ModelDownloader.size, start + ModelDownloader.pieceSize) - 1
            next = min(max(from ?? start, start), end + 1)
        }
        var done: Bool { next > end }
    }

    private var finished = Set<Int>()
    private var started: [Int: Int64] = [:]           // unfinished pieces from the ledger: next byte
    private var waiting: [Int] = []
    private var active: [Int: Piece] = [:]           // by piece number
    private var bySession: [ObjectIdentifier: Piece] = [:]
    private var handle: FileHandle?
    private var watchdog: Timer?
    private var lastShown = 0.0
    private var host = 0
    private var failuresSinceProgress = 0
    private var lastProblem: String?   // why the last reply or connection failed, for the failure message

    var isRunning: Bool {
        switch state { case .downloading, .verifying: true; default: false }
    }

    func start() {
        guard !isRunning else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let problem = spaceProblem() { state = .failed(problem); return }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            try? FileManager.default.removeItem(at: ledger)
        }
        (finished, started) = loadLedger()
        // Listed at once (even if empty): pieces land anywhere in the file, so its size no
        // longer says how much of it is good.
        writeLedger()
        if finished.count == Self.pieceCount { verify(); return }
        guard let h = try? FileHandle(forWritingTo: partial) else {
            // Without it every byte would be thrown away, and the whole download called damaged.
            state = .failed("can't write to \(partial.deletingLastPathComponent().path)"); return
        }
        handle = h
        // Unfinished pieces first, so their bytes are kept.
        waiting = (0..<Self.pieceCount).filter { !finished.contains($0) }.sorted { (started[$0] != nil ? 0 : 1) < (started[$1] != nil ? 0 : 1) }
        host = 0; failuresSinceProgress = 0; lastProblem = nil
        lastShown = progress
        state = .downloading(lastShown)
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkStalls() }
        }
        fill()
    }

    /// Why the disk can't take the rest of the download, or nil. Asks for what's left to fetch
    /// plus 1 GB, so the download doesn't leave the disk full (checking reads the file in
    /// place, and finishing is a rename, so neither needs more).
    func spaceProblem() -> String? {
        let dir = folder
        let have = min(Self.size, Int64(loadLedger().finished.count) * Self.pieceSize)
        let need = max(0, Self.size - have) + 1_000_000_000
        let probe = FileManager.default.fileExists(atPath: dir.path) ? dir : FileManager.default.homeDirectoryForCurrentUser
        guard let free = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < need else { return nil }
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1e9) }
        return "needs \(gb(need)) free and the disk has \(gb(free))"
    }

    func cancel() {
        stopAll()
        state = .idle   // the .part file and its list of pieces stay, so the next start resumes
    }

    private func stopAll() {
        if handle != nil { saveLedger() }
        watchdog?.invalidate(); watchdog = nil
        for p in active.values { p.session?.invalidateAndCancel() }
        active = [:]; bySession = [:]; waiting = []
        try? handle?.close(); handle = nil
    }

    private var progress: Double {
        let inFlight = active.values.reduce(Int64(0)) { $0 + ($1.next - $1.start) }
            + started.reduce(Int64(0)) { $0 + ($1.value - Piece($1.key).start) }
        let whole = Int64(finished.count) * Self.pieceSize - (finished.contains(Self.pieceCount - 1) ? Int64(Self.pieceCount) * Self.pieceSize - Self.size : 0)
        return Double(whole + inFlight) / Double(Self.size)
    }

    // MARK: pieces

    private func fill() {
        while active.count < Self.connections, !waiting.isEmpty {
            let i = waiting.removeFirst()
            let p = Piece(i, from: started.removeValue(forKey: i))
            active[p.index] = p
            request(p)
        }
        if active.isEmpty && waiting.isEmpty && finished.count == Self.pieceCount {
            stopAll(); verify()
        }
    }

    /// Asks for what's left of the piece on a new connection.
    private func request(_ p: Piece) {
        if let old = p.session { bySession[ObjectIdentifier(old)] = nil; old.invalidateAndCancel() }
        p.host = host
        var req = URLRequest(url: URL(string: Self.hosts[host] + Self.path)!)
        req.setValue("bytes=\(p.next)-\(p.end)", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        let s = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        p.session = s
        p.windowStart = Date(); p.windowBytes = 0
        bySession[ObjectIdentifier(s)] = p
        s.dataTask(with: req).resume()
    }

    /// A piece that went wrong: after three failures in a row with nothing received the next
    /// host is tried, and after every host has failed three times the download stops.
    private func retry(_ p: Piece, because problem: String) {
        lastProblem = problem
        failuresSinceProgress += 1
        if failuresSinceProgress % 3 == 0 { host = (host + 1) % Self.hosts.count }
        if failuresSinceProgress >= 3 * Self.hosts.count * 2 {
            stopAll()
            state = .failed(problem)
            return
        }
        // A moment's pause, so a host that's down isn't asked again many times a second.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.active[p.index] === p else { return }
                self.request(p)
            }
        }
    }

    private func checkStalls() {
        saveLedger()
        let now = Date()
        for p in active.values where now.timeIntervalSince(p.windowStart) >= Self.stallWindow {
            let rate = Double(p.windowBytes) / now.timeIntervalSince(p.windowStart)
            if rate < Self.stallRate { request(p) } else { p.windowStart = now; p.windowBytes = 0 }
        }
    }

    private func finish(_ p: Piece) {
        p.session?.finishTasksAndInvalidate()
        if let s = p.session { bySession[ObjectIdentifier(s)] = nil }
        active[p.index] = nil
        finished.insert(p.index)
        saveLedger()
        fill()
    }

    private func loadLedger() -> (finished: Set<Int>, started: [Int: Int64]) {
        if let text = try? String(contentsOf: ledger, encoding: .utf8) {
            var done = Set<Int>(), part: [Int: Int64] = [:]
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ")
                guard let i = f.first.flatMap({ Int($0) }), (0..<Self.pieceCount).contains(i) else { continue }
                if f.count > 1, let n = Int64(f[1]) { part[i] = n } else { done.insert(i) }
            }
            return (done, part)
        }
        // A .part file from the single-connection downloader: its whole pieces are good.
        let have = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        return (Set(0..<Int(min(have, Self.size) / Self.pieceSize)), [:])
    }

    /// Written only after the bytes are on disk, so the ledger never claims more than is there.
    private func saveLedger() {
        try? handle?.synchronize()
        writeLedger()
    }

    private func writeLedger() {
        let lines = finished.sorted().map(String.init)
            + active.values.filter { $0.next > $0.start }.map { "\($0.index) \($0.next)" }
            + started.map { "\($0.key) \($0.value)" }
        try? lines.joined(separator: "\n").write(to: ledger, atomically: true, encoding: .utf8)
    }

    // MARK: checking

    private func verify() {
        state = .verifying
        let partial = self.partial, target = self.target, ledger = self.ledger
        Task.detached(priority: .utility) {
            let ok = Self.hash(of: partial) == Self.sha256
            await MainActor.run {
                if ok {
                    try? FileManager.default.removeItem(at: target)
                    do {
                        try FileManager.default.moveItem(at: partial, to: target)
                        try? FileManager.default.removeItem(at: ledger)
                        if Self.testFolder == nil { EmbeddedModel.shared.forgetLoadFailure() }
                        self.state = .done
                    }
                    catch { self.state = .failed(error.localizedDescription) }
                } else {
                    // A corrupt file can't be resumed into a good one.
                    // Removed, not trashed: 2.7 GB in the Trash would fail the next space check.
                    try? FileManager.default.removeItem(at: partial)
                    try? FileManager.default.removeItem(at: ledger)
                    self.state = .failed("the file was damaged")
                }
            }
        }
    }

    nonisolated static func hash(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelDownloader: URLSessionDataDelegate {
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
        let ok = MainActor.assumeIsolated { () -> Bool in
            guard let p = bySession[ObjectIdentifier(session)] else { return false }
            // Only the model itself is written into the .part file: a captive portal's page or
            // an error page sent as 200 would otherwise spoil the download.
            if code == 206, range.hasPrefix("bytes \(p.next)-\(p.end)/") { return true }
            let problem = code == 200 || code == 206 ? "unexpected reply from the server" : "the server returned error \(code)"
            bySession[ObjectIdentifier(session)] = nil
            p.session = nil
            session.invalidateAndCancel()
            retry(p, because: problem)
            return false
        }
        completionHandler(ok ? .allow : .cancel)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard let p = bySession[ObjectIdentifier(session)], let handle else { return }   // stopped or replaced
            let n = min(Int64(data.count), p.end - p.next + 1)
            // The throwing write: the old one raises an exception (a crash) on a full disk.
            do {
                try handle.seek(toOffset: UInt64(p.next))
                try handle.write(contentsOf: data.prefix(Int(n)))
            } catch {
                stopAll()
                state = .failed(spaceProblem() ?? error.localizedDescription)   // the .part file stays for a retry
                return
            }
            p.next += n; p.windowBytes += n
            failuresSinceProgress = 0
            if p.done { finish(p); return }   // the last one starts the check
            let shown = progress
            if shown - lastShown >= 0.005 { lastShown = shown; state = .downloading(shown) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard let p = bySession[ObjectIdentifier(session)] else { return }   // finished, replaced or stopped
            bySession[ObjectIdentifier(session)] = nil
            p.session = nil
            session.finishTasksAndInvalidate()
            if p.done { return }
            retry(p, because: error?.localizedDescription ?? "the connection closed early")
        }
    }
}
