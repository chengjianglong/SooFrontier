import SwiftUI

struct AgentsView: View {
    @Environment(FrontierStore.self) private var store

    var body: some View {
        List {
            Section {
                Text("Six harvesters fan out in parallel. The Skeptic cross-examines everything they bring back, and the Synthesizer turns the best of it into your brief.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Harvesters") { ForEach(AgentKind.harvesters) { row($0) } }
            Section("Thinkers") {
                row(.skeptic, model: store.roleClient(store.skepticProvider)?.label)
                row(.synthesizer, model: store.roleClient(store.synthesizerProvider)?.label)
            }
            Section("Frontier Council") {
                ForEach(Provider.allCases) { p in
                    HStack {
                        Image(systemName: p.symbol).foregroundStyle(p.color).frame(width: 28)
                        VStack(alignment: .leading) {
                            Text("\(p.councilSeat.title) · \(p.family)").font(.body.weight(.medium))
                            Text(p.councilSeat.brief).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(store.client(p) == nil ? "Not set up" : "Seated")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(store.client(p) == nil ? Color.secondary : Color.green)
                    }
                }
            }
        }
        .navigationTitle("Agent crew")
        .inlineTitle()
        .toolbar { ToolbarItem { RefreshButton() } }
    }

    private func row(_ a: AgentKind, model: String? = nil) -> some View {
        HStack(spacing: 12) {
            AgentBadge(kind: a, status: store.status[a] ?? .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).font(.body.weight(.semibold))
                Text(a.role).font(.caption).foregroundStyle(.secondary)
                if let model { Text(model).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                Text((store.status[a] ?? .idle).label).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { store.enabledAgents.contains(a) }, set: { _ in store.toggle(a) }))
                .labelsHidden()
        }
    }
}

struct SettingsView: View {
    @Environment(FrontierStore.self) private var store

