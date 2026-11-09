import Foundation

/// The Skeptic: an always-on heuristic pass over every item.
enum SkepticAgent {
    private static let hypeWords = ["revolutionary", "game-changer", "game changer", "agi", "breakthrough", "insane",
                                    "mind-blowing", "unprecedented", "destroys", "kills", "beats gpt", "beats every",
                                    "sota", "state-of-the-art", "state of the art", "superhuman", "10x", "100x",
                                    "changes everything", "secret", "shocking", "you won't believe"]
    private static let evidenceWords = ["benchmark", "ablation", "evaluation", "we evaluate", "dataset", "open-source",
                                        "open source", "code", "github", "weights", "reproduc", "baseline", "limitations",
                                        "error bars", "human eval", "preprint", "peer"]

    /// Whole words only: as substrings, "agi" matches "imaging" and "kills" matches "skills".
    static func hasWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "(^|[^a-z0-9])\(NSRegularExpression.escapedPattern(for: word))($|[^a-z0-9])", options: .regularExpression) != nil
    }

    static func assess(_ item: FrontierItem) -> Assessment {
        let text = (item.title + " " + item.summary).lowercased()
        let hypeHits = hypeWords.filter { hasWord(text, $0) }
        let evidenceHits = evidenceWords.filter(text.contains)
        var flags: [String] = []
        var hype = min(1, Double(hypeHits.count) * 0.22 + (item.title.contains("!") ? 0.15 : 0))
        var signal = min(1, Double(evidenceHits.count) * 0.12 + min(0.4, log10(item.traction + 1) / 8))

        if !hypeHits.isEmpty { flags.append("Hype language: “\(hypeHits.prefix(3).joined(separator: "”, “"))”") }
        if hypeHits.contains(where: { ["sota", "state-of-the-art", "state of the art"].contains($0) }) {
            flags.append("Claims SOTA — check which benchmarks and whether baselines are current")
        }
        switch item.category {
        case .papers, .reports:
            signal += 0.15
            if !text.contains("code") && !text.contains("github") { flags.append("No code mentioned — reproducibility unknown") }
            if item.category == .reports && item.source != "arXiv" { flags.append("Lab-authored report — not peer reviewed") }
        case .models:
            signal += 0.1
            if item.traction < 50 { flags.append("Low community traction so far") }
        case .products, .services:
            if item.source == "Hacker News" { flags.append("Secondhand source — read the primary announcement") }
            if ["AWS Machine Learning", "Google Cloud AI", "Cloudflare AI"].contains(item.source) {
                flags.append("Vendor announcement — expect favorable framing")
                hype += 0.15
            }
        case .voices:
            flags.append("A post, not a paper — check the thread and who replies")
        case .essays:
            flags.append("Opinion piece — weigh the author's track record and incentives")
        case .companies:
            flags.append("Company's own blog — expect favorable framing of its products")
            hype += 0.1
        case .demos:
            flags.append("Demos are curated — test it on your own hard cases")
        case .code:
            if item.traction > 5000 { signal += 0.1 }
        }
        return Assessment(hype: min(1, hype), signal: min(1, signal), flags: flags, questions: questions(for: item.category))
    }

    static func questions(for c: FrontierCategory) -> [String] {
        switch c {
        case .papers: ["What is the strongest baseline, and is it tuned fairly?", "Could the eval set have leaked into pre-training?", "Do the gains hold across seeds and scales?"]
        case .reports: ["Which results are independently reproducible?", "What compute and data went in, and is it disclosed?", "What does the report leave out?"]
        case .models: ["Which evals were self-reported vs independently run?", "What's the license, and can you use it commercially?", "How does it do on your own task, not leaderboards?"]
        case .products: ["Who is this actually for, and what job does it replace?", "What isn't being announced, such as cost, limits, or availability?", "How defensible is it if a frontier lab ships the same thing?"]
        case .services: ["What does it cost per million tokens or per call at your scale?", "What are the rate limits, SLAs, and data-retention terms?", "How hard is it to switch providers later?"]
        case .demos: ["Is the demo cherry-picked?", "What happens on adversarial or out-of-distribution input?", "What does it cost per query?"]
        case .voices: ["Is this a considered view or a reaction?", "What does this person gain if they're right?", "Who credible disagrees, and why?"]
        case .companies: ["What is this company selling, and how does the post serve that?", "Which claims come with numbers someone else can check?", "What do competitors or independent researchers say about it?"]
        case .essays: ["What evidence would change the author's mind?", "Is the strongest counter-argument addressed?", "What are the author's incentives?"]
        case .code: ["Is it actively maintained?", "Is it a thin wrapper or real engineering?", "What's the bus factor?"]
        }
    }

    /// Starting-point opportunities for the quick read, by lane.
    static func opportunities(for c: FrontierCategory) -> [String] {
        switch c {
        case .papers: ["**Reproduce and stress-test it:** rerun the main result on a held-out benchmark or a different model scale to see whether the gain holds.",
                       "**Transfer the method:** apply the core idea to an adjacent task or modality where the same bottleneck appears.",
                       "**Ablate the key component:** isolate the one design choice that matters most and test whether a simpler version keeps the benefit."]
        case .reports: ["**Benchmark it yourself:** run the reported model or system on your own tasks to check the claimed numbers.",
                        "**Fill the disclosure gaps:** compute, data, and safety details left out of the report are open ground for independent analysis.",
                        "**Build on the release:** use any released weights, tools, or datasets as a baseline for follow-up work."]
        case .models: ["**Fine-tune for a niche:** adapt it with LoRA or distillation to a domain the base model underserves.",
                       "**Build an evaluation:** create a focused benchmark for the task it claims to be good at.",
                       "**Ship a product on it:** if the license allows, wrap it in a narrowly scoped app or API."]
        case .products: ["**Serve the gap:** identify which users it leaves out, by price, privacy, platform, or workflow, and build for them.",
                         "**Integrate with it:** a plugin, connector, or workflow layer can ride on its launch.",
                         "**Measure it:** an independent comparison against alternatives is useful to buyers and builders alike."]
        case .services: ["**Cut cost or latency:** routing, caching, or batching layers on top of the service can make it cheaper to use.",
                         "**Reduce lock-in:** a portable abstraction across providers lets teams switch when prices change.",
                         "**Combine it:** pair it with retrieval, tools, or agents to deliver a complete workflow."]
        case .demos: ["**Turn the demo into a tool:** harden the interaction into something people can use daily.",
                      "**Probe its limits:** collect failure cases and publish them as a small benchmark.",
                      "**Combine it with another model:** chain it into a pipeline that solves a fuller task."]
        case .code: ["**Contribute:** tests, docs, or performance work are often the fastest way to make it production-ready.",
                     "**Package it:** a hosted version or integration can serve users who won't run it themselves.",
                     "**Extend it:** add the feature or backend the issue tracker keeps asking for."]
        case .voices, .essays, .companies: ["**Test the claim:** design a small experiment that would confirm or refute the central argument.",
                                            "**Build for the trend:** if the view is right, name the tool or product that becomes necessary.",
                                            "**Write the counterpoint:** a well-evidenced response adds value whichever side is right."]
        }
    }

    static let ideasSystem = """
    You write the quick read for one specific item in SooFrontier, an app for AI researchers and builders.
    Use exactly these five Markdown headings, each followed only by bullets starting with "- ":
    ## Contributions
    1–3 bullets: what this item introduces that is new (method, model, dataset, system, or product), named specifically.
    ## Findings
    1–3 bullets: what it shows or observes beyond the headline numbers (insights, ablations, behaviors, trade-offs).
    ## Results
    1–3 bullets: the concrete outcomes with the exact numbers, benchmarks, and baselines stated in the source. \
    If the source reports no numbers, write one bullet saying so and what it claims qualitatively.
    ## Limitations
    1–3 bullets: weaknesses, missing evidence, narrow evaluation, costs, or risks specific to this item, including any \
    the authors acknowledge.
    ## Potential opportunities
    3–4 bullets. Each Contribution, Finding, Result, and Limitation bullet is 1–2 full sentences. Each opportunity is a bold one-line idea followed by 1–2 sentences.
    Every idea must be specific to THIS item: name its actual method, components, datasets, benchmarks, numbers, or the \
    limitation it leaves, and say concretely what to build, test, or extend and how. Never give advice that would fit \
    any other paper or product. Use only facts stated in the item; when the source says little (for example a model \
    card with only a name and tags), do not assume its modality, size, or capabilities, and frame ideas around \
    finding those out. No preamble or sign-off; nothing but the five headings and their bullets.
    """

    static func prompt(for item: FrontierItem) -> String {
        """
        Item type: \(item.category.title)
        Title: \(item.title)
        Source: \(item.source)\(item.author.map { " · by \($0)" } ?? "")
        URL: \(item.url.absoluteString)
        Traction: \(item.tractionLabel ?? "unknown")
        Summary: \(item.summary)
        """
    }
}

