import SwiftUI

/// The three desks of the app, each shown as a tab.
enum FrontierSection: String, CaseIterable, Codable, Identifiable, Sendable {
    case research, productions, opinions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .research: "Research"
        case .productions: "Productions"
        case .opinions: "Opinions"
        }
    }

    var symbol: String {
        switch self {
        case .research: "flask"
        case .productions: "shippingbox"
        case .opinions: "quote.bubble"
        }
    }

    var lanes: [FrontierCategory] { FrontierCategory.allCases.filter { $0.section == self } }

    /// What the desk's digest should do with its top items.
    var digestBrief: String {
        let focus: String
        switch self {
        case .research:
            focus = """
            You edit SooFrontier's Research desk. From these papers, technical reports, demos, and code, write a digest for AI researchers.
            TL;DR: what moved the state of the art this week, in 3–4 sentences naming the methods and the results that matter.
            Takeaways: 4–5 bullets naming the work and the result, including one method worth stealing and the one item to read first.
            Potential opportunities: 3–4 improvements or extensions these results open up for researchers.
            """
        case .productions:
            focus = """
            You are SooFrontier's Productions analyst. From these AI models, products, and services, write an analysis.
            TL;DR: the most important market move and who it threatens, in 3–4 sentences with the technical specifics (model size, modality, context, price, or API).
            Takeaways: 4–5 bullets on launches, capability, openness, and price, including one pick worth adopting now.
            Potential opportunities: 3–4 products, integrations, or improvements these launches make possible, and gaps the market leaves open.
            """
        case .opinions:
            focus = """
            You moderate SooFrontier's Opinions desk. From these posts, essays, and company blog posts by AI entrepreneurs, \
            researchers, engineers, investors, builders, and the AI model and data companies themselves, summarize the debate.
            TL;DR: where the conversation stands this week, in 3–4 sentences, including the technical claim at the center of the debate.
            Takeaways: 4–5 bullets on the consensus and the contrarian take worth hearing, attributing views by name.
            Potential opportunities: 3–4 ideas worth pursuing that the debate points to, noting the live disagreements behind them.
            Note where a company is promoting its own product.
            """
        }
        return focus + "\n" + Structure.instructions + "\nUnder 550 words. Ground every claim in the items."
    }
}

/// The lanes inside each desk.
enum FrontierCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case papers, reports, demos, code
    case models, products, services
    case voices, essays, companies

    var id: String { rawValue }

    var section: FrontierSection {
        switch self {
        case .papers, .reports, .demos, .code: .research
        case .models, .products, .services: .productions
        case .voices, .essays, .companies: .opinions
        }
    }

    var title: String {
        switch self {
        case .papers: "SOTA papers"
        case .reports: "Tech reports"
        case .demos: "Demos"
        case .code: "Code"
        case .models: "Models"
        case .products: "Products"
        case .services: "Services"
        case .voices: "Voices on X"
        case .essays: "Essays"
        case .companies: "Company blogs"
        }
    }

    var symbol: String {
        switch self {
        case .papers: "doc.text.magnifyingglass"
        case .reports: "doc.richtext"
        case .demos: "play.rectangle"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .models: "cpu"
        case .products: "app.badge"
        case .services: "cloud"
        case .voices: "bubble.left.and.text.bubble.right"
        case .essays: "text.book.closed"
        case .companies: "building.2"
        }
    }

    var tint: Color {
        switch self {
        case .papers: .blue
        case .reports: .indigo
        case .demos: .pink
        case .code: .green
        case .models: .purple
        case .products: .orange
        case .services: .cyan
        case .voices: .teal
        case .essays: .brown
        case .companies: .gray
        }
    }
}

