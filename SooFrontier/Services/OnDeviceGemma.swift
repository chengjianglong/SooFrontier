import Foundation
import LiteRTLM
import Network

/// Gemma 4 E2B running on this device through LiteRT-LM: the writer of last resort when
/// Claude, GPT, and Grok can't be reached (no network, or the Mac bridge is down).
actor OnDeviceGemma {
    static let shared = OnDeviceGemma()

    /// Gemma 4 E2B handles 128K, but phones have little memory to spare; 8K tokens covers a story and its answer.
    static let maxNumTokens = 8_192
    static let maxOutputTokens = 1_800
    /// Rough character budget for system + prompt, leaving room for the answer.
    static let maxPromptChars = 16_000

    private var engine: Engine?
    private var loading: Task<Engine, Error>?

    var isLoaded: Bool { engine != nil }

    func complete(system: String, prompt: String) async throws -> String {
        guard let url = GemmaModel.installedURL() else {
            throw LLMError(message: "You're offline and on-device Gemma isn't downloaded. Download it in Settings to keep working offline.")
        }
        let engine = try await engine(url)
        let config = ConversationConfig(
            systemMessage: Message(String(system.prefix(3_000)), role: .system),
            samplerConfig: try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.6),
            thinkingConfig: ThinkingConfig(enableThinking: false)
        )
        let conversation = try await engine.createConversation(with: config)
        let budget = Self.maxPromptChars - min(system.count, 3_000)
        let trimmed = prompt.count > budget ? String(prompt.prefix(budget)) + "\n[…truncated for on-device model]" : prompt
        var text = ""
        for try await chunk in conversation.sendMessageStream(Message(trimmed), maxOutputTokens: Self.maxOutputTokens) {
            try Task.checkCancellation()
            for content in chunk.contents {
                if case let .text(t) = content { text += t }
            }
        }
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { throw LLMError(message: "On-device Gemma returned no text.") }
        return out
    }

    /// Frees the model's memory (it reloads on next use).
    func unload() {
        engine = nil
        loading = nil
    }

    private func engine(_ url: URL) async throws -> Engine {
        if let engine { return engine }
        if let loading { return try await loading.value }
        let task = Task { () throws -> Engine in
            #if targetEnvironment(simulator)
            let backend = Backend.cpu()
            #else
            let backend = Backend.gpu
            #endif
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LiteRTLM", isDirectory: true)
            try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            let config = try EngineConfig(modelPath: url.path, backend: backend,
                                          maxNumTokens: Self.maxNumTokens, cacheDir: caches.path)
            let engine = Engine(engineConfig: config)
            try await engine.initialize()
            return engine
        }
        loading = task
        do {
            let e = try await task.value
            engine = e
            loading = nil
            return e
        } catch {
            loading = nil
            throw error
        }
    }
}

/// Whether the device currently has any network path.
final class Connectivity: @unchecked Sendable {
    static let shared = Connectivity()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.online = path.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "soofrontier.connectivity"))
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    /// True when an error means the remote model simply couldn't be reached.
    static func isUnreachable(_ error: Error) -> Bool {
        if error is URLError || error is BridgeUnreachable { return true }
        let m = error.localizedDescription.lowercased()
        return ["offline", "network", "could not resolve", "can't reach", "cannot reach", "timed out",
                "connection", "enotfound", "econnrefused", "unable to connect", "took too long"].contains { m.contains($0) }
    }
}

/// Raised when an iPhone or iPad can't reach the Mac bridge.
struct BridgeUnreachable: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// MARK: - Model file and download

/// The Gemma 4 E2B model file: where it lives and downloading it once.
@MainActor @Observable
final class GemmaModel: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case notDownloaded, downloading(Double), ready, failed(String)
    }

    nonisolated static let remoteURL = URL(string:
        "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm")!
    nonisolated static let minimumBytes: Int64 = 2_000_000_000

    private(set) var state: State = .notDownloaded
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    override init() {
        super.init()
        refresh()
    }

    nonisolated static var ownURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SooFrontier/gemma-4-E2B-it.litertlm")
    }

    /// The model to load: a development override, our own copy, or (on a Mac) a copy another app already downloaded.
    nonisolated static func installedURL() -> URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["SOOFRONTIER_MODEL_PATH"] { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(ownURL)
        #if os(macOS)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        candidates += [support.appendingPathComponent("GemmaLens/gemma-4-E2B-it.litertlm"),
                       support.appendingPathComponent("SooTalky/gemma-4-E2B-it.litertlm")]
        #endif
        return candidates.first(where: isValid)
    }

    nonisolated static func isValid(_ url: URL) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size >= minimumBytes
    }

    func refresh() {
        if case .downloading = state { return }
        state = Self.installedURL() == nil ? .notDownloaded : .ready
    }

    func download() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: Self.ownURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = session.downloadTask(with: Self.remoteURL)
        task = t
        state = .downloading(0)
        t.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        refresh()
    }

    func delete() {
        cancel()
        try? FileManager.default.removeItem(at: Self.ownURL)
        Task { await OnDeviceGemma.shared.unload() }
        refresh()
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { MainActor.assumeIsolated { if self.task != nil { self.state = .downloading(p) } } }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file must be moved before this callback returns.
        let result: State
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= Self.minimumBytes else { throw LLMError(message: "The download was incomplete. Please try again.") }
            try? FileManager.default.removeItem(at: Self.ownURL)
            try FileManager.default.moveItem(at: location, to: Self.ownURL)
            result = .ready
        } catch {
            result = .failed(error.localizedDescription)
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.task = nil; self.state = result } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.task = nil; self.state = .failed(error.localizedDescription) } }
    }
}
