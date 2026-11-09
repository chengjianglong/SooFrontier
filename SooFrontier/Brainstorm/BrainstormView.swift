import SwiftUI

/// The Brainstorm tab: the whole agent panel discussing any topic with you, by text or voice.
struct BrainstormView: View {
    @Environment(FrontierStore.self) private var store
    @Environment(Reader.self) private var reader
    @State private var room = BrainstormRoom()
    @State private var draft = ""
    @FocusState private var typing: Bool
    @State private var showTranscript = false
    @State private var showKeyboard = false
    @State private var showProgress = false
    @State private var stopTaps = 0

    private let starters = [
        "What's the most important thing in today's frontier, and is it overhyped?",
        "What should an AI researcher build this week?",
        "Is scaling still the main driver of progress? Everyone weigh in.",
        "Debate: will small specialized models beat frontier models for most companies?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $room.mode) {
                ForEach(BrainstormRoom.Mode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.top, 8)
            panelStrip
            Divider()
            if room.mode == .video { meeting } else { transcript; composer }
        }
        .animation(.snappy, value: room.mode)
        .brandToolbar("Brainstorm")
        .toolbar {
            ToolbarItem {
                Menu {
                    Toggle("Read replies aloud", isOn: $room.speakReplies)
                    Toggle("Hands-free voice", isOn: $room.handsFree)
                    Toggle("Use today's frontier as context", isOn: $room.useFrontierContext)
                    Divider()
                    Button("Wrap up") { room.wrapUp() }.disabled(room.messages.isEmpty)
                    Button("New session", role: .destructive) { room.reset() }
                } label: { Label("Options", systemImage: "slider.horizontal.3") }
            }
        }
        .onAppear { room.attach(store) }
        .onDisappear { room.interrupt(); room.voice.stopListening() }
    }

    // MARK: Panel

    private var panelStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Panelist.all) { p in
                    let on = room.members.contains(p.id)
                    let busy = room.phase == .thinking(p.name) || room.phase == .speaking(p.name)
                    Button {
                        if on { room.members.remove(p.id) } else { room.members.insert(p.id) }
                    } label: {
                        HStack(spacing: 6) {
                            AgentBadge(kind: p.agent, status: busy ? .working("") : .idle, size: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.name).font(.caption.weight(.semibold))
                                Text(store.local.isConfigured ? LocalModels.shortName(store.local.model) : "Not set up").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 4).padding(.trailing, 10).padding(.vertical, 4)
                        .background(on ? AnyShapeStyle(p.agent.color.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.4)), in: Capsule())
                        .opacity(on ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(p.name), \(on ? "on the panel" : "off the panel")")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // MARK: Video meeting

    /// Talking faces in a meeting grid, with SooTalky's Talk captions and dock underneath.
    private var meeting: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                FaceStage(room: room)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.06, green: 0.07, blue: 0.11), in: RoundedRectangle(cornerRadius: 18))
                    .contentShape(Rectangle())
                    // Tapping a face while someone speaks jumps in, as in SooTalky.
                    .onTapGesture { if case .speaking = room.phase { room.micTapped() } }
                if showTranscript {
                    meetingTranscript.transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12).padding(.top, 10)
            .animation(.snappy, value: showTranscript)
            talkCaptions
            dock
        }
        .sheet(isPresented: $showProgress) { progressSheet }
    }

    /// "Name  what they're saying", centred, with your words underneath while you talk.
    private var talkCaptions: some View {
        ScrollView {
            VStack(spacing: 6) {
                if let m = room.captionMessage {
                    (Text(m.name + "  ").foregroundColor(Theme.accent).bold() + Text(m.isSummary ? "Wrap-up ready. Open the transcript to read it." : Reader.plain(m.text)))
                        .font(.title3.weight(.medium))
                }
                if room.phase == .listening, !room.liveCaption.isEmpty {
                    Text("“\(room.liveCaption)”").font(.callout).foregroundStyle(.secondary)
                } else if let e = room.error, room.phase == .idle {
                    Text(e).font(.callout).foregroundStyle(.red)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1)],
                             startPoint: .top, endPoint: .bottom))
        .frame(minHeight: 64, maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Transcript · Type · Mic · Stop · Progress, with a status line, as in SooTalky's Talk tab.
    private var dock: some View {
        VStack(spacing: 12) {
            if showKeyboard {
                HStack(spacing: 8) {
                    TextField("Type a message", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit(sendDraft)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill").font(.largeTitle).symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .top, spacing: 8) {
                DockButton(title: "Transcript", systemImage: "text.bubble", isOn: showTranscript) { showTranscript.toggle() }
                DockButton(title: "Type", systemImage: "keyboard", isOn: showKeyboard) {
                    showKeyboard.toggle()
                    typing = showKeyboard
                }
                micButton.frame(maxWidth: .infinity)
                DockButton(title: "Stop", systemImage: "stop.fill", isOn: false) {
                    stopTaps += 1
                    room.stopTapped()
                }
                .disabled(room.phase == .idle)
                DockButton(title: "Progress", systemImage: "chart.bar", isOn: false) { showProgress = true }
            }
            Text(statusText).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: room.phase)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
        .animation(.snappy, value: showKeyboard)
        .sensoryFeedback(.impact(weight: .medium), trigger: stopTaps)
    }

    private var micButton: some View {
        let listening = room.phase == .listening
        let busy: Bool = { switch room.phase { case .speaking, .thinking: true; default: false } }()
        let size: CGFloat = 76
        return Button {
            typing = false
            reader.stop()
            room.micTapped()
        } label: {
            ZStack {
                if listening {
                    Circle().stroke(Theme.accent.opacity(0.6), lineWidth: 2).frame(width: size + 12, height: size + 12)
                        .phaseAnimator([false, true]) { v, on in v.scaleEffect(on ? 1.18 : 0.96).opacity(on ? 0 : 0.8) } animation: { _ in .easeOut(duration: 1.4) }
                }
                Circle()
                    .fill(busy ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Theme.accent.gradient))
                    .frame(width: size, height: size)
                    .shadow(color: busy ? .clear : Theme.accent.opacity(0.35), radius: 8, y: 4)
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(busy ? Theme.accent : .white)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: listening)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(height: size + 12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Microphone")
        .accessibilityValue(listening ? "Listening" : busy ? "Tap to interrupt" : "Off")
        .sensoryFeedback(.impact, trigger: listening)
    }

    private var statusText: String {
        switch room.phase {
        case .idle: "Tap the mic to talk"
        case .listening: "I'm listening… take your time"
        case .thinking(let name): "\(name) is thinking…"
        case .speaking: "Tap a face or Stop to jump in"
        }
    }

    /// The discussion so far, slid up over the faces.
    private var meetingTranscript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(room.messages) { m in bubble(m) }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(8)
    }

    /// Who has spoken and how much: turns and words per panelist, and yours.
    private var progressSheet: some View {
        NavigationStack {
            List {
                let you = room.messages.filter { $0.speaker == "user" }
                Section("You") {
                    LabeledContent("Turns", value: "\(you.count)")
                    LabeledContent("Words", value: "\(you.reduce(0) { $0 + $1.text.split(separator: " ").count })")
                }
                Section("Panel") {
                    ForEach(Panelist.all) { p in
                        let said = room.messages.filter { $0.speaker == p.id }
                        HStack(spacing: 10) {
                            AgentBadge(kind: p.agent, status: .idle, size: 28)
                            Text(p.name)
                            Spacer()
                            Text("\(said.count) turns · \(said.reduce(0) { $0 + $1.text.split(separator: " ").count }) words")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Progress")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showProgress = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// The line being spoken (or the latest one), or what you're saying while the mic is open.
    @ViewBuilder private var caption: some View {
        if room.phase == .listening {
            Label(room.liveCaption.isEmpty ? "Listening…" : "“\(room.liveCaption)”", systemImage: "mic.fill")
                .font(.callout).foregroundStyle(Theme.accent)
        } else if case .thinking(let name) = room.phase {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(name) is thinking…") }
                .font(.callout).foregroundStyle(.secondary)
        } else if let last = room.messages.last {
            VStack(alignment: .leading, spacing: 4) {
                Text(last.speaker == "user" ? "You" : last.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(last.isSummary ? "Wrap-up ready: switch to Group chat to read it." : last.text)
                    .font(Theme.body).lineLimit(4)
            }
        } else if let e = room.error {
            Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
        } else {
            Text("Tap the mic and talk to the panel, or type a question.").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if room.messages.isEmpty { emptyState }
                    ForEach(room.messages) { m in bubble(m).id(m.id) }
                    statusRow.id("status")
                }
                .padding(16)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: room.messages.count) { withAnimation { proxy.scrollTo("status", anchor: .bottom) } }
            .onChange(of: room.phase) { withAnimation { proxy.scrollTo("status", anchor: .bottom) } }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Brainstorm").eyebrow(Theme.accent)
            Text("Put a question to the whole panel.").font(Theme.display(26))
            Text("Name an agent to ask them directly, say \"everyone\" for every view, or tap the mic and talk. Tap Wrap up for a summary.")
                .font(Theme.body).foregroundStyle(.secondary)
            ForEach(starters, id: \.self) { s in
                Button { room.send(s) } label: {
                    Label(s, systemImage: "sparkles").font(.callout).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private func bubble(_ m: BrainstormMessage) -> some View {
        if m.speaker == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(m.text)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }
        } else if let p = Panelist.all.first(where: { $0.id == m.speaker }) {
            HStack(alignment: .top, spacing: 10) {
                AgentBadge(kind: p.agent, status: .idle, size: 30)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(m.isSummary ? "\(p.name) · wrap-up" : p.name).font(.subheadline.weight(.semibold))
                        if let model = m.model { Text(model).font(.caption2).foregroundStyle(.tertiary) }
                    }
                    if m.isSummary { StructuredText(text: m.text) }
                    else { Text(markdown: m.text).font(Theme.body).lineSpacing(3).textSelection(.enabled) }
                }
                Spacer(minLength: 24)
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch room.phase {
        case .thinking(let name):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(name) is thinking…") }
                .font(.callout).foregroundStyle(.secondary)
        case .speaking(let name):
            Label("\(name) is speaking · tap the mic to interrupt", systemImage: "waveform").font(.callout).foregroundStyle(.secondary)
        case .listening:
            Label(room.liveCaption.isEmpty ? "Listening…" : "“\(room.liveCaption)”", systemImage: "mic.fill")
                .font(.callout).foregroundStyle(Theme.accent)
        case .idle:
            if let e = room.error { Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red) }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask the panel…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                .onSubmit(sendDraft)
            if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button {
                    typing = false
                    reader.stop()
                    room.micTapped()
                } label: {
                    Image(systemName: room.phase == .listening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(room.phase == .listening ? Color.red : Theme.accent)
                        .symbolEffect(.pulse, isActive: room.phase == .listening)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(room.phase == .listening ? "Stop listening" : "Talk to the panel")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        room.send(text)
    }
}

/// SooTalky's dock button: a round icon with a small label underneath.
private struct DockButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: 46, height: 46)
                    .background(isOn ? AnyShapeStyle(Theme.accent.opacity(0.18)) : AnyShapeStyle(.background.secondary), in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    .foregroundStyle(isOn ? Theme.accent : Color.primary)
                Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isOn)
    }
}
