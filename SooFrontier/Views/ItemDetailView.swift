import SwiftUI

/// One item, laid out as TL;DR, Takeaways, and Potential opportunities, with the Council's debate below.
struct ItemDetailView: View {
    @Environment(FrontierStore.self) private var store
    @Environment(Reader.self) private var reader
    private var start: FrontierItem
    /// The list this story was opened from, for Previous / Next.
    private var sequence: [FrontierItem]
    /// When set (split views), moving updates the parent's selection; otherwise the page moves itself.
    private var selection: Binding<FrontierItem?>?
    @State private var moved: FrontierItem?

    init(item: FrontierItem, sequence: [FrontierItem] = [], selection: Binding<FrontierItem?>? = nil) {
        self.start = item
        self.sequence = sequence
        self.selection = selection
    }

    private var item: FrontierItem { moved ?? start }
    private var index: Int? { sequence.firstIndex { $0.id == item.id } }
    private var previous: FrontierItem? { index.flatMap { $0 > 0 ? sequence[$0 - 1] : nil } }
    private var next: FrontierItem? { index.flatMap { $0 + 1 < sequence.count ? sequence[$0 + 1] : nil } }

    @State private var critique: String?
    @State private var critiqueBy: String?
    @State private var critiquing = false
    @State private var council: [CouncilAgent.Turn] = []
    @State private var ruling: String?
    @State private var convening = false
    @State private var error: String?
    @State private var paper: PaperContent?
    @State private var paperLoaded = false
    @State private var quick: QuickRead?
    @State private var ideasLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                actions
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                }
                structured
                councilSection
                pager
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .id(item.id)
        .safeAreaInset(edge: .bottom) { ReaderBar().animation(.snappy, value: reader.isActive) }
        // Follow the reader as it moves through the list.
        .onChange(of: reader.currentItemID) { _, id in
            if let id, id != item.id, let target = sequence.first(where: { $0.id == id }) { move(to: target, followingReader: true) }
        }
        .task(id: item.id) {
            // Read the paper (full text and figures) in the background for figures and Analyze.
            if [.papers, .reports].contains(item.category) || PaperReader.arxivID(item.url) != nil {
                paper = await PaperReader.read(item)
            }
            paperLoaded = true
            quick = store.quickReads[item.id]
            if quick == nil {
                ideasLoading = true
                let id = item.id
                let points = KeyPoints.extract(summary: item.summary, fullText: paper?.text, exclude: quickTLDR)
                let result = await store.quickRead(for: item, content: paper, keyPoints: points)
                if item.id == id { quick = result; ideasLoading = false }
            }
            if let next { store.prefetchQuickRead(for: next) }
        }
        .navigationTitle(item.category.title)
        .inlineTitle()
        .toolbar {
            if index != nil, sequence.count > 1 {
                ToolbarItemGroup {
                    Button { move(to: previous) } label: { Label("Previous", systemImage: "chevron.up") }
                        .disabled(previous == nil)
                        .keyboardShortcut(.upArrow, modifiers: .command)
                        .help("Previous story (⌘↑)")
                    Button { move(to: next) } label: { Label("Next", systemImage: "chevron.down") }
                        .disabled(next == nil)
                        .keyboardShortcut(.downArrow, modifiers: .command)
                        .help("Next story (⌘↓)")
                }
            }
            ToolbarItem {
                Button { store.toggleSaved(item) } label: {
                    Label("Save", systemImage: store.saved.contains(item.id) ? "bookmark.fill" : "bookmark")
                }
            }
            ToolbarItem { ShareLink(item: item.url, subject: Text(item.title)) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            ItemEyebrow(item: item)
            Text(item.title)
                .font(Theme.display(30, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let a = item.author, !a.isEmpty { Text("By \(a)").fontWeight(.medium) }
                if let d = item.date { Text("·"); Text(d, format: .dateTime.month(.wide).day().year()) }
                if let t = item.tractionLabel { Text("·"); Text(t).monospacedDigit() }
            }
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                Image(systemName: item.agent.symbol)
                Text("Found by the \(item.agent.name)")
                Link(destination: item.url) {
                    Image(systemName: "arrow.up.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .accessibilityLabel("Read the source")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.accent)
                .padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.tertiary)
            if !item.tags.isEmpty {
                Text(item.tags.joined(separator: "  ·  ")).font(.caption).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 4)
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { Task { await runCritique() } } label: {
                    ActionLabel(title: critiquing ? "Analyzing…" : (critique == nil ? "Analyze" : "Re-analyze"), symbol: "eyeglasses")
                }
                .disabled(critiquing)
                Button { Task { await runCouncil() } } label: {
                    ActionLabel(title: convening ? "In session…" : "Council", symbol: "person.3")
                }
                .disabled(convening)
                Button { readingThis ? reader.stop() : listen() } label: {
                    ActionLabel(title: readingThis ? "Stop" : "Listen", symbol: readingThis ? "stop.fill" : "speaker.wave.2")
                }
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .controlSize(.large)
        .frame(maxWidth: 460)
    }

    // MARK: TL;DR · Takeaways · Potential opportunities

    private var analysis: Structure.Parsed? { critique.flatMap(Structure.parse) }

    /// Takeaways for the quick read, built from the story's own facts so the section is never empty.
    private var quickTakeaways: [String] {
        var out: [String] = []
        let tldr = quickTLDR
        var more: [String] = []
        item.summary.enumerateSubstrings(in: item.summary.startIndex..., options: .bySentences) { s, _, _, stop in
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, !tldr.contains(s) else { return }
            more.append(s)
            if more.count == 2 { stop = true }
        }
        out += more
        // The substance first: contributions, method, and results pulled from the abstract and full text.
        // Claude Haiku's story-specific Contributions, Findings, Results; the extracted sentences until it arrives.
        if let q = quick, !q.takeaways.isEmpty {
            out = q.takeaways
        } else {
            let points = KeyPoints.extract(summary: item.summary, fullText: paper?.text, exclude: tldr)
            if !points.isEmpty { out = points }
        }
        var where_ = "**Where it comes from:** Published by \(item.source)"
        if let d = item.date { where_ += " \(d.formatted(.relative(presentation: .named)))" }
        where_ += item.author.map { ", credited to \($0)." } ?? "."
        if let t = item.tractionLabel {
            where_ += " It has \(t) so far, a rough signal of how much attention it is getting, not of whether it holds up."
        }
        out.append(where_)
        if !item.tags.isEmpty, technicalDetails.isEmpty { out.append("**Topics:** It is tagged \(item.tags.joined(separator: ", ")), which places it among related \(item.category.title.lowercased()).") }
        if let a = item.assessment {
            let why = a.signal > a.hype
                ? "The evidence outweighs the promotional language, so it is worth reading closely."
                : "The language runs ahead of the evidence, so treat its claims as unverified until someone reproduces them."
            out.append("**Skeptic's verdict: \(a.verdict).** It scores \(Int(a.signal * 100)) for signal and \(Int(a.hype * 100)) for hype. \(why)")
            out += a.flags.map { "**Watch out:** \($0)." }
        }
        return out
    }

    /// Story-specific ideas when available; otherwise the authors' own future work, then the lane's defaults.
    private var quickOpportunities: [String] {
        if let ideas = quick?.opportunities, !ideas.isEmpty { return ideas }
        let authors = KeyPoints.futureWork(paper?.text)
        if !authors.isEmpty { return authors }
        return ideasLoading ? [] : SkepticAgent.opportunities(for: item.category)
    }

    /// The source's opening sentences plus the technical facts, so the quick read is a TL;DR with some substance.
    private var quickTLDR: String {
        var sentences: [String] = []
        item.summary.enumerateSubstrings(in: item.summary.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s { sentences.append(s.trimmingCharacters(in: .whitespaces)) }
            if sentences.count == 3 { stop = true }
        }
        var tldr = sentences.isEmpty ? item.title : sentences.joined(separator: " ")
        if !technicalDetails.isEmpty && !tldr.hasSuffix(".") { tldr += "." }
        if !technicalDetails.isEmpty { tldr += " " + technicalDetails }
        return tldr
    }

    /// Technical facts drawn from the item's tags and metadata (task, library, format, language, arXiv ID).
    private var technicalDetails: String {
        let tags = item.tags.filter { !["HN", "demo", "Voice"].contains($0) && !Voice.Role.allCases.map(\.title).contains($0) }
        guard !tags.isEmpty else { return "" }
        switch item.category {
        case .models: return "Technical details: \(tags.joined(separator: ", ")); \(item.tractionLabel ?? "") on Hugging Face."
        case .code: return "Built with \(tags.joined(separator: ", ")); \(item.tractionLabel ?? "") on GitHub."
        case .demos: return "Runs as a \(tags.joined(separator: ", ")) app on Hugging Face Spaces."
        case .papers, .reports: return "Reference: \(tags.joined(separator: ", "))."
        default: return ""
        }
    }


    @ViewBuilder private var structured: some View {
        VStack(alignment: .leading, spacing: 12) {
            if critiquing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Writing a detailed analysis…").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            if analysis != nil, let critiqueBy {
                Text("Analysis by \(critiqueBy)").eyebrow()
            } else if critique == nil {
                Text("Quick read · tap Analyze for the full analysis with math").eyebrow()
            }
            if let critique, analysis == nil {
                // The model ignored the structure; show what it wrote rather than nothing.
                MarkdownText(text: critique, serif: true)
            } else {
                let a = item.assessment
                StructuredSections(
                    tldr: Text(markdown: analysis?.tldr ?? quickTLDR),
                    takeaways: (analysis?.takeaways ?? quickTakeaways).map { Text(markdown: $0) },
                    math: analysis?.math ?? [],
                    opportunities: (analysis?.opportunities ?? quickOpportunities).map { Text(markdown: $0) },
                    opportunitiesLoading: analysis == nil && ideasLoading && quickOpportunities.isEmpty
                ) {
                    if let a { SignalMeter(assessment: a).padding(.bottom, 4) }
                    if let figs = paper?.keyFigures(), !figs.isEmpty { KeyFigures(figures: figs).padding(.bottom, 6) }
                }
            }
        }
    }

    // MARK: Council

    @ViewBuilder private var councilSection: some View {
        if convening || !council.isEmpty {
            VStack(alignment: .leading, spacing: 20) {
                SectionRule(title: "The Frontier Council")
                ForEach(Provider.allCases.filter { store.configuredProviders.contains($0) }) { p in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(p.councilSeat.title).eyebrow(.primary)
                            Text("· \(p.family)").eyebrow()
                        }
                        if let t = council.first(where: { $0.provider == p }) {
                            if t.failed { Text(t.text).font(.callout).foregroundStyle(.red) }
                            else { MarkdownText(text: t.text, serif: true) }
                        } else {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Deliberating…").foregroundStyle(.secondary) }
                                .font(.callout)
                        }
                    }
                    Divider()
                }
                if let ruling, !ruling.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The ruling").eyebrow(Theme.accent)
                        StructuredText(text: ruling)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
                } else if convening && council.count == store.configuredProviders.count {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("The moderator is ruling…").foregroundStyle(.secondary) }
                        .font(.callout)
                }
            }
        }
    }

    // MARK: Previous / Next

    @ViewBuilder private var pager: some View {
        if let index, sequence.count > 1 {
            VStack(spacing: 12) {
                Divider()
                HStack {
                    Button { move(to: previous) } label: { Label("Previous", systemImage: "arrow.left") }
                        .disabled(previous == nil)
                    Spacer()
                    Text("\(index + 1) of \(sequence.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button { move(to: next) } label: {
                        HStack(spacing: 6) { Text("Next"); Image(systemName: "arrow.right") }
                    }
                    .disabled(next == nil)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Theme.accent)
            }
        }
    }

    // MARK: Read aloud

    private var readingThis: Bool { reader.isActive && reader.currentItemID == item.id }

    /// Starts reading here and on through the list. The reader owns the playlist, so it keeps going
    /// with the screen locked, in the background, or with no network or Mac bridge.
    private func listen() {
        let a = analysis
        // This page's fuller script (analysis, figures-aware takeaways); later stories use on-device data.
        let here = Reader.script(
            tldr: a?.tldr ?? quickTLDR,
            takeaways: a?.takeaways ?? quickTakeaways,
            math: a?.math ?? [],
            opportunities: a?.opportunities ?? quickOpportunities)
        let list = index == nil ? [item] : sequence
        let id = item.id
        reader.play(list, from: index ?? 0) { [store] it in
            it.id == id ? here : ReadAloud.script(for: it, store: store)
        }
    }

    private func move(to target: FrontierItem?, followingReader: Bool = false) {
        guard let target else { return }
        // Moving by hand while listening carries the reading along.
        if readingThis && !followingReader { reader.jump(to: target.id) }
        critique = nil; critiqueBy = nil; critiquing = false; paper = nil; paperLoaded = false; quick = nil; ideasLoading = false
        council = []; ruling = nil; convening = false; error = nil
        if let selection { selection.wrappedValue = target } else { moved = target }
    }

    // MARK: Agents

    private func runCritique() async {
        let id = item.id
        critiquing = true; error = nil
        defer { if item.id == id { critiquing = false } }
        do {
            if !paperLoaded, [.papers, .reports].contains(item.category) { paper = await PaperReader.read(item) }
            let result = try await store.critique(item, content: paper)
            if item.id == id { (critique, critiqueBy) = result }
        } catch { if item.id == id { self.error = error.localizedDescription } }
    }

    private func runCouncil() async {
        let id = item.id
        convening = true; error = nil; council = []; ruling = nil
        defer { if item.id == id { convening = false } }
        do {
            let r = try await store.convene(item) { turn in if item.id == id { council.append(turn) } }
            if item.id == id { ruling = r }
        } catch { if item.id == id { self.error = error.localizedDescription } }
    }
}

/// Icon-over-title label so three actions fit side by side on a phone.
private struct ActionLabel: View {
    var title: String
    var symbol: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(height: 20)
            Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

/// The paper's main pipeline / framework figures, with captions; tap to enlarge.
private struct KeyFigures: View {
    var figures: [PaperFigure]
    @State private var zoomed: PaperFigure?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Key figures").eyebrow(Theme.accent)
            ForEach(figures) { f in
                VStack(alignment: .leading, spacing: 6) {
                    AsyncImage(url: f.url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.primary.opacity(0.08)))
                                .onTapGesture { zoomed = f }
                        case .failure:
                            Label("Figure unavailable", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        default:
                            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 160)
                                .overlay(ProgressView())
                        }
                    }
                    Text(f.caption).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
            }
        }
        .sheet(item: $zoomed) { f in
            NavigationStack {
                ScrollView([.vertical, .horizontal]) {
                    AsyncImage(url: f.url) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                        .background(Color.white)
                        .padding()
                    Text(f.caption).font(.callout).padding(.horizontal)
                }
                .navigationTitle(f.label ?? "Figure")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { zoomed = nil } } }
            }
        }
    }
}