/// The Synthesizer: writes the Frontier Brief from the crew's top findings.
enum SynthesizerAgent {
    static let system = """
    You are the Synthesizer agent in SooFrontier. Other agents have harvested today's AI frontier: research,
    productions (models, products, services), and opinions. Write the Frontier Brief for a busy AI researcher.
    \(Structure.instructions)
    TL;DR: the one thing to know today in 3–4 sentences, including the key technical detail behind it (method, model, \
    scale, or result numbers) rather than only the headline.
    Takeaways: 5–7 bullets, each naming an item and why it matters technically. Include one bullet that flags \
    what is overclaimed, and one that names something worth trying today.
    Potential opportunities: 3–4 bullets on improvements, extensions, or things to build that today's items open up.
    Ground every claim in the provided items; do not invent results. Keep it under 650 words.
    """

    static func digest(_ items: [FrontierItem], newSince: Date? = nil) -> String {
        items.enumerated().map { i, it in
            let a = it.assessment.map { " [skeptic: \($0.verdict)]" } ?? ""
            let isNew = newSince.map { (it.date ?? .distantPast) > $0 } ?? false
            return "\(i + 1). \(isNew ? "[NEW] " : "")(\(it.category.title)) \(it.title) — \(it.source), \(it.tractionLabel ?? "")\(a)\n   \(it.summary.prefix(280))"
        }.joined(separator: "\n")
    }

