import Foundation

/// The Skeptic: an always-on heuristic pass over every item, plus an optional LLM deep critique.
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

    static let critiqueSystem = """
    You are the Analyst inside SooFrontier, an app for AI researchers. Write a detailed, technically rigorous analysis of one item.
    \(Structure.detailedInstructions)
    TL;DR: 3–4 sentences: what the item claims; the key technical details (method or architecture, data, scale, and the \
    headline numbers or benchmarks when given); and your verdict (Strong signal, Promising, Unverified, or Hype).
    Takeaways: when the full text is provided, summarize the main takeaways the way an expert reader would after reading \
    the whole paper: 6–8 bullets, each a bold one-line claim followed by a full paragraph (4–6 sentences). Cover, in order: \
    the problem and why prior approaches fall short; the method or framework and its main components, walking through \
    the pipeline step by step and citing the figure that shows it (for example "Figure 2 shows…"); the data and training \
    setup; the main results with exact numbers and baselines; what the ablations reveal; and the limitations or red flags. \
    Without the full text, give 4–6 elaborated bullets on the evidence, what is new, and any red flags.
    Mathematical analysis: formalize the core idea. Give the objective or loss and the key equations, define every symbol, \
    state the assumptions, and reason about complexity, scaling, or convergence. Sanity-check any reported numbers \
    (for example whether a claimed speedup or accuracy gain is plausible). If the source gives too little to formalize, \
    write the most likely formulation and say clearly that it is your reconstruction.
    Potential opportunities: 3–5 bullets on concrete improvements or extensions that build on this work: \
    follow-up experiments, better methods, new applications, or products and research directions it enables.
    Be specific. If you only have the abstract or blurb, say what you cannot judge from it.
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

/// The Frontier Council: each configured provider argues from its seat, then a moderator rules.
enum CouncilAgent {
    struct Turn: Identifiable, Sendable {
        var id: Provider { provider }
        var provider: Provider
        var model: String
        var text: String
        var failed = false
    }

    static func seatSystem(_ p: Provider) -> String {
        """
        You sit on SooFrontier's Frontier Council as \(p.councilSeat.title). \(p.councilSeat.brief)
        React to the item in at most 140 words of Markdown: open with a bold one-line take, then 2–3 bullets.
        Be concrete and opinionated, and never generic.
        """
    }

    static let moderatorSystem = """
    You moderate SooFrontier's Frontier Council. Given an item and each panelist's take, rule on it.
    \(Structure.instructions)
    TL;DR: your ruling in 2–3 sentences, telling a researcher whether to read, try, wait, or skip, and the technical reason why.
    Takeaways: 2–4 bullets on where the panel agrees, naming panelists.
    Potential opportunities: 1–3 bullets on how the work could be improved or extended, including the experiment \
    that would settle the panel's disagreement.
    Under 170 words.
    """
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

    /// The detailed four-part form used for story analyses.
    static let detailedInstructions = """
    Write in Markdown using exactly these four headings, in this order, and no others:
    ## TL;DR
    ## Takeaways
    ## Mathematical analysis
    ## Potential opportunities
    TL;DR is plain prose. Takeaways and Potential opportunities are bullet lists starting with "- ". No preamble or sign-off.
    \(elaboration)
    Mathematical analysis is short paragraphs and bullets. Write math in Unicode, never LaTeX: use symbols such as \
    Σ ∇ ∂ ‖·‖ ≈ ≤ ∈ θ λ, superscripts like x², and subscripts like x₀. Put each display equation on its own line, \
    wrapped in single backticks, for example `L(θ) = E[‖x − f_θ(z)‖²]`.
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
