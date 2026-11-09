import SwiftUI
import Security

/// The three model providers SooFrontier can put to work. Each one gets its own key and model.
enum Provider: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic, openai, xai

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .xai: "xAI"
        }
    }

    var family: String {
        switch self {
        case .anthropic: "Claude"
        case .openai: "GPT"
        case .xai: "Grok"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-5"
        case .xai: "grok-4"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .anthropic: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        case .openai: ["gpt-5", "gpt-5-mini"]
        case .xai: ["grok-4", "grok-4-fast"]
        }
    }

    var keyHelp: String {
        switch self {
        case .anthropic: "console.anthropic.com → API Keys"
        case .openai: "platform.openai.com → API keys"
        case .xai: "console.x.ai → API Keys"
        }
    }

    var color: Color {
        switch self {
        case .anthropic: .orange
        case .openai: .green
        case .xai: .primary
        }
    }

    var symbol: String {
        switch self {
        case .anthropic: "asterisk"
        case .openai: "circle.hexagongrid"
        case .xai: "xmark"
        }
    }
}

struct LLMError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// One configured provider + model, able to answer a single-turn prompt.
struct LLMClient: Sendable {
    var provider: Provider
    var apiKey: String
    var model: String
    var mode: AccessMode = .apiKey
    /// CLI model alias used in subscription mode ("" = the CLI's default).
    var cliModel: String = ""
    /// On iPhone/iPad, the Mac (Bonjour name) that runs subscription requests, plus its pairing code.
    var bridgeService: String = ""
    var bridgeCode: String = ""
    /// Always use the local model server (no provider is set up on this device).
    var localOnly = false
    /// A short job (quick reads): the local fallback uses its fast model.
    var fast = false

    static func local() -> LLMClient { LLMClient(provider: .anthropic, apiKey: "", model: LocalModels.config.model, localOnly: true) }

    var label: String {
        if localOnly { return LocalModels.label(fast ? LocalModels.config.fastModel : LocalModels.config.model) }
        return mode == .subscription
            ? "\(provider.family) · \(provider.planName.components(separatedBy: " ").last ?? "plan") plan\(cliModel.isEmpty ? "" : " · \(cliModel)")"
            : "\(provider.family) · \(model)"
    }

    func complete(system: String, prompt: String, maxTokens: Int = 8000, research: Bool = false) async throws -> String {
        try await completeLabeled(system: system, prompt: prompt, maxTokens: maxTokens, research: research).text
    }

    /// Answers with this provider, or with the local model server when the provider can't be reached
    /// (or first, when "Prefer local models" is on). Returns which model actually wrote the text.
    /// Research (live X/web search) always goes to the provider.
    func completeLabeled(system: String, prompt: String, maxTokens: Int = 8000,
                         research: Bool = false) async throws -> (text: String, label: String) {
        let local = LocalModels.config
        let canUseLocal = !research && local.isConfigured
        if canUseLocal && (localOnly || local.prefer || !Connectivity.shared.isOnline) {
            do {
                return try await LocalModels.complete(system: system, prompt: prompt, maxTokens: maxTokens, fast: fast)
            } catch where !localOnly && Connectivity.isUnreachable(error) {
                // The GPU box is off or out of reach: let the provider answer instead.
            }
        }
        if localOnly { throw LLMError(message: "Connect a model in Settings, or set up a local model server.") }
        do {
            return (try await remote(system: system, prompt: prompt, maxTokens: maxTokens, research: research), label)
        } catch where canUseLocal && !local.prefer && Connectivity.isUnreachable(error) {
            return try await LocalModels.complete(system: system, prompt: prompt, maxTokens: maxTokens, fast: fast)
        }
    }

    private func remote(system: String, prompt: String, maxTokens: Int, research: Bool) async throws -> String {
        if mode == .subscription {
            #if os(macOS)
            return try await CLIRunner.run(provider, model: cliModel, system: system, prompt: prompt, research: research)
            #else
            let req = BridgeRequest(code: bridgeCode, provider: provider, model: cliModel, system: system, prompt: prompt,
                                    research: research)
            return try await BridgeClient.send(req, to: bridgeService)
            #endif
        }
        guard !apiKey.isEmpty else { throw LLMError(message: "Add a \(provider.name) API key in Settings.") }
        switch provider {
        case .anthropic: return try await anthropic(system: system, prompt: prompt, maxTokens: maxTokens)
        case .openai: return try await chatCompletions(base: "https://api.openai.com/v1", tokenField: "max_completion_tokens",
                                                       system: system, prompt: prompt, maxTokens: maxTokens)
        case .xai: return try await chatCompletions(base: "https://api.x.ai/v1", tokenField: "max_tokens",
                                                    system: system, prompt: prompt, maxTokens: maxTokens)
        }
    }

    // MARK: Anthropic Messages API (raw HTTP; no official Swift SDK)

    private func anthropic(system: String, prompt: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": prompt]],
            "output_config": ["effort": "low"],
        ]
        // Opus/Sonnet/Fable re-route safety-declined requests server-side; Haiku has no fallback.
        if !model.contains("haiku") {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        let json = try await post(&req, body: body)
        if json["stop_reason"] as? String == "refusal" {
            let cat = (json["stop_details"] as? [String: Any])?["category"] as? String ?? "policy"
            throw LLMError(message: "Claude declined this request (\(cat)).")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: OpenAI-compatible Chat Completions (OpenAI and xAI)

    private func chatCompletions(base: String, tokenField: String, system: String, prompt: String, maxTokens: Int) async throws -> String {
        var req = URLRequest(url: URL(string: base + "/chat/completions")!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            tokenField: maxTokens,
            "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
        ]
        let json = try await post(&req, body: body)
        let choice = (json["choices"] as? [[String: Any]])?.first
        let text = (choice?["message"] as? [String: Any])?["content"] as? String ?? ""
        if text.isEmpty, let reason = choice?["finish_reason"] as? String {
            throw LLMError(message: "\(provider.family) returned no text (\(reason)).")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func post(_ req: inout URLRequest, body: [String: Any]) async throws -> [String: Any] {
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await Net.session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            let err = json["error"]
            let msg = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "HTTP \(http.statusCode)"
            throw LLMError(message: "\(provider.name): \(msg)")
        }
        return json
    }
}

enum Keychain {
    private static let service = "com.soofrontier.app"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
