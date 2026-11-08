import SwiftUI

/// The Brief: SooFrontier's front page.
struct MissionControlView: View {
    @Environment(FrontierStore.self) private var store
    @Environment(Reader.self) private var reader

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                let wide = geo.size.width > 900
                VStack(alignment: .leading, spacing: 28) {
                    masthead
                    if wide {
                        HStack(alignment: .top, spacing: 40) {
                            VStack(alignment: .leading, spacing: 28) {
                                brief
                                crew
                            }
                            .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                            VStack(alignment: .leading, spacing: 28) {
                                signals
                                hype
                            }
                            .frame(maxWidth: 380, alignment: .leading)
                        }
                    } else {
                        brief
                        signals
                        hype
                        crew
                    }
                }
                .padding(.horizontal, wide ? 48 : 20)
                .padding(.vertical, 24)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) { ReaderBar().animation(.snappy, value: reader.isActive) }
        .navigationTitle("Brief")
        .brandToolbar("Brief")
        .inlineTitle()
        .toolbar {
            ToolbarItem {
                NavigationLink { SavedView() } label: { Label("Saved", systemImage: "bookmark") }
            }
            ToolbarItem { RefreshButton() }
        }
        .refreshable { await store.refresh() }
    }

    // MARK: Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).eyebrow()
            HStack(spacing: 6) {
                Text("\(store.items.count) signals · \(AgentKind.allCases.count) agents")
                if let d = store.lastRefresh { Text("· updated \(d, format: .relative(presentation: .named))") }
                Text("· next update \(DailyRefresh.nextRun(), format: .dateTime.weekday(.abbreviated).hour().minute())")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                ForEach(Provider.allCases) { p in
                    let on = store.client(p) != nil
                    HStack(spacing: 5) {
                        Circle().fill(on ? Color.green : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                        Text(p.family).font(.caption.weight(.medium)).foregroundStyle(on ? .primary : .tertiary)
                    }
                }
            }
            Rectangle().fill(.primary).frame(height: 2).padding(.top, 6)
        }
    }

    // MARK: Brief

    private var brief: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.brief?.byLLM.map { "Written by \($0)" } ?? "Synthesizer").eyebrow()
                Spacer()
                if let b = store.brief {
                    Button {
                        if reader.title == "The Frontier Brief" { reader.stop(); return }
                        let p = Structure.parse(b.text)
                        let parts = p.map { Reader.script(tldr: $0.tldr, takeaways: $0.takeaways, opportunities: $0.opportunities) }
                            ?? b.text.components(separatedBy: "\n")
                        reader.read(title: "The Frontier Brief", parts: ["The Frontier Brief."] + parts)
                    } label: {
                        Label(reader.title == "The Frontier Brief" ? "Stop" : "Listen",
                              systemImage: reader.title == "The Frontier Brief" ? "stop.fill" : "speaker.wave.2")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
                Button { Task { await store.synthesize() } } label: {
                    Label("Rewrite", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(store.status[.synthesizer]?.isWorking == true || store.items.isEmpty)
            }
            if store.status[.synthesizer]?.isWorking == true {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text((store.status[.synthesizer] ?? .idle).label).font(Theme.body).foregroundStyle(.secondary)
                }
            }
            if let b = store.brief {
                StructuredText(text: b.text)
            } else if !store.isRefreshing {
                Text("Dispatch the agents to write today's brief.").font(Theme.body).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Signals

    private var signals: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionRule(title: "Top signals", trailing: "Across all lanes")
            ForEach(Array(store.topSignals.enumerated()), id: \.element.id) { i, item in
                NavigationLink { ItemDetailView(item: item, sequence: store.topSignals) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(String(format: "%02d", i + 1))
                            .font(Theme.display(20, weight: .regular)).foregroundStyle(.tertiary)
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 4) {
                            ItemEyebrow(item: item)
                            Text(item.title).font(.system(.body, design: Theme.design, weight: .semibold))
                                .foregroundStyle(.primary).multilineTextAlignment(.leading).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    @ViewBuilder private var hype: some View {
        if !store.hypeWatch.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionRule(title: "Hype watch", trailing: "Flagged by the Skeptic")
                ForEach(store.hypeWatch) { item in
                    NavigationLink { ItemDetailView(item: item, sequence: store.hypeWatch) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            ItemEyebrow(item: item)
                            Text(item.title).font(.system(.callout, design: Theme.design, weight: .medium))
                                .foregroundStyle(.primary).multilineTextAlignment(.leading)
                            if let flag = item.assessment?.flags.first {
                                Text(flag).font(.caption).foregroundStyle(.secondary).italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    // MARK: Crew

    private var crew: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionRule(title: "The crew", trailing: store.isRefreshing ? "On assignment" : nil)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 14) {
                ForEach(AgentKind.allCases) { a in
                    let s = store.status[a] ?? .idle
                    let on = store.enabledAgents.contains(a)
                    HStack(spacing: 10) {
                        AgentBadge(kind: a, status: s, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.subheadline.weight(.semibold))
                            Text(on ? s.label : "Off duty")
                                .font(.caption).foregroundStyle(statusColor(s)).lineLimit(1)
                        }
                    }
                    .opacity(on ? 1 : 0.4)
                }
            }
        }
    }

    private func statusColor(_ s: AgentStatus) -> Color {
        if case .failed = s { return .red }
        return .secondary
    }
}