    /// Prompt for today's brief: marks what is new since the last brief and shows how that brief opened,
    /// so the lead changes from day to day instead of repeating the most-upvoted story.
    static func prompt(slate: [FrontierItem], previous: FrontierBrief?) -> String {
        var p = "Today's harvest:\n\n" + digest(slate, newSince: previous?.generatedAt.addingTimeInterval(-86400))
        if let previous, previous.byLLM != nil {
            p += "\n\nThe previous brief (\(previous.generatedAt.formatted(date: .abbreviated, time: .omitted))) opened with:\n"
            p += String(previous.text.prefix(600))
            p += "\n\nLead with something items marked [NEW] add, not the previous brief's lead story, unless it has a real new development. "
            p += "Mention a story the previous brief already covered only if there is something new to say about it."
        }
        return p
    }

    /// Offline brief built without an LLM, in the same three-part structure.
    static func offline(_ items: [FrontierItem]) -> String {
        let tops = FrontierCategory.allCases.compactMap { c in items.filter { $0.category == c }.max { $0.score < $1.score } }
        var s = "## TL;DR\nToday's top signals across \(tops.count) lanes, ranked by freshness, traction, and the Skeptic's checks. "
        s += "Connect Claude, GPT, or Grok in Settings for a full analytical brief.\n\n## Takeaways\n"
        s += tops.map { "- **\($0.category.title):** \($0.title) (\($0.source))" }.joined(separator: "\n")
        s += "\n\n## Potential opportunities\n"
        let hype = items.filter { ($0.assessment?.hype ?? 0) > 0.4 }.prefix(3)
        s += tops.prefix(3).map { "- **Build on \($0.title):** \(SkepticAgent.opportunities(for: $0.category)[0].components(separatedBy: ":** ").last ?? "")" }.joined(separator: "\n")
        return s
    }
}