    var body: some View {
        Form {
            Section {
                Text("Claude, GPT, and Grok run on your Claude Pro/Max, ChatGPT, and SuperGrok plans through the official `claude`, `codex`, and `grok` tools on your Mac, so they don't add API charges. On iPhone and iPad, those requests go through your Mac. You can switch any provider to a metered API key instead.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Agents") {
                NavigationLink { AgentsView() } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: -8) {
                            ForEach(AgentKind.allCases.prefix(4)) { a in
                                AgentBadge(kind: a, status: store.status[a] ?? .idle, size: 26)
                                    .background(Circle().fill(.background))
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Agent crew")
                            Text("\(store.enabledAgents.count) of \(AgentKind.allCases.count) on duty · Council seats")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink { VoicesView() } label: {
                    LabeledContent {
                        Text("\(store.voices.count)").monospacedDigit()
                    } label: {
                        Label("Voices on X", systemImage: "person.wave.2")
                    }
                }
            }
            AppearanceSection()
            BridgeSection()
            GemmaSection()
            ForEach(Provider.allCases) { p in ProviderSection(provider: p) }
            Section("Roles") {
                Picker("Synthesizer & moderator", selection: Binding(get: { store.synthesizerProvider },
                                                                     set: { store.setRoles(synth: $0, skeptic: store.skepticProvider) })) {
                    ForEach(Provider.allCases) { Text($0.family).tag($0) }
                }
                Picker("Story analysis (Analyze)", selection: Binding(get: { store.skepticProvider },
                                                                   set: { store.setRoles(synth: store.synthesizerProvider, skeptic: $0) })) {
                    ForEach(Provider.allCases) { Text($0.family).tag($0) }
                }
                Text("If the chosen provider isn't set up, the first available one stands in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .navigationTitle("Settings")
        .brandToolbar("Settings")
    }
}

/// Mac: share subscriptions. iPhone/iPad: pick the Mac and enter its code.
private struct BridgeSection: View {
    @Environment(FrontierStore.self) private var store
    #if !os(macOS)
    @State private var browser = BridgeBrowser()
    @State private var code = ""
    @FocusState private var codeFocused: Bool
    #endif

    var body: some View {
        #if os(macOS)
        Section {
            Toggle("Share my subscriptions with iPhone & iPad", isOn: Binding(get: { store.bridgeEnabled },
                                                                             set: { store.setBridgeEnabled($0) }))
            if store.bridgeEnabled {
                LabeledContent("Pairing code") {
                    Text(store.bridgeCode).font(.title3.monospacedDigit().weight(.semibold)).textSelection(.enabled)
                }
            }
        } header: {
            Label("Mac bridge", systemImage: "laptopcomputer.and.iphone")
        } footer: {
            Text("While SooFrontier is open on this Mac, your iPhone and iPad on the same network can use its Claude and ChatGPT plans. Enter this code on each device.")
        }
        #else
        Section {
            if browser.macs.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Looking for your Mac…").foregroundStyle(.secondary) }
            }
            ForEach(browser.macs, id: \.self) { mac in
                Button {
                    store.setBridge(service: mac, code: code)
                } label: {
                    HStack {
                        Label(mac, systemImage: "laptopcomputer")
                        Spacer()
                        if mac == store.bridgeService { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
            TextField("Pairing code from your Mac", text: $code)
                .keyboardType(.numberPad)
                .focused($codeFocused)
                .onChange(of: code) { store.setBridge(service: store.bridgeService, code: code) }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { codeFocused = false }.fontWeight(.semibold)
                    }
                }
        } header: {
            Label("Use my Mac's subscriptions", systemImage: "laptopcomputer.and.iphone")
        } footer: {
            Text("On your Mac, open SooFrontier → Settings → Mac bridge and turn on sharing. Keep it open on the same Wi-Fi.")
        }
        .onAppear { code = store.bridgeCode; browser.start() }
        .onDisappear { browser.stop() }
        #endif
    }
}

private struct ProviderSection: View {
    @Environment(FrontierStore.self) private var store
    var provider: Provider
    @State private var key = ""
    @State private var model = ""
    @State private var cliModel = ""
    @State private var testing = false
    @State private var testResult: String?
    #if os(macOS)
    @State private var cliPath: String?
    #endif

    private var mode: AccessMode { store.modes[provider] ?? .apiKey }

    var body: some View {
        Section {
            if provider.supportsSubscription {
                Picker("Access", selection: Binding(get: { mode }, set: { store.setMode($0, for: provider); testResult = nil })) {
                    ForEach(AccessMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if mode == .subscription {
                #if os(macOS)
                LabeledContent("\(provider.cliName) CLI") {
                    Text(cliPath ?? "Not found").font(.caption.monospaced())
                        .foregroundStyle(cliPath == nil ? .red : .secondary).lineLimit(1).truncationMode(.middle)
                }
                #endif
                Picker("Model", selection: Binding(get: { cliModel }, set: { cliModel = $0; store.setCLIModel($0, for: provider) })) {
                    ForEach(provider.cliModels, id: \.self) { m in Text(m.isEmpty ? "CLI default" : m).tag(m) }
                }
            } else {
                SecureField("API key", text: $key)
                    .onSubmit { store.setKey(key, for: provider) }
                    .onChange(of: key) { store.setKey(key, for: provider) }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                HStack {
                    TextField("Model", text: $model)
                        .autocorrectionDisabled()
                        .onChange(of: model) { if !model.isEmpty { store.setModel(model, for: provider) } }
                    Menu {
                        ForEach(provider.suggestedModels, id: \.self) { m in Button(m) { model = m } }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            HStack {
                Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                    .disabled(store.client(provider) == nil || testing)
                if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
        } header: {
            Label("\(provider.name) · \(provider.family)", systemImage: provider.symbol)
        } footer: {
            if mode == .subscription {
                #if os(macOS)
                Text("Uses your \(provider.planName) plan via `\(provider.cliName)`. Sign in once in Terminal with `\(provider.loginCommand)`. Plan usage limits apply, with no per-token charges.")
                #else
                Text("Runs on your Mac's \(provider.planName) plan via the Mac bridge above.")
                #endif
            } else {
                Text("Metered API billing. Get a key at \(provider.keyHelp)")
            }
        }
        .onAppear {
            key = store.keys[provider] ?? ""
            model = store.models[provider] ?? provider.defaultModel
            cliModel = store.cliModels[provider] ?? provider.defaultCLIModel
            #if os(macOS)
            if provider.supportsSubscription { cliPath = CLIRunner.executable(provider.cliName) }
            #endif
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        guard let c = store.client(provider) else { return }
        do {
            let r = try await c.complete(system: "Reply with exactly: ready", prompt: "Status check.", maxTokens: 300)
            testResult = "✓ \(r.prefix(40))"
        } catch { testResult = "✗ \(error.localizedDescription)" }
    }
}

/// The people whose X posts the Listener summarizes for the Opinions desk.
struct VoicesView: View {
    @Environment(FrontierStore.self) private var store
    @State private var input = ""
    @State private var role: Voice.Role = .researcher

    var body: some View {
        Form {
            Section {
                Text("The Listener asks Grok, on your SuperGrok plan, what these people said about AI this week. X doesn't show anyone's follow list to signed-out tools, so SooFrontier can't read @aiclong's follows automatically. Paste the handles you follow below. Copying them from x.com/aiclong/following works.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Add voices") {
                TextField("@handle, x.com/handle, or a pasted list", text: $input, axis: .vertical)
                    .lineLimit(1...6)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Role", selection: $role) {
                    ForEach(Voice.Role.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Add") {
                    store.addVoices(input, role: role)
                    input = ""
                }
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(Voice.Role.allCases, id: \.self) { r in
                let people = store.voices.filter { $0.role == r }
                if !people.isEmpty {
                    Section("\(r.title)s · \(people.count)") {
                        ForEach(people) { v in
                            HStack {
                                Text("@\(v.handle)")
                                Spacer()
                                Link(destination: URL(string: "https://x.com/\(v.handle)")!) {
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete { store.removeVoices(at: $0, in: r) }
                    }
                }
            }
            Section {
                Button("Reset to the starter list", role: .destructive) { store.resetVoices() }
            } footer: {
                Text("Grok reads these in batches of seven, so a long list takes longer and uses more of your plan.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Voices on X")
        .inlineTitle()
    }
}

/// Download or remove on-device Gemma, the offline fallback writer.
private struct GemmaSection: View {
    @Environment(FrontierStore.self) private var store
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let model = store.gemma
        Section {
            switch model.state {
            case .notDownloaded:
                Button { model.download() } label: { Label("Download Gemma 4 (2.6 GB)", systemImage: "arrow.down.circle") }
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p) { Text("Downloading Gemma 4… \(Int(p * 100))%") }
                    Button("Cancel", role: .cancel) { model.cancel() }.buttonStyle(.borderless)
                }
            case .ready:
                LabeledContent("Gemma 4 E2B") {
                    Label("On this device", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button(testing ? "Testing…" : "Test offline model") { Task { await test() } }.disabled(testing)
                if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary) }
                Button("Remove model", role: .destructive) { model.delete() }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Try again") { model.download() }
            }
        } header: {
            Label("Offline · on-device Gemma", systemImage: "cpu")
        } footer: {
            Text("When you're offline or your Mac bridge can't be reached, Gemma 4 runs on this device to write briefs, analyses, and quick reads. Answers are shorter and less detailed than Claude, GPT, or Grok, and they're marked \"Gemma 4 · on device\". Download over Wi-Fi; it needs about 3.5 GB free.")
        }
        .onAppear { model.refresh() }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let t0 = Date()
        do {
            let r = try await OnDeviceGemma.shared.complete(system: "Reply with exactly one word: ready", prompt: "Status check.")
            testResult = "✓ \(r.prefix(30)) (\(Int(Date().timeIntervalSince(t0)))s)"
        } catch { testResult = "✗ \(error.localizedDescription)" }
    }
}
