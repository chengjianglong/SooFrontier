import SwiftUI

/// App state + the orchestrator that dispatches the agent crew.
@MainActor @Observable
final class FrontierStore {
    var items: [FrontierItem] = []
    var status: [AgentKind: AgentStatus] = [:]
    var brief: FrontierBrief?
    var lastRefresh: Date?
    var isRefreshing = false
    var saved: Set<String> = []
    /// People whose X posts the Listener follows.
    var voices: [Voice] = Voice.starters
    /// Desk digests written on demand by the Synthesizer.
    var digests: [FrontierSection: SectionDigest] = [:]
    var digestsInProgress: Set<FrontierSection> = []
    /// Per-story Potential opportunities for the quick read, keyed by item id.
    var quickReads: [String: QuickRead] = [:]
    /// The on-device Gemma model used when the network or Mac bridge is unavailable.
    let gemma = GemmaModel()
    private var quickInFlight: [String: Task<QuickRead?, Never>] = [:]

    // Provider configuration
    var keys: [Provider: String] = [:]
    var models: [Provider: String] = [:]
    /// Which provider powers the Synthesizer, Skeptic deep-dives, and the Council moderator.
    var synthesizerProvider: Provider = .anthropic
    var skepticProvider: Provider = .openai
    var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases)

    // Subscription access (official CLIs on the Mac; relayed through the Mac on iPhone/iPad)
    var modes: [Provider: AccessMode] = [:]
    var cliModels: [Provider: String] = [:]
    /// iPhone/iPad: the Mac that runs subscription requests, and its pairing code.
    var bridgeService = ""
    var bridgeCode = ""
    #if os(macOS)
    /// Mac: share this Mac's subscriptions with the user's iPhone/iPad over the local network.
    var bridgeEnabled = false
    let bridge = BridgeServer()
    #endif

    private let defaults = UserDefaults.standard

    init() {
        for p in Provider.allCases {
            keys[p] = Keychain.get("key.\(p.rawValue)")
            models[p] = defaults.string(forKey: "model.\(p.rawValue)") ?? p.defaultModel
            modes[p] = p.supportsSubscription
                ? defaults.string(forKey: "mode.\(p.rawValue)").flatMap(AccessMode.init) ?? .subscription
                : .apiKey
            cliModels[p] = defaults.string(forKey: "cliModel.\(p.rawValue)") ?? p.defaultCLIModel
        }
        bridgeService = defaults.string(forKey: "bridge.service") ?? ""
        #if os(macOS)
        bridgeCode = defaults.string(forKey: "bridge.code") ?? String(format: "%06d", Int.random(in: 0...999_999))
        defaults.set(bridgeCode, forKey: "bridge.code")
        bridgeEnabled = defaults.bool(forKey: "bridge.enabled")
        if bridgeEnabled { try? bridge.start(code: bridgeCode) }
        #else
        bridgeCode = Keychain.get("bridge.code")
        #endif
        synthesizerProvider = defaults.string(forKey: "role.synth").flatMap(Provider.init) ?? .anthropic
        // Story analyses are written by ChatGPT; switch existing installs over once.
        if !defaults.bool(forKey: "migrated.analysisByGPT") {
            defaults.set(Provider.openai.rawValue, forKey: "role.skeptic")
            defaults.set(true, forKey: "migrated.analysisByGPT")
        }
        skepticProvider = defaults.string(forKey: "role.skeptic").flatMap(Provider.init) ?? .openai
        if let off = defaults.stringArray(forKey: "agents.off") {
            enabledAgents.subtract(off.compactMap(AgentKind.init))
        }
        saved = Set(defaults.stringArray(forKey: "saved") ?? [])
        if let d = defaults.data(forKey: "voices"), let v = try? JSONDecoder().decode([Voice].self, from: d) { voices = v }
        loadCache()
    }

    // MARK: Providers

    func client(_ p: Provider) -> LLMClient? {
        let mode = modes[p] ?? .apiKey
        let key = keys[p] ?? ""
        if mode == .subscription {
            #if !os(macOS)
            guard !bridgeService.isEmpty, !bridgeCode.isEmpty else { return nil }
            #endif
        } else if key.isEmpty {
            return nil
        }
        return LLMClient(provider: p, apiKey: key, model: models[p] ?? p.defaultModel, mode: mode,
                         cliModel: cliModels[p] ?? p.defaultCLIModel, bridgeService: bridgeService, bridgeCode: bridgeCode)
    }

    func setMode(_ mode: AccessMode, for p: Provider) {
        modes[p] = mode
        defaults.set(mode.rawValue, forKey: "mode.\(p.rawValue)")
    }

    func setCLIModel(_ model: String, for p: Provider) {
        cliModels[p] = model
        defaults.set(model, forKey: "cliModel.\(p.rawValue)")
    }

    func setBridge(service: String, code: String) {
        bridgeService = service
        bridgeCode = code.trimmingCharacters(in: .whitespaces)
        defaults.set(service, forKey: "bridge.service")
        Keychain.set(bridgeCode, for: "bridge.code")
    }

    #if os(macOS)
    func setBridgeEnabled(_ on: Bool) {
        bridgeEnabled = on
        defaults.set(on, forKey: "bridge.enabled")
        if on { try? bridge.start(code: bridgeCode) } else { bridge.stop() }
    }
    #endif

    var configuredProviders: [Provider] { Provider.allCases.filter { client($0) != nil } }

    /// Preferred provider for a role, falling back to any configured one.
    func roleClient(_ preferred: Provider) -> LLMClient? {
        client(preferred) ?? configuredProviders.first.flatMap { client($0) }
            ?? (GemmaModel.installedURL() != nil ? LLMClient.gemma() : nil)
    }

    func setKey(_ key: String, for p: Provider) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keys[p] = k
        Keychain.set(k, for: "key.\(p.rawValue)")
    }

    func setModel(_ model: String, for p: Provider) {
        models[p] = model
        defaults.set(model, forKey: "model.\(p.rawValue)")
    }

    func setRoles(synth: Provider, skeptic: Provider) {
        synthesizerProvider = synth
        skepticProvider = skeptic
        defaults.set(synth.rawValue, forKey: "role.synth")
        defaults.set(skeptic.rawValue, forKey: "role.skeptic")
    }

    func toggle(_ agent: AgentKind) {
        if enabledAgents.contains(agent) { enabledAgents.remove(agent) } else { enabledAgents.insert(agent) }
        defaults.set(AgentKind.allCases.filter { !enabledAgents.contains($0) }.map(\.rawValue), forKey: "agents.off")
    }

    // MARK: Queries

    func items(in c: FrontierCategory) -> [FrontierItem] {
        items.filter { $0.category == c }.sorted { $0.score > $1.score }
    }

    func items(in section: FrontierSection) -> [FrontierItem] {
        items.filter { $0.category.section == section }.sorted { $0.score > $1.score }
    }

    /// Round-robin across lanes so one noisy source can't crowd out the rest.
    var topSignals: [FrontierItem] {
        let lanes = FrontierCategory.allCases.map { items(in: $0).prefix(2) }
        return Array((0..<2).flatMap { rank in lanes.compactMap { $0.dropFirst(rank).first } }.prefix(10))
    }

    // MARK: Voices

    /// Adds handles pasted in any form (@name, x.com/name, separated by spaces, commas, or lines).
    func addVoices(_ text: String, role: Voice.Role) {
        let tokens = text.components(separatedBy: CharacterSet(charactersIn: " ,;\n\t"))
        for raw in tokens {
            var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = h.range(of: "x.com/") ?? h.range(of: "twitter.com/") { h = String(h[r.upperBound...]) }
            h = h.trimmingCharacters(in: CharacterSet(charactersIn: "@/ ")).components(separatedBy: "/").first ?? ""
            guard !h.isEmpty, h.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), h.count <= 15,
                  !voices.contains(where: { $0.id == h.lowercased() }) else { continue }
            voices.append(Voice(handle: h, role: role))
        }
        saveVoices()
    }

    func removeVoices(at offsets: IndexSet, in role: Voice.Role) {
        let ids = offsets.map { voices.filter { $0.role == role }[$0].id }
        voices.removeAll { ids.contains($0.id) }
        saveVoices()
    }

    func resetVoices() {
        voices = Voice.starters
        saveVoices()
    }

    private func saveVoices() {
        defaults.set(try? JSONEncoder().encode(voices), forKey: "voices")
    }

    var hypeWatch: [FrontierItem] {
        Array(items.filter { ($0.assessment?.hype ?? 0) >= 0.35 }
            .sorted { ($0.assessment?.hype ?? 0) > ($1.assessment?.hype ?? 0) }.prefix(5))
    }

    var savedItems: [FrontierItem] { items.filter { saved.contains($0.id) } }

    func toggleSaved(_ item: FrontierItem) {
        if saved.contains(item.id) { saved.remove(item.id) } else { saved.insert(item.id) }
        defaults.set(Array(saved), forKey: "saved")
    }

    // MARK: Orchestration

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let crew: [any HarvestAgent] = [ArchivistAgent(), ShowrunnerAgent(), LibrarianAgent(), CuratorAgent(),
                                        ScoutAgent(), AnalystAgent(), PunditAgent(), CorrespondentAgent(),
                                        ListenerAgent(voices: voices, grok: client(.xai))]
            .filter { enabledAgents.contains($0.kind) }
        for a in AgentKind.allCases { status[a] = enabledAgents.contains(a) ? .working("Briefed, heading out…") : .idle }

        // Fan out: every harvester runs in parallel and reports progress back to mission control.
        var harvested: [FrontierItem] = []
        await withTaskGroup(of: (AgentKind, Result<[FrontierItem], Error>).self) { group in
            for agent in crew {
                group.addTask {
                    let kind = agent.kind
                    do {
                        let r = try await agent.harvest { msg in await MainActor.run { self.status[kind] = .working(msg) } }
                        return (kind, .success(r))
                    } catch { return (kind, .failure(error)) }
                }
            }
            var pending = Set(crew.map(\.kind))
            for await (kind, result) in group {
                pending.remove(kind)
                switch result {
                case .success(let r):
                    status[kind] = .done(r.count)
                    harvested += r
                case .failure(let e):
                    status[kind] = .failed(e.localizedDescription)
                    // Keep what this agent found last time rather than emptying its lanes.
                    harvested += items.filter { kind.lanes.contains($0.category) }
                }
                // Publish as each agent reports, keeping lanes still in flight from the last run.
                let waiting = items.filter { item in pending.contains { $0.lanes.contains(item.category) } }
                publish(harvested + waiting)
            }
        }
        status[.skeptic] = .done(items.count)
        lastRefresh = .now
        saveCache()

        await synthesize()
        // Desk digests that were written before this harvest are now stale; rewrite them too.
        for section in FrontierSection.allCases where (digests[section]?.generatedAt ?? .distantFuture) < lastRefresh! {
            try? await writeDigest(section)
        }
    }

    /// Skeptic pass: dedupe, assess, and keep saved items even if they fell off the feeds.
    private func publish(_ harvested: [FrontierItem]) {
        status[.skeptic] = .working("Cross-examining \(harvested.count) claims…")
        var seen = Set<String>()
        var merged: [FrontierItem] = []
        for var item in harvested + items.filter({ saved.contains($0.id) }) {
            let key = item.title.lowercased().filter(\.isLetter).prefix(60)
            guard seen.insert(String(key)).inserted, seen.insert(item.id).inserted else { continue }
            item.assessment = SkepticAgent.assess(item)
            merged.append(item)
        }
        if !merged.isEmpty { items = merged }
    }

    func synthesize() async {
        guard enabledAgents.contains(.synthesizer), !items.isEmpty else { return }
        guard let llm = roleClient(synthesizerProvider) else {
            brief = FrontierBrief(text: SynthesizerAgent.offline(items), generatedAt: .now, byLLM: nil)
            status[.synthesizer] = .done(1)
            saveCache()
            return
        }
        status[.synthesizer] = .working("Drafting the brief with \(llm.provider.family)…")
        // Give the synthesizer a balanced slate: the top items from every lane.
        let slate = FrontierCategory.allCases.flatMap { items(in: $0).prefix(3) }
        do {
            let (text, by) = try await llm.completeLabeled(system: SynthesizerAgent.system,
                                              prompt: SynthesizerAgent.prompt(slate: slate, previous: brief))
            brief = FrontierBrief(text: text, generatedAt: .now, byLLM: by)
            status[.synthesizer] = .done(1)
        } catch {
            brief = FrontierBrief(text: SynthesizerAgent.offline(items), generatedAt: .now, byLLM: nil)
            status[.synthesizer] = .failed(error.localizedDescription)
        }
        saveCache()
    }

    /// Writes the desk-level digest for Research, Productions, or Opinions.
    func writeDigest(_ section: FrontierSection) async throws {
        guard let llm = roleClient(synthesizerProvider) else { throw LLMError(message: "Connect a model in Settings.") }
        digestsInProgress.insert(section)
        defer { digestsInProgress.remove(section) }
        let slate = section.lanes.flatMap { items(in: $0).prefix(6) }
        guard !slate.isEmpty else { throw LLMError(message: "Nothing to analyze yet. Dispatch the agents first.") }
        let (text, by) = try await llm.completeLabeled(system: section.digestBrief, prompt: "Items:\n\n" + SynthesizerAgent.digest(slate))
        digests[section] = SectionDigest(text: text, generatedAt: .now, byLLM: by)
        saveCache()
    }

    /// 3–4 opportunities written for this specific story by a fast model; cached per story.
    func quickRead(for item: FrontierItem, content: PaperContent?, keyPoints: [String]) async -> QuickRead? {
        if let cached = quickReads[item.id] { return cached }
        // Share one request per story (the page and the next-story prefetch may ask at the same time).
        if let running = quickInFlight[item.id] { return await running.value }
        let task = Task { await self.writeQuickRead(for: item, content: content, keyPoints: keyPoints) }
        quickInFlight[item.id] = task
        defer { quickInFlight[item.id] = nil }
        return await task.value
    }

    /// Prepares the next story's ideas in the background so Next shows them right away.
    func prefetchQuickRead(for item: FrontierItem) {
        guard quickReads[item.id] == nil, quickInFlight[item.id] == nil else { return }
        Task {
            let paper = [.papers, .reports].contains(item.category) ? await PaperReader.read(item) : nil
            let points = KeyPoints.extract(summary: item.summary, fullText: paper?.text, exclude: "")
            _ = await quickRead(for: item, content: paper, keyPoints: points)
        }
    }

    private func writeQuickRead(for item: FrontierItem, content: PaperContent?, keyPoints: [String]) async -> QuickRead? {
        // Prefer Claude Haiku on the plan for speed; otherwise whichever model writes analyses.
        var llm = client(.anthropic) ?? roleClient(skepticProvider)
        if llm?.provider == .anthropic { llm?.cliModel = "haiku"; llm?.model = "claude-haiku-5-5" }
        guard let llm else { return nil }
        var prompt = SkepticAgent.prompt(for: item)
        if !keyPoints.isEmpty { prompt += "\n\nKey points:\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n") }
        if let content {
            let captions = content.keyFigures(4).map { "- \($0.caption)" }.joined(separator: "\n")
            if !captions.isEmpty { prompt += "\n\nKey figures:\n" + captions }
            prompt += "\n\nExcerpt:\n" + String(content.text.prefix(6_000))
        }
        guard let text = try? await llm.complete(system: SkepticAgent.ideasSystem, prompt: prompt, maxTokens: 3000),
              let read = QuickRead.parse(text) else { return nil }
        quickReads[item.id] = read
        saveCache()
        return read
    }

    /// Full analysis, written from the paper's full text and figure captions when the page can be read.
    func critique(_ item: FrontierItem, content: PaperContent?) async throws -> (String, String) {
        guard let llm = roleClient(skepticProvider) else { throw LLMError(message: "Add a model provider key in Settings.") }
        var prompt = SkepticAgent.prompt(for: item)
        if let content {
            let figures = content.figures.prefix(12).map { "- \($0.caption)" }.joined(separator: "\n")
            if !figures.isEmpty { prompt += "\n\nFigures (captions):\n" + figures }
            prompt += "\n\nFull text:\n" + content.text
        }
        let (text, by) = try await llm.completeLabeled(system: SkepticAgent.critiqueSystem, prompt: prompt)
        return (text, by)
    }

    /// Convenes every configured provider in parallel, then has the moderator rule.
    func convene(_ item: FrontierItem, onTurn: @escaping (CouncilAgent.Turn) -> Void) async throws -> String {
        let panel = configuredProviders.compactMap { self.client($0) }
        guard !panel.isEmpty else { throw LLMError(message: "Add at least one provider key in Settings.") }
        let prompt = SkepticAgent.prompt(for: item)
        var turns: [CouncilAgent.Turn] = []
        await withTaskGroup(of: CouncilAgent.Turn.self) { group in
            for llm in panel {
                group.addTask {
                    do {
                        let t = try await llm.complete(system: CouncilAgent.seatSystem(llm.provider), prompt: prompt, maxTokens: 4000)
                        return .init(provider: llm.provider, model: llm.model, text: t)
                    } catch {
                        return .init(provider: llm.provider, model: llm.model, text: error.localizedDescription, failed: true)
                    }
                }
            }
            for await t in group { turns.append(t); onTurn(t) }
        }
        let good = turns.filter { !$0.failed }
        guard let moderator = roleClient(synthesizerProvider), !good.isEmpty else { return "" }
        let transcript = good.map { "### \($0.provider.councilSeat.title) (\($0.provider.family))\n\($0.text)" }.joined(separator: "\n\n")
        return try await moderator.complete(system: CouncilAgent.moderatorSystem,
                                            prompt: prompt + "\n\nPanel:\n\n" + transcript, maxTokens: 4000)
    }

    // MARK: Cache

    private struct Cache: Codable {
        var items: [FrontierItem]
        var brief: FrontierBrief?
        var at: Date?
        var digests: [FrontierSection: SectionDigest]?
        var quickReads: [String: QuickRead]?
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "frontier-cache.json")
    }

    private func saveCache() {
        let c = Cache(items: items, brief: brief, at: lastRefresh, digests: digests, quickReads: quickReads)
        if let d = try? JSONEncoder().encode(c) { try? d.write(to: cacheURL, options: .atomic) }
    }

    private func loadCache() {
        guard let d = try? Data(contentsOf: cacheURL), let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        items = c.items
        brief = c.brief
        lastRefresh = c.at
        digests = c.digests ?? [:]
        quickReads = c.quickReads ?? [:]
    }
}
