import Foundation
import Network

/// How a provider is reached: the user's paid plan (via the official CLI) or a metered API key.
enum AccessMode: String, Codable, CaseIterable, Sendable {
    case subscription, apiKey

    var label: String { self == .subscription ? "Subscription" : "API key" }
}

extension Provider {
    /// Every provider's consumer plan can be used through its official command-line tool.
    var supportsSubscription: Bool { true }

    var cliName: String {
        switch self {
        case .anthropic: "claude"
        case .openai: "codex"
        case .xai: "grok"
        }
    }

    /// What to run once in Terminal to sign the CLI in to the plan.
    var loginCommand: String {
        switch self {
        case .anthropic: "claude"
        case .openai: "codex login"
        case .xai: "grok login"
        }
    }

    var planName: String {
        switch self {
        case .anthropic: "Claude Pro/Max"
        case .openai: "ChatGPT Plus/Pro"
        case .xai: "SuperGrok"
        }
    }

    /// Model choices understood by the CLI; "" means the CLI's own default.
    var cliModels: [String] {
        switch self {
        case .anthropic: ["opus", "sonnet", "haiku"]
        case .openai: ["", "gpt-6-astra"]
        case .xai: ["", "grok-build-0.1"]
        }
    }

    var defaultCLIModel: String { self == .anthropic ? "opus" : "" }
}

// MARK: - Bridge protocol (one JSON line each way)

struct BridgeRequest: Codable, Sendable {
    var code: String
    var provider: Provider
    var model: String
    var system: String
    var prompt: String
    /// Allow the CLI to search the web and X (Grok's Listener); otherwise answer-only.
    var research: Bool? = nil
}

struct BridgeResponse: Codable, Sendable {
    var text: String?
    var error: String?
}

enum Bridge {
    static let serviceType = "_soofrontier._tcp"

    static func encodeLine<T: Encodable>(_ value: T) -> Data {
        var d = (try? JSONEncoder().encode(value)) ?? Data()
        d.append(0x0A)
        return d
    }

    /// Reads from the connection until a newline, then decodes.
    static func receiveLine<T: Decodable>(_ type: T.Type, on conn: NWConnection, buffer: Data = Data(),
                                          completion: @escaping @Sendable (Result<T, Error>) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let nl = buf.firstIndex(of: 0x0A) {
                do { completion(.success(try JSONDecoder().decode(T.self, from: buf[..<nl]))) }
                catch { completion(.failure(error)) }
            } else if let error {
                completion(.failure(error))
            } else if done || buf.count > 4 << 20 {
                completion(.failure(LLMError(message: "Mac bridge closed the connection.")))
            } else {
                receiveLine(type, on: conn, buffer: buf, completion: completion)
            }
        }
    }
}

#if os(macOS)
import AppKit

// MARK: - CLI runner (macOS)

