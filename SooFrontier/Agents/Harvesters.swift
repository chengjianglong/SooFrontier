import Foundation

/// A harvesting agent: goes out to the web and comes back with items for its lanes.
protocol HarvestAgent: Sendable {
    var kind: AgentKind { get }
    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem]
}

private func feedItems(_ entries: [(source: String, entry: FeedParser.Entry)], agent: AgentKind,
                       category: FrontierCategory) -> [FrontierItem] {
    entries.compactMap { s, e in
        guard !e.title.isEmpty, let url = URL(string: e.link) else { return nil }
        return FrontierItem(title: Text2.plain(e.title, limit: 200), summary: Text2.plain(e.summary),
                            url: url, source: s, category: category, agent: agent,
                            author: e.author.isEmpty ? nil : e.author, date: Text2.date(e.date),
                            tags: Array(e.categories.prefix(4)))
    }
}

private func arxiv(_ query: String, max: Int) async -> [FeedParser.Entry] {
    var comps = URLComponents(string: "https://export.arxiv.org/api/query")!
    comps.queryItems = [.init(name: "search_query", value: query), .init(name: "sortBy", value: "submittedDate"),
                        .init(name: "sortOrder", value: "descending"), .init(name: "max_results", value: "\(max)")]
    guard let data = try? await Net.data(comps.url!) else { return [] }
    return FeedParser.parse(data)
}

// MARK: Archivist — SOTA papers and technical reports

struct ArchivistAgent: HarvestAgent {
    let kind = AgentKind.archivist

    static let labFeeds = [
        ("Google Research", "https://research.google/blog/rss/"),
        ("Microsoft Research", "https://www.microsoft.com/en-us/research/feed/"),
        ("NVIDIA Technical Blog", "https://developer.nvidia.com/blog/feed"),
        ("Hugging Face", "https://huggingface.co/blog/feed.xml"),
        ("Berkeley AI Research", "https://bair.berkeley.edu/blog/feed.xml"),
    ]

    private struct DailyPaper: Decodable {
        struct Paper: Decodable {
            var id: String
            var title: String
            var summary: String?
            var upvotes: Int?
            var authors: [Author]?
            struct Author: Decodable { var name: String? }
        }
        var paper: Paper
        var publishedAt: String?
    }

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Pulling HF Daily Papers…")
        let daily = (try? await Net.json([DailyPaper].self, from: URL(string: "https://huggingface.co/api/daily_papers?limit=40")!)) ?? []
        var items = daily.map { d in
            FrontierItem(title: d.paper.title, summary: Text2.plain(d.paper.summary ?? ""),
                         url: URL(string: "https://arxiv.org/abs/\(d.paper.id)")!, source: "HF Daily Papers",
                         category: .papers, agent: kind,
                         author: d.paper.authors?.prefix(3).compactMap(\.name).joined(separator: ", "),
                         date: d.publishedAt.flatMap(Text2.date), tags: ["arXiv \(d.paper.id)"],
                         traction: Double(d.paper.upvotes ?? 0) * 10, tractionLabel: "\(d.paper.upvotes ?? 0) upvotes")
        }
        await report("Scanning arXiv for new work…")
        let cats = "(cat:cs.AI OR cat:cs.LG OR cat:cs.CL OR cat:cs.CV)"
        items += feedItems((await arxiv(cats, max: 25)).map { (source: "arXiv", entry: $0) }, agent: kind, category: .papers)
        await report("Collecting technical reports…")
        items += feedItems((await arxiv("ti:\"technical report\" AND \(cats)", max: 20)).map { (source: "arXiv", entry: $0) },
                           agent: kind, category: .reports)
        items += feedItems(await Net.feeds(Self.labFeeds), agent: kind, category: .reports)
        return items.map { var i = $0; i.tags = i.tags.filter { !$0.hasPrefix("cs.") || i.source == "arXiv" }; return i }
    }
}

// MARK: Showrunner — demos

struct ShowrunnerAgent: HarvestAgent {
    let kind = AgentKind.showrunner

