import AVFoundation
import SwiftUI

/// A panelist in the Brainstorm room: one of the agents, given a viewpoint and a model to think with.
struct Panelist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let agent: AgentKind
    let provider: Provider
    let viewpoint: String
    /// Other words that address this panelist ("Claude", "GPT", …).
    let aliases: [String]

    static let all: [Panelist] = [
        Panelist(id: "skeptic", name: "Skeptic", agent: .skeptic, provider: .anthropic,
                 viewpoint: "A rigorous methodologist. You test claims: missing baselines, weak evidence, hidden assumptions, and what would change your mind.",
                 aliases: ["claude"]),
        Panelist(id: "builder", name: "Builder", agent: .analyst, provider: .openai,
                 viewpoint: "A pragmatic engineer and product builder. You focus on what this enables today, how you would ship it, what it costs, and concrete next steps.",
                 aliases: ["gpt", "chatgpt", "analyst"]),
        Panelist(id: "contrarian", name: "Contrarian", agent: .pundit, provider: .xai,
                 viewpoint: "A provocative outsider. You challenge the consensus, name who benefits from the hype, and argue the unpopular side when it has merit.",
                 aliases: ["grok", "pundit"]),
        Panelist(id: "archivist", name: "Archivist", agent: .archivist, provider: .anthropic,
                 viewpoint: "A research historian. You connect the topic to prior papers, earlier waves of similar ideas, and what the literature already settled.",
                 aliases: ["researcher"]),
        Panelist(id: "synthesizer", name: "Synthesizer", agent: .synthesizer, provider: .anthropic,
                 viewpoint: "The moderator. You find common ground, sharpen the real disagreement, and steer the group toward a useful conclusion.",
                 aliases: ["moderator"]),
    ]
}

struct BrainstormMessage: Identifiable, Hashable, Sendable {
    let id = UUID()
    let speaker: String          // "user" or a panelist id
    let name: String
    var text: String
    var model: String? = nil     // which model wrote it
    var isSummary = false
}

/// The Brainstorm room: you and the agent panel, by text or by voice.
/// Turn-taking follows SooTalky's Room: mentions first, "everyone" asks all, otherwise the quietest speaks and
/// another may chime in; an agent asked a question by name gets to answer.
@MainActor @Observable
final class BrainstormRoom {
    enum Phase: Equatable { case idle, listening, thinking(String), speaking(String) }
    enum Mode: String, CaseIterable, Identifiable {
        case chat, video
        var id: String { rawValue }
        var label: String { self == .chat ? "Group chat" : "Video meeting" }
        var symbol: String { self == .chat ? "bubble.left.and.bubble.right" : "video" }
    }