enum CLIRunner {
    private static let searchDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                "\(home)/.bun/bin", "\(home)/.claude/local", "/usr/bin", "/bin"]
    }()

    /// Locates a CLI the way a terminal would, since GUI apps don't inherit the shell PATH.
    static func executable(_ name: String) -> String? {
        if let hit = searchDirs.map({ "\($0)/\(name)" }).first(where: FileManager.default.isExecutableFile) { return hit }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func run(_ provider: Provider, model: String, system: String, prompt: String, research: Bool = false) async throws -> String {
        guard let exe = executable(provider.cliName) else {
            throw LLMError(message: "Couldn't find the `\(provider.cliName)` CLI. Install it and sign in with your \(provider.planName) plan.")
        }
        let work = FileManager.default.temporaryDirectory.appending(path: "soofrontier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let outFile = work.appending(path: "out.txt")

        var args: [String]
        let combined = "<instructions>\n\(system)\n</instructions>\n\n\(prompt)"
        switch provider {
        case .anthropic:
            args = ["-p", "--tools", "", "--setting-sources", "", "--no-session-persistence",
                    "--output-format", "json", "--system-prompt", system]
            if !model.isEmpty { args += ["--model", model] }
            args.append(prompt)
        case .openai:
            args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-o", outFile.path,
                    "-c", "model_reasoning_effort=\"medium\""]
            if !model.isEmpty { args += ["-m", model] }
            args.append(combined)
        case .xai:
            // The strict sandbox confines reads and writes to the empty scratch folder, and Grok gets no file,
            // shell or add-on tools at all. Research mode allows web search, which xAI runs on its side and
            // which covers posts on X, plus web fetch.
            args = ["--no-auto-update", "--no-alt-screen", "--output-format", "streaming-json",
                    "--max-turns", research ? "8" : "1", "--cwd", work.path, "--sandbox", "strict",
                    "--tools", research ? "web_search,web_fetch" : "web_fetch", "--disallowed-tools", "search_tool,use_tool"]
            args += research ? ["--allow", "WebSearch", "--allow", "WebFetch"] : ["--disable-web-search"]
            if !model.isEmpty { args += ["-m", model] }
            args += ["-p", combined]
        }

        // Never let a stray API key in the environment turn plan usage into metered billing.
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY", "XAI_API_KEY"] { env[k] = nil }
        env["PATH"] = (searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")

        if provider == .xai { try await grokSignIn.renewIfNeeded(exe: exe, env: env, cwd: work) }
        let (status, stdout, stderr, timedOut) = try await launch(exe, args: args, env: env, cwd: work)
        switch provider {
        case .anthropic:
            let json = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any]
            let result = json?["result"] as? String ?? ""
            if status != 0 || json?["is_error"] as? Bool == true || result.isEmpty {
                throw LLMError(message: "Claude CLI: \(result.isEmpty ? tail(stderr) : result)")
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openai:
            let text = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
            if status != 0 || text.isEmpty { throw LLMError(message: "Codex CLI: \(tail(stderr))") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .xai:
            // Keep only the text written after Grok's last tool call; earlier text is "let me check…" narration.
            var answer = ""
            for line in stdout.split(separator: 0x0A) {
                guard let e = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
                switch e["type"] as? String {
                case "tool_call": answer = ""
                case "text": answer += e["data"] as? String ?? ""
                default: break
                }
            }
            let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if timedOut { throw LLMError(message: "Grok didn't answer in time.") }
            if status != 0 || text.isEmpty { throw LLMError(message: "Grok CLI: \(tail(stderr.isEmpty ? stdout : stderr))") }
            return text
        }
    }

    private static func tail(_ d: Data) -> String {
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "no output" : String(s.suffix(300))
    }

    /// The strict sandbox can't write to Grok's auth lock, so with an expired token Grok waits forever instead of
    /// failing. Renew it first, outside the sandbox, with a fixed prompt. Parallel calls share one renewal.
    private actor GrokSignIn {
        private var renewal: Task<Void, Error>?

        func renewIfNeeded(exe: String, env: [String: String], cwd: URL) async throws {
            let task = renewal ?? Task {
                guard let expiry = Self.expiry(), expiry.timeIntervalSinceNow <= 600 else { return }
                _ = try await CLIRunner.launch(exe, args: ["--no-auto-update", "--no-alt-screen", "--max-turns", "1", "--cwd", cwd.path,
                                                           "--disable-web-search", "-p", "Reply with exactly: ready"], env: env, cwd: cwd, timeout: 60)
                if let renewed = Self.expiry(), renewed.timeIntervalSinceNow <= 0 {
                    throw LLMError(message: "Grok's sign-in has expired. Run `grok login`, then refresh.")
                }
            }
            renewal = task
            defer { renewal = nil }
            try await task.value
        }

        /// Latest expiry among the sign-ins in Grok's auth file, or nil if there is no file to read.
        private static func expiry() -> Date? {
            let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".grok/auth.json")
            guard let data = try? Data(contentsOf: file),
                  let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let dates = auth.values.compactMap { entry -> Date? in
                guard let raw = (entry as? [String: Any])?["expires_at"] as? String else { return nil }
                // Grok writes microseconds, and only whole seconds matter here.
                return ISO8601DateFormatter().date(from: raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
            }
            return dates.max() ?? .distantPast
        }
    }

    private static let grokSignIn = GrokSignIn()

    private static func launch(_ exe: String, args: [String], env: [String: String], cwd: URL,
                               timeout seconds: Double = 300) async throws -> (Int32, Data, Data, Bool) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = env
                p.currentDirectoryURL = cwd
                p.standardInput = FileHandle.nullDevice
                let errURL = cwd.appending(path: "stderr.txt")
                FileManager.default.createFile(atPath: errURL.path, contents: nil)
                let out = Pipe()
                p.standardOutput = out
                p.standardError = try? FileHandle(forWritingTo: errURL)
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timeout.cancel()
                cont.resume(returning: (p.terminationStatus, data, (try? Data(contentsOf: errURL)) ?? Data(), p.terminationReason == .uncaughtSignal))
            }
        }
    }
}