    private struct Space: Decodable {
        var id: String
        var likes: Int?
        var sdk: String?
        var createdAt: String?
        var lastModified: String?
        var cardData: Card?
        struct Card: Decodable { var title: String?; var short_description: String?; var emoji: String? }
    }

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Queueing up trending Spaces…")
        let url = URL(string: "https://huggingface.co/api/spaces?sort=trendingScore&direction=-1&limit=36&full=true")!
        let spaces = try await Net.json([Space].self, from: url)
        return spaces.map { s in
            let name = s.cardData?.title.map { "\(s.cardData?.emoji ?? "✨") \($0)" } ?? s.id
            return FrontierItem(title: name, summary: s.cardData?.short_description ?? "Interactive demo by \(s.id.split(separator: "/").first ?? "")",
                                url: URL(string: "https://huggingface.co/spaces/\(s.id)")!, source: "HF Spaces",
                                category: .demos, agent: kind, author: s.id.split(separator: "/").first.map(String.init),
                                date: (s.lastModified ?? s.createdAt).flatMap(Text2.date), tags: [s.sdk ?? "demo"],
                                traction: Double(s.likes ?? 0) * 3, tractionLabel: "\(s.likes ?? 0) likes")
        }
    }
}

// MARK: Librarian — code

struct LibrarianAgent: HarvestAgent {
    let kind = AgentKind.librarian

    private struct Search: Decodable {
        var items: [Repo]
        struct Repo: Decodable {
            var full_name: String
            var html_url: URL
            var description: String?
            var stargazers_count: Int
            var language: String?
            var topics: [String]?
            var created_at: String?
        }
    }

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Searching GitHub for rising repos…")
        let since = Date.now.addingTimeInterval(-86400 * 45).formatted(.iso8601.year().month().day())
        // GitHub search can't OR qualifiers, so ask once per topic and merge.
        var repos: [Search.Repo] = []
        for topic in ["llm", "ai-agents", "machine-learning"] {
            var comps = URLComponents(string: "https://api.github.com/search/repositories")!
            comps.queryItems = [
                .init(name: "q", value: "topic:\(topic) created:>\(since)"),
                .init(name: "sort", value: "stars"), .init(name: "order", value: "desc"), .init(name: "per_page", value: "15"),
            ]
            if let r = try? await Net.json(Search.self, from: comps.url!) { repos += r.items }
        }
        guard !repos.isEmpty else { throw URLError(.cannotLoadFromNetwork, userInfo: [NSLocalizedDescriptionKey: "GitHub search unavailable"]) }
        return repos.map { r in
            FrontierItem(title: r.full_name, summary: r.description ?? "Open-source project",
                         url: r.html_url, source: "GitHub", category: .code, agent: kind,
                         author: r.full_name.split(separator: "/").first.map(String.init),
                         date: r.created_at.flatMap(Text2.date),
                         tags: ([r.language].compactMap { $0 } + (r.topics ?? [])).prefix(4).map { $0 },
                         traction: Double(r.stargazers_count), tractionLabel: "★ \(r.stargazers_count.formatted(.number.notation(.compactName)))")
        }
    }
}

// MARK: Curator — models

struct CuratorAgent: HarvestAgent {
    let kind = AgentKind.curator

    private struct HFModel: Decodable {
        var id: String
        var likes: Int?
        var downloads: Int?
        var pipeline_tag: String?
        var createdAt: String?
        var tags: [String]?
    }

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Reading the Hugging Face leaderboard…")
        let url = URL(string: "https://huggingface.co/api/models?sort=trendingScore&direction=-1&limit=40")!
        let models = try await Net.json([HFModel].self, from: url)
        return models.map { m in
            let org = m.id.split(separator: "/").first.map(String.init) ?? "community"
            let task = m.pipeline_tag?.replacingOccurrences(of: "-", with: " ") ?? "model"
            let downloads = m.downloads.map { "\($0.formatted(.number.notation(.compactName))) downloads" } ?? ""
            let interesting = (m.tags ?? []).filter { !$0.contains(":") && $0.count < 20 }.prefix(4)
            return FrontierItem(title: m.id, summary: "Trending \(task) from \(org). \(downloads)",
                                url: URL(string: "https://huggingface.co/\(m.id)")!, source: "Hugging Face",
                                category: .models, agent: kind, author: org, date: m.createdAt.flatMap(Text2.date),
                                tags: [task] + interesting, traction: Double(m.likes ?? 0) * 5,
                                tractionLabel: "\(m.likes ?? 0) likes")
        }
    }
}

// MARK: Scout — AI products