    private(set) var messages: [BrainstormMessage] = []
    private(set) var phase: Phase = .idle
    var members: Set<String> { didSet { UserDefaults.standard.set(Array(members), forKey: "brainstorm.members") } }
    /// Voice mode: replies are spoken, and the mic reopens after the panel finishes.
    var handsFree: Bool { didSet { UserDefaults.standard.set(handsFree, forKey: "brainstorm.handsFree") } }
    var speakReplies: Bool { didSet { UserDefaults.standard.set(speakReplies, forKey: "brainstorm.speak") } }
    /// Group chat (text bubbles) or video meeting (talking faces; replies always spoken).
    var mode: Mode { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "brainstorm.mode") } }
    /// Give the panel today's top signals as shared context.
    var useFrontierContext = true
    private(set) var liveCaption = ""
    var error: String?

    let voice = BrainstormVoice()
    @ObservationIgnored private weak var store: FrontierStore?
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastSpoke: [String: Date] = [:]

    init() {
        let d = UserDefaults.standard
        members = Set(d.stringArray(forKey: "brainstorm.members") ?? Panelist.all.map(\.id))
        handsFree = d.bool(forKey: "brainstorm.handsFree")
        speakReplies = d.object(forKey: "brainstorm.speak") as? Bool ?? false
        mode = d.string(forKey: "brainstorm.mode").flatMap(Mode.init) ?? .chat
        voice.onHeard = { [weak self] text in self?.liveCaption = text }
        voice.onCommit = { [weak self] text in self?.send(text) }
        voice.onError = { [weak self] msg in self?.error = msg; self?.phase = .idle }
        voice.onFinishedSpeaking = { [weak self] in self?.panelDone() }
    }

    func attach(_ store: FrontierStore) { self.store = store }

    var panel: [Panelist] { Panelist.all.filter { members.contains($0.id) } }
    var isBusy: Bool { if case .thinking = phase { true } else { false } }

    // MARK: Conversation

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        voice.stopListening()
        interrupt()
        liveCaption = ""
        error = nil
        messages.append(BrainstormMessage(speaker: "user", name: "You", text: text))
        run(pickResponders(for: text))
    }

    /// The Synthesizer closes the session in the house structure.
    func wrapUp() {
        guard messages.contains(where: { $0.speaker == "user" }) else { return }
        interrupt()
        let moderator = Panelist.all.first { $0.id == "synthesizer" }!
        run([Pick(panelist: moderator, summary: true)])
    }

    func reset() {
        interrupt()
        voice.stopListening()
        messages = []
        lastSpoke = [:]
        liveCaption = ""
        error = nil
        phase = .idle
    }

    /// Stop: ends listening, or interrupts whoever is speaking or thinking.
    func stopTapped() {
        voice.stopListening()
        interrupt()
        phase = .idle
    }

    /// The panelist speaking now, else the newest panelist line: drives the meeting caption.
    var captionMessage: BrainstormMessage? {
        if let id = voice.speakingPanelist, let m = messages.last(where: { $0.speaker == id }) { return m }
        return messages.last(where: { $0.speaker != "user" })
    }

    func interrupt() {
        turn += 1
        task?.cancel()
        task = nil
        voice.stopSpeaking()
        if case .listening = phase {} else { phase = .idle }
    }

    // MARK: Voice

    func micTapped() {
        switch phase {
        case .listening:
            voice.stopListening()
            let pending = liveCaption.trimmingCharacters(in: .whitespaces)
            if !pending.isEmpty { send(pending) } else { phase = .idle }
        case .speaking, .thinking:
            interrupt()
            listen()
        case .idle:
            listen()
        }
    }

    private func listen() {
        Task {
            guard await BrainstormVoice.requestPermissions() else {
                error = "Brainstorm needs the microphone and speech recognition. Allow them in Settings › SooFrontier."
                return
            }
            liveCaption = ""
            if voice.startListening() { phase = .listening }
        }
    }

    private func panelDone() {
        guard task == nil else { return }
        phase = .idle
        if handsFree { listen() }
    }

    // MARK: Turn-taking

    private struct Pick {
        let panelist: Panelist
        var optional = false
        var summary = false
    }

    private func pickResponders(for text: String) -> [Pick] {
        let room = panel
        guard !room.isEmpty else { return [] }
        let lower = text.lowercased()
        func mentions(_ p: Panelist) -> String.Index? {
            for word in [p.name.lowercased()] + p.aliases {
                if let r = lower.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) {
                    return r.lowerBound
                }
            }
            return nil
        }
        if lower.range(of: "\\b(everyone|everybody|all of you|you all|the panel|each of you)\\b", options: .regularExpression) != nil {
            return quietestFirst(room).map { Pick(panelist: $0) }
        }
        let named = room.compactMap { p in mentions(p).map { (p, $0) } }.sorted { $0.1 < $1.1 }.map { Pick(panelist: $0.0) }
        if !named.isEmpty { return Array(named.prefix(3)) }
        // Opening question: let the panel each weigh in once.
        if messages.filter({ $0.speaker == "user" }).count == 1 {
            return quietestFirst(room).prefix(4).map { Pick(panelist: $0) }
        }
        let order = quietestFirst(room)
        var picks = [Pick(panelist: order[0])]
        if order.count > 1 { picks.append(Pick(panelist: order[1], optional: true)) }
        return picks
    }

    private func quietestFirst(_ room: [Panelist]) -> [Panelist] {
        room.enumerated()
            .sorted { (lastSpoke[$0.element.id] ?? .distantPast, $0.offset) < (lastSpoke[$1.element.id] ?? .distantPast, $1.offset) }
            .map(\.element)
    }

    private func run(_ initial: [Pick]) {
        guard !initial.isEmpty else { return }
        turn += 1
        let id = turn
        task = Task { [weak self] in
            guard let self else { return }
            var picks = initial
            var followUps = 0
            var i = 0
            while i < picks.count, id == self.turn, !Task.isCancelled {
                let reply = await self.speak(picks[i], turn: id)
                // An agent asked another by name gets to answer, once per round.
                if let reply, i == picks.count - 1, followUps < 1, reply.contains("?"),
                   let addressed = self.panel.first(where: { p in p.id != picks[i].panelist.id &&
                       reply.range(of: "\\b\(p.name)\\b", options: [.regularExpression, .caseInsensitive]) != nil }) {
                    picks.append(Pick(panelist: addressed))
                    followUps += 1
                }
                i += 1
            }
            guard id == self.turn else { return }
            self.task = nil
            if !self.voice.isSpeaking { self.panelDone() }
        }
    }

    /// One panelist's turn. Returns the reply, or nil if they passed or failed.
    private func speak(_ pick: Pick, turn id: Int) async -> String? {
        guard let store else { return nil }
        let p = pick.panelist
        phase = .thinking(p.name)
        let llm = store.client(p.provider) ?? store.roleClient(p.provider)
        guard let llm else {
            error = "Connect a model in Settings, or set up a local model server, to brainstorm."
            return nil
        }
        do {
            let (text, by) = try await llm.completeLabeled(system: system(for: p, summary: pick.summary),
                                                           prompt: prompt(for: p, optional: pick.optional, summary: pick.summary),
                                                           maxTokens: pick.summary ? 3000 : 800)
            guard id == turn else { return nil }
            let reply = Self.clean(text, name: p.name)
            if reply.isEmpty || reply.uppercased().hasPrefix("PASS") { return nil }
            messages.append(BrainstormMessage(speaker: p.id, name: p.name, text: reply, model: by, isSummary: pick.summary))
            lastSpoke[p.id] = .now
            if speakReplies || handsFree || mode == .video {
                phase = .speaking(p.name)
                voice.speak(Reader.plain(reply), as: p.id)
            }
            return reply
        } catch {
            guard id == turn else { return nil }
            messages.append(BrainstormMessage(speaker: p.id, name: p.name, text: "(couldn't join: \(error.localizedDescription))", model: nil))
            return nil
        }
    }

    // MARK: Prompts

    private func system(for p: Panelist, summary: Bool) -> String {
        let others = panel.filter { $0.id != p.id }.map(\.name).joined(separator: ", ")
        var s = """
        You are the \(p.name) on SooFrontier's Brainstorm panel, a live discussion between an AI researcher ("You" in the \
        transcript) and a panel of agents: \(others). \(p.viewpoint)
        """
        if summary {
            s += "\nThe discussion is ending. Summarise it for the researcher.\n" + Structure.instructions +
                 "\nTL;DR: where the discussion landed, in 2–3 sentences. Takeaways: the strongest points, crediting who made them. " +
                 "Potential opportunities: concrete next steps or ideas to pursue. Under 300 words."
        } else {
            s += """

            Speak naturally, like a sharp colleague in a meeting: at most 4 short sentences (under 90 words), no headings or bullet lists. React to what \
            was just said, build on or push back against other panelists by name, and add something new rather than \
            repeating. You may end with one pointed question to a specific panelist or to the researcher.
            """
        }
        if useFrontierContext, let store, !store.items.isEmpty {
            let top = store.topSignals.prefix(8).map { "- (\($0.category.title)) \($0.title) — \($0.source)" }.joined(separator: "\n")
            s += "\n\nToday's frontier, for reference if relevant:\n\(top)"
        }
        return s
    }

    private func prompt(for p: Panelist, optional: Bool, summary: Bool) -> String {
        let transcript = messages.suffix(24).map { "\($0.name): \($0.text)" }.joined(separator: "\n\n")
        var s = "Discussion so far:\n\n\(transcript)\n\n"
        if summary { s += "Write the summary now." }
        else if optional { s += "You are the \(p.name). Add a brief reaction only if it adds something new. Otherwise reply with exactly PASS." }
        else { s += "It's your turn, \(p.name). Reply now, without prefixing your name." }
        return s
    }

    /// Strips a leading "Name:" the model sometimes adds.
    private static func clean(_ text: String, name: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\(name):", "**\(name):**", "**\(name)**:"] where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