// MARK: - Bridge server (macOS): lets iPhone/iPad use this Mac's subscriptions

@MainActor
final class BridgeServer {
    private var listener: NWListener?
    private(set) var isRunning = false

    func start(code: String) throws {
        stop()
        let l = try NWListener(using: .tcp)
        l.service = NWListener.Service(name: Host.current().localizedName ?? "SooFrontier Mac", type: Bridge.serviceType)
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Bridge.receiveLine(BridgeRequest.self, on: conn) { result in
                Task {
                    let response: BridgeResponse
                    switch result {
                    case .failure(let e): response = .init(error: e.localizedDescription)
                    case .success(let req) where req.code != code: response = .init(error: "Pairing code doesn't match this Mac.")
                    case .success(let req):
                        do {
                            response = .init(text: try await CLIRunner.run(req.provider, model: req.model, system: req.system, prompt: req.prompt,
                                                                        research: req.research ?? false))
                        } catch { response = .init(error: error.localizedDescription) }
                    }
                    conn.send(content: Bridge.encodeLine(response), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        l.start(queue: .main)
        listener = l
        isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
}
#endif

// MARK: - Bridge client (iPhone/iPad)

enum BridgeClient {
    static func send(_ req: BridgeRequest, to service: String) async throws -> String {
        let conn = NWConnection(to: .service(name: service, type: Bridge.serviceType, domain: "local.", interface: nil), using: .tcp)
        let response: BridgeResponse = try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            @Sendable func finish(_ r: Result<BridgeResponse, Error>) {
                guard once.claim() else { return }
                conn.cancel()
                cont.resume(with: r)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Bridge.encodeLine(req), completion: .contentProcessed { err in
                        if let err { finish(.failure(err)); return }
                        Bridge.receiveLine(BridgeResponse.self, on: conn) { finish($0) }
                    })
                case .failed(let e):
                    finish(.failure(BridgeUnreachable(message: "Can't reach \(service): \(e.localizedDescription)")))
                case .waiting(let e):
                    finish(.failure(BridgeUnreachable(message: "Can't reach \(service). Is SooFrontier open on your Mac, on the same Wi-Fi? (\(e.localizedDescription))")))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 320) {
                finish(.failure(BridgeUnreachable(message: "Your Mac took too long to answer.")))
            }
        }
        if let e = response.error { throw LLMError(message: e) }
        return response.text ?? ""
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}

/// Finds Macs on the local network that are sharing their subscriptions.
@MainActor @Observable
final class BridgeBrowser {
    var macs: [String] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: Bridge.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { r -> String? in
                if case let .service(name, _, _, _) = r.endpoint { return name }
                return nil
            }
            Task { @MainActor in self.macs = Array(Set(names)).sorted() }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() { browser?.cancel(); browser = nil }
}
