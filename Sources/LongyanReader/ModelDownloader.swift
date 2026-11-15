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
    private(set) var state: State = .idle { didSet { onChange() } }
    var onChange: () -> Void = {}

    private var target: URL { EmbeddedModel.modelsDirectory.appendingPathComponent(EmbeddedModel.fileName) }
    private var partial: URL { target.appendingPathExtension("part") }
    private var session: URLSession?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var hostIndex = 0
    private var lastShown = 0.0

    var isRunning: Bool {
        switch state { case .downloading, .verifying: true; default: false }
    }

    func start() {
        guard !isRunning else { return }
        try? FileManager.default.createDirectory(at: EmbeddedModel.modelsDirectory, withIntermediateDirectories: true)
        hostIndex = 0
        request()
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
        var req = URLRequest(url: URL(string: Self.hosts[hostIndex] + Self.path)!)
        req.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        req.timeoutInterval = 30
        handle = try? FileHandle(forWritingTo: partial)
        handle?.seekToEndOfFile()
        state = .downloading(Double(received) / Double(Self.size))
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session = s
        s.dataTask(with: req).resume()
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                                completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            if code == 200 {
                // The server ignored the range: start the file over.
                try? handle?.truncate(atOffset: 0); received = 0
            }
        }
        completionHandler(code == 200 || code == 206 ? .allow : .cancel)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            handle?.write(data)
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
                state = .failed(error?.localizedDescription ?? "HTTP \(code)")
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
                    do { try FileManager.default.moveItem(at: partial, to: target); self.state = .done }
                    catch { self.state = .failed(error.localizedDescription) }
                } else {
                    // A corrupt file can't be resumed into a good one.
                    try? FileManager.default.trashItem(at: partial, resultingItemURL: nil)
                    self.state = .failed("the downloaded file didn't match its checksum; try again")
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
