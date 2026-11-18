import CryptoKit
import Foundation

/// Downloads the local model (Qwen 3.5 4B, Q4_K_M, Apache 2.0) into
/// ~/Library/Application Support/LongyanReader/models/. Tries hf-mirror.com first (reachable
/// from mainland China), then huggingface.co; resumes a partial download; keeps the file only
/// if its SHA-256 matches. It's the same file Ollama's qwen3.5:4b uses, which the evals ran on.
@MainActor
final class ModelDownloader: NSObject, URLSessionDataDelegate {
    static let shared = ModelDownloader()

    nonisolated static let path = "unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf"
    nonisolated static let hosts = ["https://hf-mirror.com/", "https://huggingface.co/"]
    nonisolated static let size: Int64 = 2_740_937_888
    nonisolated static let sha256 = "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"

    enum State: Equatable { case idle, downloading(Double), verifying, failed(String), done }
    private(set) var state: State = .idle { didSet { observers.forEach { $0() } } }
    private var observers: [() -> Void] = []
    /// Called on every state change: the menu and the welcome window both follow the download.
    func observe(_ f: @escaping () -> Void) { observers.append(f) }

    private var target: URL { EmbeddedModel.modelsDirectory.appendingPathComponent(EmbeddedModel.fileName) }
    private var partial: URL { target.appendingPathExtension("part") }
    private var session: URLSession?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var hostIndex = 0
    private var lastShown = 0.0
    private var badReply: String?   // why the last reply was refused, for the failure message

    var isRunning: Bool {
        switch state { case .downloading, .verifying: true; default: false }
    }

    func start() {
        guard !isRunning else { return }
        try? FileManager.default.createDirectory(at: EmbeddedModel.modelsDirectory, withIntermediateDirectories: true)
        if let problem = spaceProblem() { state = .failed(problem); return }
        hostIndex = 0
        request()
    }

    /// Why the disk can't take the rest of the download, or nil. Asks for what's left to fetch
    /// plus 1 GB, so the download doesn't leave the disk full (checking reads the file in
    /// place, and finishing is a rename, so neither needs more).
    func spaceProblem() -> String? {
        let dir = EmbeddedModel.modelsDirectory
        let have = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let need = max(0, Self.size - have) + 1_000_000_000
        let probe = FileManager.default.fileExists(atPath: dir.path) ? dir : FileManager.default.homeDirectoryForCurrentUser
        guard let free = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < need else { return nil }
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1e9) }
        return "needs \(gb(need)) free and the disk has \(gb(free))"
    }

    func cancel() {
        session?.invalidateAndCancel(); session = nil
        try? handle?.close(); handle = nil
        state = .idle   // the .part file stays, so the next start resumes
    }

    private func request() {
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        received = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        if received >= Self.size { verify(); return }
        lastShown = Double(received) / Double(Self.size)
        badReply = nil
        var req = URLRequest(url: URL(string: Self.hosts[hostIndex] + Self.path)!)
        req.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        handle = try? FileHandle(forWritingTo: partial)
        _ = try? handle?.seekToEnd()
        state = .downloading(Double(received) / Double(Self.size))
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        s.dataTask(with: req).resume()
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
        let length = response.expectedContentLength
        let ok = MainActor.assumeIsolated { () -> Bool in
            // Only the model itself is written into the .part file: a captive portal's page or
            // an error page sent as 200 would otherwise spoil the resume and cost the whole file.
            if code == 206, range.hasPrefix("bytes \(received)-") { return true }
            if code == 200, length == Self.size {
                // The server ignored the range: start the file over.
                try? handle?.truncate(atOffset: 0); received = 0
                lastShown = 0
                return true
            }
            badReply = code == 200 || code == 206 ? "unexpected reply from the server" : "the server returned error \(code)"
            return false
        }
        completionHandler(ok ? .allow : .cancel)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            // The throwing write: the old one raises an exception (a crash) on a full disk.
            do { try handle?.write(contentsOf: data) } catch {
                session.invalidateAndCancel(); self.session = nil
                try? handle?.close(); handle = nil
                state = .failed(spaceProblem() ?? error.localizedDescription)   // the .part file stays for a retry
                return
            }
            received += Int64(data.count)
            let p = Double(received) / Double(Self.size)
            if p - lastShown >= 0.005 { lastShown = p; state = .downloading(p) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard session === self.session else { return }   // cancelled
            try? handle?.close(); handle = nil
            self.session = nil
            session.finishTasksAndInvalidate()
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if received >= Self.size { verify(); return }
            if hostIndex + 1 < Self.hosts.count {
                hostIndex += 1; request()      // the mirror failed: try the next host, resuming
            } else {
                hostIndex = 0
                state = .failed(badReply ?? error?.localizedDescription ?? "the server returned error \(code)")
            }
        }
    }

    private func verify() {
        state = .verifying
        let partial = self.partial, target = self.target
        Task.detached(priority: .utility) {
            let ok = Self.hash(of: partial) == Self.sha256
            await MainActor.run {
                if ok {
                    try? FileManager.default.removeItem(at: target)
                    do {
                        try FileManager.default.moveItem(at: partial, to: target)
                        EmbeddedModel.shared.forgetLoadFailure()
                        self.state = .done
                    }
                    catch { self.state = .failed(error.localizedDescription) }
                } else {
                    // A corrupt file can't be resumed into a good one.
                    // Removed, not trashed: 2.7 GB in the Trash would fail the next space check.
                    try? FileManager.default.removeItem(at: partial)
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