/// The Frontier Council: five perspectives, played by the local models, debating in rounds until they agree.
enum CouncilAgent {
    struct Seat: Identifiable, Sendable {
        var id: String
        var title: String
        var brief: String
        var symbol: String
    }

    static let seats: [Seat] = [
        .init(id: "skeptic", title: "The Skeptic", brief: "Rigorous methodologist. Hunt for missing baselines, eval leakage, cherry-picked results, and unstated limitations.", symbol: "magnifyingglass"),
        .init(id: "builder", title: "The Builder", brief: "Pragmatic engineer. Judge what this enables today, what it costs to run, and how you'd actually ship with it.", symbol: "hammer"),
        .init(id: "contrarian", title: "The Contrarian", brief: "Provocative outsider. Challenge the consensus narrative, name who benefits from the hype, and say what everyone is missing.", symbol: "arrow.triangle.swap"),
        .init(id: "advocate", title: "The Open-Weights Advocate", brief: "Hands-on open-model practitioner. Judge whether this can be reproduced, run and fine-tuned on hardware you own, and what the closed labs are not telling you.", symbol: "lock.open"),
        .init(id: "edge", title: "The Edge Engineer", brief: "On-device and small-model specialist. Judge whether this works on phones, laptops and edge chips, what it costs in memory and latency, and whether a small model could do the job.", symbol: "iphone"),
    ]
    /// Seats played by their own local model by default; the rest use the main local model.
    static let defaultModels = ["edge": "hf.co/LiquidAI/LFM3-1.7B-GGUF:BF16"]
    static let maxRounds = 4

    static func seat(_ id: String) -> Seat { seats.first { $0.id == id } ?? seats[0] }

    struct Turn: Identifiable, Sendable {
        var id: String { "\(seat)-\(round)" }
        var seat: String
        var round: Int
        var model = ""
        var text: String
        var verdict: String?
        /// No verdict line this round, so the member's previous verdict stands.
        var kept = false
        var failed = false
    }

    struct Outcome: Sendable {
        var counts: [String: Int]
        var leading: String?
        var agreed: Bool
        var rounds: Int

        init(_ turns: [Turn], rounds: Int) {
            var c: [String: Int] = [:]
            for t in turns { if let v = t.verdict { c[v, default: 0] += 1 } }
            counts = c
            leading = c.max { a, b in a.value < b.value }?.key
            let voters = turns.filter { $0.verdict != nil }.count
            agreed = voters > 1 && c.count == 1 && voters == turns.count
            self.rounds = rounds
        }

