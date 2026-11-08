import SwiftUI

enum AppTab: String, Hashable {
    case brief, research, productions, opinions, brainstorm, settings
}

struct RootView: View {
    @Environment(FrontierStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// iPhone's tab bar shows five tabs; there Settings moves to a gear button on every tab.
    private var settingsAsTab: Bool {
        #if os(iOS)
        sizeClass != .compact
        #else
        true
        #endif
    }
    @SceneStorage("tab") private var tab: AppTab = .brief

    var body: some View {
        TabView(selection: $tab) {
            Tab("Brief", systemImage: "newspaper", value: AppTab.brief) {
                NavigationStack { MissionControlView() }
            }
            Tab(FrontierSection.research.title, systemImage: FrontierSection.research.symbol, value: AppTab.research) {
                SectionTab(section: .research)
            }
            Tab(FrontierSection.productions.title, systemImage: FrontierSection.productions.symbol, value: AppTab.productions) {
                SectionTab(section: .productions)
            }
            Tab(FrontierSection.opinions.title, systemImage: FrontierSection.opinions.symbol, value: AppTab.opinions) {
                SectionTab(section: .opinions)
            }
            Tab("Brainstorm", systemImage: "bubble.left.and.bubble.right", value: AppTab.brainstorm) {
                NavigationStack { BrainstormView() }
            }
            if settingsAsTab {
                Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                    NavigationStack { SettingsView() }
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        // Refresh at 6:00 am Pacific each day, and catch up on launch or return if that run was missed.
        .task { DailyRefresh.start(store) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { DailyRefresh.start(store) } }
    }
}

/// One desk: its lanes as a tab strip over one list, a digest bar, and a detail pane on wide screens.
struct SectionTab: View {
    @Environment(FrontierStore.self) private var store
    var section: FrontierSection
    @SceneStorage private var lane: FrontierCategory
    @State private var selection: FrontierItem?

    init(section: FrontierSection) {
        self.section = section
        _lane = SceneStorage(wrappedValue: section.lanes[0], "lane.\(section.rawValue)")
    }

    var body: some View {
        // One full-width column on every device: title, Filter, lane tabs, then stories. A story opens full screen.
        NavigationStack {
            FeedView(title: section.title, items: store.items(in: lane), selection: $selection) {
                VStack(spacing: 0) {
                    LaneTabStrip(lanes: section.lanes, selection: $lane)
                    DigestBar(section: section)
                }
            }
            .brandToolbar(section.title)
            .navigationDestination(item: $selection) { item in
                ItemDetailView(item: store.items.first { $0.id == item.id } ?? item,
                               sequence: store.items(in: lane), selection: $selection)
                    .id(item.id)
            }
        }
        .onChange(of: lane) { selection = nil }
    }
}

/// The desk's digest: written on demand by the Synthesizer, read in a sheet.
struct DigestBar: View {
    @Environment(FrontierStore.self) private var store
    var section: FrontierSection
    @State private var reading = false
    @State private var error: String?

    private var digest: SectionDigest? { store.digests[section] }
    private var working: Bool { store.digestsInProgress.contains(section) }

    private var label: String {
        switch section {
        case .research: "Research digest"
        case .productions: "Analyst's take"
        case .opinions: "Consensus & dissent"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).eyebrow(.primary)
                    Group {
                        if working { Text("Writing…") }
                        else if let error { Text(error).foregroundStyle(.red) }
                        else if let d = digest { Text("Updated \(d.generatedAt, format: .relative(presentation: .named))") }
                        else { Text("Across every lane in \(section.title)") }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if digest != nil {
                    Button("Read") { reading = true }
                        .buttonStyle(.bordered).controlSize(.small).tint(Theme.accent)
                }
                Button(digest == nil ? "Write" : "Rewrite") {
                    Task {
                        error = nil
                        do { try await store.writeDigest(section); reading = true }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderless).controlSize(.small)
                .disabled(working)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
        }
        .background(.background)
        .sheet(isPresented: $reading) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(section.title).eyebrow()
                        Text(label).font(Theme.display(30, weight: .bold))
                        if let d = digest {
                            Text("Written by \(d.byLLM)").font(.caption).foregroundStyle(.secondary)
                            Divider()
                            StructuredText(text: d.text)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: Theme.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { reading = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 560, minHeight: 520)
            #endif
        }
    }
}

/// Saved stories, opened from the Brief.
struct SavedView: View {
    @Environment(FrontierStore.self) private var store

    var body: some View {
        List {
            ForEach(store.savedItems) { item in
                NavigationLink { ItemDetailView(item: item, sequence: store.savedItems) } label: {
                    ItemRow(item: item, saved: true, showLane: true)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.savedItems.isEmpty {
                ContentUnavailableView("Nothing saved yet", systemImage: "bookmark",
                                       description: Text("Tap the bookmark on any story to keep it here."))
            }
        }
        .navigationTitle("Saved")
    }
}

struct ItemDetailOrPlaceholder: View {
    @Environment(FrontierStore.self) private var store
    @Binding var selection: FrontierItem?
    var sequence: [FrontierItem]

    var body: some View {
        if let item = selection {
            ItemDetailView(item: store.items.first { $0.id == item.id } ?? item, sequence: sequence, selection: $selection)
                .id(item.id)
        } else {
            VStack(spacing: 10) {
                Text("SooFrontier").eyebrow()
                Text("Select a story").font(Theme.display(28))
                Text("Read the Skeptic's assessment or convene the Council.")
                    .font(Theme.body).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding()
        }
    }
}

/// Underlined text tabs for a desk's lanes, in the manner of a newspaper section bar.
struct LaneTabStrip: View {
    @Environment(FrontierStore.self) private var store
    var lanes: [FrontierCategory]
    @Binding var selection: FrontierCategory
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(lanes) { c in
                            let on = c == selection
                            Button {
                                withAnimation(.snappy(duration: 0.25)) { selection = c }
                            } label: {
                                VStack(spacing: 7) {
                                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                                        Text(c.title)
                                            .font(.subheadline.weight(on ? .semibold : .regular))
                                            .foregroundStyle(on ? .primary : .secondary)
                                        Text("\(store.items(in: c).count)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                    ZStack {
                                        Rectangle().fill(.clear).frame(height: 2)
                                        if on {
                                            Rectangle().fill(Theme.accent).frame(height: 2)
                                                .matchedGeometryEffect(id: "underline", in: underline)
                                        }
                                    }
                                }
                                .fixedSize()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(c)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                }
                .onChange(of: selection) { withAnimation { proxy.scrollTo(selection, anchor: .center) } }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
            }
            Divider()
        }
        .background(.background)
    }
}

struct FeedView<Header: View>: View {
    @Environment(FrontierStore.self) private var store
    var title: String
    var items: [FrontierItem]
    @Binding var selection: FrontierItem?
    var showLane = false
    @ViewBuilder var header: Header
    @State private var query = ""
    @State private var hideHype = false

    private var filtered: [FrontierItem] {
        items.filter { i in
            (query.isEmpty || i.title.localizedCaseInsensitiveContains(query) || i.summary.localizedCaseInsensitiveContains(query)
                || i.source.localizedCaseInsensitiveContains(query))
            && (!hideHype || (i.assessment?.verdict != "Hype alert"))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        #if os(iOS)
        // Always show the Filter box under the title, with the lane tabs right below it.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter \(title.lowercased())")
        #else
        .searchable(text: $query, prompt: "Filter \(title.lowercased())")
        #endif
        .navigationTitle(title)
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $hideHype) { Label("Hide hype", systemImage: "eyeglasses") }
                    .help("Hide items the Skeptic flags as hype")
            }
            ToolbarItem { RefreshButton() }
        }
    }

    private var list: some View {
        List(filtered) { item in
            Button { selection = item } label: {
                ItemRow(item: item, saved: store.saved.contains(item.id), showLane: showLane)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
                .listRowSeparatorTint(.primary.opacity(0.12))
                .swipeActions {
                    Button { store.toggleSaved(item) } label: { Label("Save", systemImage: "bookmark") }.tint(.indigo)
                }
                .contextMenu {
                    Button(store.saved.contains(item.id) ? "Unsave" : "Save") { store.toggleSaved(item) }
                    Link("Open in Browser", destination: item.url)
                    ShareLink(item: item.url)
                }
        }
        .listStyle(.plain)
        .overlay {
            if filtered.isEmpty {
                if store.isRefreshing { ProgressView("Agents are harvesting…") }
                else if query.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "tray") }
                else { ContentUnavailableView.search(text: query) }
            }
        }
        .refreshable { await store.refresh() }
    }
}

struct RefreshButton: View {
    @Environment(FrontierStore.self) private var store

    var body: some View {
        Button { Task { await store.refresh() } } label: {
            Label("Dispatch agents", systemImage: "arrow.clockwise")
                .symbolEffect(.rotate, isActive: store.isRefreshing)
        }
        .disabled(store.isRefreshing)
        .keyboardShortcut("r", modifiers: .command)
    }
}