/// Every agent in the crew. Harvesters fetch; the Skeptic and Synthesizer reason over what was fetched.
enum AgentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case archivist, showrunner, librarian, curator, scout, analyst, listener, pundit, correspondent, skeptic, synthesizer

    var id: String { rawValue }

    var name: String {
        switch self {
        case .archivist: "Archivist"
        case .showrunner: "Showrunner"
        case .librarian: "Librarian"
        case .curator: "Curator"
        case .scout: "Scout"
        case .analyst: "Analyst"
        case .listener: "Listener"
        case .pundit: "Pundit"
        case .correspondent: "Correspondent"
        case .skeptic: "Skeptic"
        case .synthesizer: "Synthesizer"
        }
    }

    var role: String {
        switch self {
        case .archivist: "SOTA papers from arXiv and HF Daily Papers, plus lab technical reports"
        case .showrunner: "Demos worth trying"
        case .librarian: "Rising open-source code"
        case .curator: "Trending open-weight models"
        case .scout: "AI product launches across the tech press"
        case .analyst: "AI platform and cloud services"
        case .listener: "What the voices you follow on X are saying, via Grok"
        case .pundit: "Essays and newsletters"
        case .correspondent: "Blogs from AI model and data companies"
        case .skeptic: "Separates signal from hype"
        case .synthesizer: "Writes your Frontier Brief and desk digests"
        }
    }

    var symbol: String {
        switch self {
        case .archivist: "books.vertical.fill"
        case .showrunner: "sparkles.tv.fill"
        case .librarian: "tray.full.fill"
        case .curator: "cube.transparent.fill"
        case .scout: "binoculars.fill"
        case .analyst: "chart.bar.doc.horizontal.fill"
        case .listener: "ear.fill"
        case .pundit: "megaphone.fill"
        case .correspondent: "building.2.fill"
        case .skeptic: "eyeglasses"
        case .synthesizer: "wand.and.stars"
        }
    }

    var color: Color {
        switch self {
        case .skeptic: .red
        case .synthesizer: .indigo
        default: lanes.first?.tint ?? .gray
        }
    }

    /// The lanes this agent fills.
    var lanes: [FrontierCategory] {
        switch self {
        case .archivist: [.papers, .reports]
        case .showrunner: [.demos]
        case .librarian: [.code]
        case .curator: [.models]
        case .scout: [.products]
        case .analyst: [.services]
        case .listener: [.voices]
        case .pundit: [.essays]
        case .correspondent: [.companies]
        case .skeptic, .synthesizer: []
        }
    }

    static var harvesters: [AgentKind] { allCases.filter { !$0.lanes.isEmpty } }
}

enum AgentStatus: Equatable, Sendable {
    case idle
    case working(String)
    case done(Int)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Standing by"
        case .working(let s): s
        case .done(let n): "Delivered \(n)"
        case .failed(let e): e
        }
    }

    var isWorking: Bool { if case .working = self { true } else { false } }
}

/// The Skeptic's verdict on an item.
struct Assessment: Codable, Hashable, Sendable {
    /// 0 = sober, 1 = pure hype.
    var hype: Double
    /// 0...1 evidence of substance (code, benchmarks, community traction).
    var signal: Double
    var flags: [String]
    var questions: [String]

    var verdict: String {
        switch (signal - hype) {
        case 0.35...: "Strong signal"
        case 0.05..<0.35: "Promising"
        case -0.2..<0.05: "Unverified"
        default: "Hype alert"
        }
    }

    var verdictColor: Color {
        switch (signal - hype) {
        case 0.35...: .green
        case 0.05..<0.35: .mint
        case -0.2..<0.05: .yellow
        default: .red
        }
    }
}

