import Foundation
import Network

/// Open-weight models served from your own GPU box (an Ollama server, e.g. a DGX Spark / GB10 on your network).
/// They write when Claude, GPT and Grok can't be reached, when no provider is set up, or for every job
/// when "Prefer local models" is on.
enum LocalModels {
    /// The strongest model that fits a 128 GB GB10: writes briefs, analyses and Council rulings.
    static let defaultModel = "gpt-oss:120b"
    /// A fast mixture-of-experts model for quick reads and other short jobs.
    static let defaultFastModel = "qwen3.6:35b-a3b"
    static let suggestedModels = ["gpt-oss:120b", "qwen3.8:27b", "qwen3.6:35b-a3b", "qwen3-next:80b", "gemma4:31b", "gpt-oss:20b"]
    static let defaultURL = "http://localhost:11434"

    struct Config: Sendable, Equatable {
        var url: String
        var model: String
        var fastModel: String
        var prefer: Bool
        /// Frontier Council seats played by their own model (seat id → model tag); others use `model`.
        var councilModels: [String: String] = [:]
        var isConfigured: Bool { URL(string: url)?.host() != nil && !model.isEmpty }
    }

    /// Read straight from UserDefaults so any actor can check it.
    static var config: Config {
        let d = UserDefaults.standard
        return Config(url: d.string(forKey: "local.url") ?? "",
                      model: d.string(forKey: "local.model") ?? defaultModel,
                      fastModel: d.string(forKey: "local.fastModel") ?? defaultFastModel,
                      prefer: d.bool(forKey: "local.prefer"),
                      councilModels: d.dictionary(forKey: "local.councilModels") as? [String: String]
                          ?? CouncilAgent.defaultModels)
    }

    static func save(_ c: Config) {
        let d = UserDefaults.standard
        d.set(c.url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "local.url")
        d.set(c.model, forKey: "local.model")
        d.set(c.fastModel, forKey: "local.fastModel")
        d.set(c.prefer, forKey: "local.prefer")
        d.set(c.councilModels, forKey: "local.councilModels")
    }

    static func label(_ model: String) -> String { "\(shortName(model)) · local" }

    /// A model tag short enough for a label: "hf.co/LiquidAI/LFM3-1.7B-GGUF:BF16" → "LFM3-1.7B".
    static func shortName(_ model: String) -> String {
        let last = model.split(separator: "/").last.map(String.init) ?? model
        return last.replacingOccurrences(of: "-GGUF(:.*)?$", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Big models think for a while before the first byte; allow up to ten minutes per answer.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 600
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()

    private static func base(_ c: Config) throws -> String {
        guard c.isConfigured else {
            throw LLMError(message: "Can't reach Claude, GPT or Grok, and no local model server is set up. Add one in Settings.")
        }
        var s = c.url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// One answer from the local server's OpenAI-compatible endpoint.
    static func complete(system: String, prompt: String, maxTokens: Int = 8000, fast: Bool = false,
                         temperature: Double? = nil, thinking: Bool? = nil,
                         model override: String? = nil) async throws -> (text: String, label: String) {
        let c = config
        let thinking = thinking ?? (maxTokens > 4000 && !fast)
        let model = override ?? (fast && !c.fastModel.isEmpty ? c.fastModel : c.model)
        var req = URLRequest(url: URL(string: try base(c) + "/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        if let temperature { body["temperature"] = temperature }
        // Thinking spends the same token budget as the answer. gpt-oss always reasons, so keep that short;
        // thinking models such as Qwen3 skip it on short jobs.
        if model.hasPrefix("gpt-oss") { body["reasoning_effort"] = fast || maxTokens <= 3000 ? "low" : "medium" }
        else if !thinking { body["reasoning_effort"] = "none" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) } catch {
            throw BridgeUnreachable(message: "Can't reach the local model server at \(c.url).")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let err = json["error"]
            let msg = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "HTTP \(http.statusCode)"
            throw LLMError(message: "Local model (\(model)): \(msg)")
        }
        let choice = (json["choices"] as? [[String: Any]])?.first
        let text = ((choice?["message"] as? [String: Any])?["content"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Ran out of budget while thinking: answer again without thinking.
        if text.isEmpty, choice?["finish_reason"] as? String == "length", thinking, !model.hasPrefix("gpt-oss") {
            return try await complete(system: system, prompt: prompt, maxTokens: maxTokens, fast: fast,
                                      temperature: temperature, thinking: false, model: override)
        }
        guard !text.isEmpty else {
            throw LLMError(message: "Local model (\(model)) returned no text (\(choice?["finish_reason"] as? String ?? "empty")).")
        }
        return (text, label(model))
    }

    /// The models the server has downloaded, for the Settings picker and connection test.
    static func installed(at url: String) async throws -> [String] {
        var c = config
        c.url = url
        let (data, _) = try await session.data(from: URL(string: try base(c) + "/api/tags")!)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return ((json?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
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