        var tally: String { counts.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: " · ") }
    }

    enum Event: Sendable {
        case speaking(seat: String, round: Int)
        case turn(Turn)
        case outcome(Outcome)
    }

    private static let verdictRule = """
    End with one final line exactly in this form: "Verdict: read", "Verdict: try", "Verdict: wait" or "Verdict: skip" \
    (read = worth studying closely, try = worth running or building with now, wait = promising but not ready, skip = not worth the time).
    """

    /// Local models' training data ends before today, so tell them the date and that the item is real.
    static var currentContext: String {
        "Today is \(Date.now.formatted(.iso8601.year().month().day())). The item is real and recent: SooFrontier's agents found it at its source. Dates, version numbers and arXiv IDs later than your training data are expected, not signs of a mistake or a hallucination. Judge the substance, never whether the item exists."
    }

    static func seatSystem(_ seat: Seat, round: Int) -> String {
        let others = seats.filter { $0.id != seat.id }.map(\.title).joined(separator: ", ")
        let task = round == 1
            ? "Give your opening statement on the item in at most 120 words of Markdown: a bold one-line take, then 2–3 bullets. Argue strictly from your own perspective."
            : "This is rebuttal round \(round). In at most 110 words, respond to the other members by name: concede any point that is right, push back where you still disagree, and give the evidence or test that would change your mind. Do not repeat your earlier points. Change your verdict only if the arguments actually convinced you, and say so. The council is trying to reach an agreement it can stand behind, not a polite one."
        return """
        You sit on SooFrontier's Frontier Council as \(seat.title). \(seat.brief)
        \(currentContext)
        The other members are \(others). Be concrete, technical and opinionated, never generic. Write in English, even if the item is in another language. Speak only as yourself, in the first person: never write lines for other members, and don't copy their wording. Don't start with a heading or your own name.
        \(task)
        \(verdictRule)
        """
    }

    static func transcript(_ turns: [Turn]) -> String {
        var out = ""
        var round = 0
        for t in turns where !t.failed {
            if t.round != round {
                round = t.round
                out += "\n## Round \(round)\(round == 1 ? ": opening statements" : ": rebuttals")\n"
            }
            out += "\n### \(seat(t.seat).title)\n\(t.text)\nVerdict: \(t.verdict ?? "none given")\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func turnPrompt(_ item: FrontierItem, heard: [Turn]) -> String {
        heard.isEmpty ? SkepticAgent.prompt(for: item) : SkepticAgent.prompt(for: item) + "\n\nThe debate so far:\n\n" + transcript(heard)
    }

    /// Splits a turn into its argument and its "Verdict: …" line (models vary the format, so be lenient).
    static func parse(_ raw: String) -> (text: String, verdict: String?) {
        let names = seats.map { $0.title.replacingOccurrences(of: "The ", with: "") }.joined(separator: "|")
        var verdict: String?
        var kept: [String] = []
        let verdictLine = #/^[\s>#*_-]*(?:my |final |updated |revised )?verdict[\s*_]*[:\-–][\s*_]*(read|try|wait|skip)\b.*$/#.ignoresCase()
        let selfName = try? Regex("^\\s*(?:#{1,6}\\s*|\\*\\*)(?:the )?(?:\(names))(?:\\*\\*)?:?\\s*$").ignoresCase()
        for (i, line) in raw.components(separatedBy: "\n").enumerated() {
            if let m = line.wholeMatch(of: verdictLine) { verdict = String(m.1).lowercased(); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") && t.lowercased().contains("verdict") { continue }
            if i < 3, let selfName, line.wholeMatch(of: selfName) != nil { continue }
            // A heading as the opening line ("# Opening statement — …") adds nothing.
            if t.hasPrefix("#"), kept.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            kept.append(line)
        }
        var joined = kept.joined(separator: "\n")
        // No verdict line? It may be tacked onto the end of the last paragraph ("…until then. Verdict: wait").
        let tail = #/[\s*_]*verdict[\s*_]*[:\-–][\s*_]*(read|try|wait|skip)\b[*_.!]*\s*$/#.ignoresCase()
        if verdict == nil, let m = joined.firstMatch(of: tail) {
            verdict = String(m.1).lowercased()
            joined.removeSubrange(m.range)
        }
        let text = joined
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, verdict)
    }

    static let moderatorSystem = """
    You moderate SooFrontier's Frontier Council, where its members debated an item over several rounds. Rule on it. Write in English.
    \(Structure.instructions)
    TL;DR: your ruling in 2–3 sentences, telling a researcher whether to read, try, wait, or skip, and the technical reason why. \
    If the council agreed, say how it got there; if not, rule anyway and name who dissents and why.
    Takeaways: 2–4 bullets on the arguments that moved the debate, naming members and who changed their mind.
    Potential opportunities: 1–3 bullets on how the work could be improved or extended, including the experiment \
    that would settle any remaining disagreement.
    Under 190 words.
    """

    static func moderatorPrompt(_ item: FrontierItem, turns: [Turn], outcome: Outcome) -> String {
        let verdict = outcome.leading ?? ""
        let result = outcome.agreed
            ? "the council agreed on \"\(verdict)\" after \(outcome.rounds) rounds. Your ruling is \"\(verdict)\": never overrule the council."
            : "no full agreement after \(outcome.rounds) rounds (\(outcome.tally)). Rule with the majority, \"\(verdict)\", and name who dissents and why."
        return currentContext + "\n\n" + SkepticAgent.prompt(for: item) + "\n\n" + transcript(turns) + "\n\nOutcome: " + result
    }
}