struct FrontierItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.absoluteString }
    var title: String
    var summary: String
    var url: URL
    var source: String
    var category: FrontierCategory
    var agent: AgentKind
    var author: String?
    var date: Date?
    var tags: [String] = []
    /// Raw traction number from the source (likes, stars, points, upvotes).
    var traction: Double = 0
    var tractionLabel: String?
    var assessment: Assessment?

    /// Ranking score: freshness × traction × skeptic signal.
    var score: Double {
        let ageHours = max(1, -(date ?? .now.addingTimeInterval(-86400 * 3)).timeIntervalSinceNow / 3600)
        // Half-life of a day, so a new story outranks yesterday's most-upvoted one.
        let freshness = pow(0.5, ageHours / 24)
        let pull = log10(traction + 10)
        let quality = 0.5 + (assessment.map { $0.signal - $0.hype * 0.5 } ?? 0)
        return freshness * pull * quality
    }
}

struct FrontierBrief: Codable, Sendable {
    var text: String
    var generatedAt: Date
    /// Label of the model that wrote it, or nil for the offline brief.
    var byLLM: String?
}

/// Someone whose X posts the Listener follows.
struct Voice: Codable, Hashable, Identifiable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        case entrepreneur, researcher, engineer, investor, builder
        var title: String { rawValue.capitalized }
    }

    var handle: String
    var role: Role
    var id: String { handle.lowercased() }

    /// A starting roster across the five roles; replace or extend it with the people @aiclong follows.
    static let starters: [Voice] = [
        .init(handle: "sama", role: .entrepreneur), .init(handle: "DarioAmodei", role: .entrepreneur),
        .init(handle: "demishassabis", role: .entrepreneur), .init(handle: "alexandr_wang", role: .entrepreneur),
        .init(handle: "karpathy", role: .researcher), .init(handle: "ylecun", role: .researcher),
        .init(handle: "AndrewYNg", role: .researcher), .init(handle: "fchollet", role: .researcher),
        .init(handle: "drfeifei", role: .researcher),
        .init(handle: "gdb", role: .engineer), .init(handle: "JeffDean", role: .engineer),
        .init(handle: "simonw", role: .engineer), .init(handle: "swyx", role: .engineer),
        .init(handle: "pmarca", role: .investor), .init(handle: "eladgil", role: .investor),
        .init(handle: "saranormous", role: .investor), .init(handle: "nathanbenaich", role: .investor),
        .init(handle: "levelsio", role: .builder), .init(handle: "amasad", role: .builder),
        .init(handle: "rauchg", role: .builder),
    ]
}

/// The quick read Claude Haiku writes for one story: what it contributes, finds, and reports, and what it opens up.
struct QuickRead: Codable, Hashable, Sendable {
    var contributions: [String]
    var findings: [String]
    var results: [String]
    /// Optional so quick reads cached before Limitations existed still load.
    var limitations: [String]?
    var opportunities: [String]

    /// Labelled Takeaways, in the order Contributions, Findings, Results, Limitations.
    var takeaways: [String] {
        contributions.map { "**Contribution:** \($0)" } + findings.map { "**Finding:** \($0)" }
            + results.map { "**Result:** \($0)" } + (limitations ?? []).map { "**Limitation:** \($0)" }
    }

    static func parse(_ text: String) -> QuickRead? {
        var groups: [String: [String]] = [:]
        var current = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let key = line.lowercased().filter(\.isLetter)
            if line.hasPrefix("#") || (line.hasSuffix(":") && line.count < 30) || (line.hasPrefix("**") && line.hasSuffix("**") && line.count < 30) {
                for k in ["contribution", "finding", "result", "limitation", "opportunit"] where key.contains(k) { current = k }
                continue
            }
            guard !current.isEmpty, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            groups[current, default: []].append(String(line.dropFirst(2)))
        }
        let r = QuickRead(contributions: groups["contribution"] ?? [], findings: groups["finding"] ?? [],
                          results: groups["result"] ?? [], limitations: groups["limitation"],
                          opportunities: groups["opportunit"] ?? [])
        return r.contributions.isEmpty && r.opportunities.isEmpty ? nil : r
    }
}

/// A desk-level digest written by the Synthesizer.
struct SectionDigest: Codable, Sendable {
    var text: String
    var generatedAt: Date
    var byLLM: String
}