struct ScoutAgent: HarvestAgent {
    let kind = AgentKind.scout
    static let feeds = [
        ("The Verge AI", "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml"),
        ("TechCrunch AI", "https://techcrunch.com/category/artificial-intelligence/feed/"),
        ("Ars Technica AI", "https://arstechnica.com/ai/feed/"),
        ("VentureBeat AI", "https://venturebeat.com/category/ai/feed/"),
        ("MIT Tech Review", "https://www.technologyreview.com/topic/artificial-intelligence/feed"),
    ]

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Sweeping \(Self.feeds.count) newsrooms…")
        var items = feedItems(await Net.feeds(Self.feeds), agent: kind, category: .products)
        await report("Checking launches on Hacker News…")
        items += (try? await HackerNews.stories(query: "AI launch OR launches OR released OR introducing", minPoints: 100,
                                                agent: kind, category: .products)) ?? []
        return items
    }
}

// MARK: Analyst — AI services

struct AnalystAgent: HarvestAgent {
    let kind = AgentKind.analyst
    static let feeds = [
        ("AWS Machine Learning", "https://aws.amazon.com/blogs/machine-learning/feed/"),
        ("Google Cloud AI", "https://cloudblog.withgoogle.com/products/ai-machine-learning/rss/"),
        ("Cloudflare AI", "https://blog.cloudflare.com/tag/ai/rss/"),
        ("Hugging Face", "https://huggingface.co/blog/feed.xml"),
    ]

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Reading \(Self.feeds.count) platform blogs…")
        var items = feedItems(await Net.feeds(Self.feeds), agent: kind, category: .services)
        // Hugging Face's blog is mostly research; keep only its platform and pricing posts here.
        items.removeAll { $0.source == "Hugging Face" && !$0.title.localizedCaseInsensitiveContains("inference")
            && !$0.title.localizedCaseInsensitiveContains("endpoint") && !$0.title.localizedCaseInsensitiveContains("hub") }
        await report("Checking API and pricing news…")
        items += (try? await HackerNews.stories(query: "AI API pricing OR \"inference API\" OR \"AI platform\"", minPoints: 60,
                                                agent: kind, category: .services)) ?? []
        return items
    }
}

// MARK: Pundit — essays

struct PunditAgent: HarvestAgent {
    let kind = AgentKind.pundit
    static let feeds = [
        ("Simon Willison", "https://simonwillison.net/atom/everything/"),
        ("Interconnects", "https://www.interconnects.ai/feed"),
        ("Import AI", "https://importai.substack.com/feed"),
        ("One Useful Thing", "https://www.oneusefulthing.org/feed"),
        ("Gary Marcus", "https://garymarcus.substack.com/feed"),
        ("Lil'Log", "https://lilianweng.github.io/index.xml"),
        ("The Gradient", "https://thegradient.pub/rss/"),
        ("Latent Space", "https://www.latent.space/feed"),
    ]

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Reading \(Self.feeds.count) newsletters…")
        return feedItems(await Net.feeds(Self.feeds), agent: kind, category: .essays)
    }
}

// MARK: Correspondent — blogs from AI model and data companies

struct CorrespondentAgent: HarvestAgent {
    let kind = AgentKind.correspondent

    /// Companies without their own RSS feed are read through Olshansk/rss-feeds, a community project that mirrors their news pages.
    private static let mirror = "https://raw.githubusercontent.com/Olshansk/rss-feeds/main/feeds/"

    static let feeds = [
        // Model providers
        ("OpenAI", "https://openai.com/news/rss.xml"),
        ("Anthropic", mirror + "feed_anthropic_news.xml"),
        ("Google DeepMind", "https://blog.google/technology/google-deepmind/rss/"),
        ("Google AI", "https://blog.google/technology/ai/rss/"),
        ("Meta AI", mirror + "feed_meta_ai.xml"),
        ("Mistral AI", mirror + "feed_mistral.xml"),
        ("xAI", mirror + "feed_xainews.xml"),
        ("NVIDIA", "https://blogs.nvidia.com/feed/"),
        ("Together AI", "https://www.together.ai/blog/rss.xml"),
        // Data companies
        ("Databricks", "https://www.databricks.com/feed"),
        ("Snorkel AI", "https://snorkel.ai/feed/"),
    ]

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        await report("Reading \(Self.feeds.count) company blogs…")
        let items = feedItems(await Net.feeds(Self.feeds), agent: kind, category: .companies)
        guard !items.isEmpty else { throw URLError(.cannotLoadFromNetwork, userInfo: [NSLocalizedDescriptionKey: "Company blogs unavailable"]) }
        return items
    }
}

// MARK: Listener — voices on X, read by Grok

struct ListenerAgent: HarvestAgent {
    let kind = AgentKind.listener
    var voices: [Voice]
    var grok: LLMClient?