/// SooFrontier's house structure for everything the agents write: TL;DR, Takeaways, Potential opportunities.
enum Structure {
    static let instructions = """
    Write in Markdown using exactly these three headings, in this order, and no others:
    ## TL;DR
    ## Takeaways
    ## Potential opportunities
    TL;DR is plain prose. Takeaways and Potential opportunities are bullet lists starting with "- ". No preamble or sign-off.
    \(elaboration)
    """

    /// How much each bullet should say.
    static let elaboration = """
    %@ Each potential opportunity names a concrete improvement or extension and explains in 1–2 sentences how to pursue it and why it is promising.
    """.replacingOccurrences(of: "%@", with: "Each takeaway is a bold one-line claim followed by 2–4 sentences that elaborate it with specifics: the mechanism, the numbers or evidence, how it compares with prior work, and why it matters to a researcher or builder.")

    struct Parsed: Equatable {
        var tldr: String
        var takeaways: [String]
        var math: [String] = []
        var opportunities: [String]
    }

    /// Splits text written in the house structure; nil when the three parts aren't there.
    static func parse(_ text: String) -> Parsed? {
        enum Part { case none, tldr, takeaways, math, opportunities }
        var part = Part.none
        var tldr: [String] = [], takeaways: [String] = [], math: [String] = [], opportunities: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let key = line.lowercased().filter { $0.isLetter || $0 == ";" }
            let isHeading = line.hasPrefix("#") || (line.hasPrefix("**") && line.count < 40) || (line.hasSuffix(":") && line.count < 30)
            if isHeading || key.count < 20 {
                if key.hasPrefix("tl;dr") || key.hasPrefix("tldr") { part = .tldr; continue }
                if key.hasPrefix("takeaway") || key.hasPrefix("keytakeaway") { part = .takeaways; continue }
                if key.hasPrefix("potentialopportunit") || key.hasPrefix("opportunit") || key.hasPrefix("unsolved")
                    || key.hasPrefix("openproblem") || key.hasPrefix("openquestion") { part = .opportunities; continue }
                if key.hasPrefix("mathematical") || key.hasPrefix("math") { part = .math; continue }
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var item = line
            var isBullet = false
            for marker in ["- ", "* ", "• "] where item.hasPrefix(marker) { item = String(item.dropFirst(2)); isBullet = true }
            // A paragraph under a bold claim (or a wrapped bullet) belongs to the item above it.
            let continues = !isBullet && !(item.hasPrefix("**") && item.hasSuffix("**")) && !item.hasPrefix("`")
            if continues, part == .takeaways, !takeaways.isEmpty { takeaways[takeaways.count - 1] += " " + item; continue }
            if continues, part == .opportunities, !opportunities.isEmpty { opportunities[opportunities.count - 1] += " " + item; continue }
            if !isBullet, item.hasPrefix("**"), item.hasSuffix("**"), part == .takeaways || part == .opportunities {
                // Bold claim on its own line: keep it as the start of a new item.
                isBullet = true
            }
            if let dot = item.firstIndex(of: "."), item[..<dot].allSatisfy(\.isNumber), !item[..<dot].isEmpty {
                item = item[item.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            }
            switch part {
            case .none: continue
            case .tldr: tldr.append(line)
            case .takeaways: takeaways.append(item)
            case .math: math.append(item)
            case .opportunities: opportunities.append(item)
            }
        }
        guard !tldr.isEmpty, !takeaways.isEmpty else { return nil }
        return Parsed(tldr: tldr.joined(separator: " "), takeaways: takeaways, math: math, opportunities: opportunities)
    }
}