    private struct Post: Decodable {
        var name: String?
        var handle: String
        var headline: String?
        var summary: String?
        var url: String?
        var date: String?
    }

    static let system = """
    You are the Listener agent in SooFrontier, an app for AI researchers. Use web search to find recent posts on X (x.com). \
    Reply ONLY with a JSON array, with no prose before or after it.
    """

    func harvest(report: @escaping @Sendable (String) async -> Void) async throws -> [FrontierItem] {
        guard let grok, grok.provider == .xai else {
            throw LLMError(message: "Connect Grok in Settings to hear voices on X")
        }
        guard grok.mode == .subscription else {
            throw LLMError(message: "Voices on X need Grok on your SuperGrok plan")
        }
        guard !voices.isEmpty else { return [] }
        let roles = Dictionary(voices.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
        let batches = stride(from: 0, to: voices.count, by: 7).map { Array(voices[$0..<min($0 + 7, voices.count)]) }
        await report("Asking Grok about \(voices.count) voices on X…")

        var posts: [Post] = []
        var lastError: Error?
        await withTaskGroup(of: Result<[Post], Error>.self) { group in
            for batch in batches {
                group.addTask {
                    let handles = batch.map { "@\($0.handle)" }.joined(separator: ", ")
                    let prompt = """
                    Today is \(Date.now.formatted(.iso8601.year().month().day())). Use web search to find posts on X (x.com) \
                    from these accounts in the last 7 days: \(handles).
                    For each account, summarize their most notable opinion about AI.
                    Reply ONLY with a JSON array of objects with keys: name, handle (without @), headline (at most 12 words), \
                    summary (2 sentences), url (link to the post on x.com), date (ISO 8601).
                    Skip accounts with no AI posts in that window. Never invent posts or links.
                    """
                    do {
                        let text = try await grok.complete(system: Self.system, prompt: prompt, maxTokens: 8000, research: true)
                        return .success(Self.decode(text))
                    } catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case .success(let p): posts += p
                case .failure(let e): lastError = e
                }
            }
        }
        if posts.isEmpty, let lastError { throw lastError }
        return posts.compactMap { p in
            guard let urlString = p.url, let url = URL(string: urlString), url.host()?.contains("x.com") == true
                    || url.host()?.contains("twitter.com") == true else { return nil }
            let handle = p.handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
            let role = roles[handle.lowercased()]
            return FrontierItem(title: p.headline ?? "Post by @\(handle)", summary: p.summary ?? "",
                                url: url, source: "@\(handle)", category: .voices, agent: kind,
                                author: p.name, date: p.date.flatMap(Text2.date),
                                tags: [role?.title ?? "Voice"])
        }
    }

    private static func decode(_ text: String) -> [Post] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return [] }
        return (try? JSONDecoder().decode([Post].self, from: Data(text[start...end].utf8))) ?? []
    }
}

enum HackerNews {
    private struct Result: Decodable {
        var hits: [Hit]
        struct Hit: Decodable {
            var objectID: String
            var title: String?
            var url: String?
            var points: Int?
            var num_comments: Int?
            var author: String?
            var created_at: String?
        }
    }

    static func stories(query: String, minPoints: Int, agent: AgentKind, category: FrontierCategory) async throws -> [FrontierItem] {
        let since = Int(Date.now.addingTimeInterval(-86400 * 7).timeIntervalSince1970)
        var comps = URLComponents(string: "https://hn.algolia.com/api/v1/search")!
        comps.queryItems = [
            .init(name: "query", value: query), .init(name: "tags", value: "story"),
            .init(name: "numericFilters", value: "points>\(minPoints),created_at_i>\(since)"),
            .init(name: "hitsPerPage", value: "20"),
        ]
        let r = try await Net.json(Result.self, from: comps.url!)
        return r.hits.compactMap { h in
            guard let title = h.title else { return nil }
            let discussion = URL(string: "https://news.ycombinator.com/item?id=\(h.objectID)")!
            return FrontierItem(title: title, summary: "\(h.points ?? 0) points · \(h.num_comments ?? 0) comments on Hacker News",
                                url: h.url.flatMap(URL.init(string:)) ?? discussion,
                                source: "Hacker News", category: category, agent: agent, author: h.author,
                                date: h.created_at.flatMap(Text2.date), tags: ["HN"],
                                traction: Double(h.points ?? 0), tractionLabel: "▲ \(h.points ?? 0)")
        }
    }
}
