import AVFoundation
import MediaPlayer
import SwiftUI

/// Reads stories and briefs aloud, and can carry on to the next story when one finishes.
@MainActor @Observable
final class Reader: NSObject {
    enum Speed: Float, CaseIterable, Identifiable {
        case slow = 0.85, normal = 1, brisk = 1.2, fast = 1.4
        var id: Float { rawValue }
        var label: String { rawValue == 1 ? "1×" : "\(rawValue.formatted())×" }
    }

    private(set) var title: String?
    private(set) var isPaused = false
    var isActive: Bool { title != nil }

    var autoAdvance: Bool { didSet { UserDefaults.standard.set(autoAdvance, forKey: "reader.autoAdvance") } }
    var speed: Speed { didSet { UserDefaults.standard.set(speed.rawValue, forKey: "reader.speed") } }

    /// The story being read from a playlist; story pages follow it when they're on screen.
    private(set) var currentItemID: String?

    /// Playlist state lives here, not in the UI, so reading continues offline, locked, or in the background.
    @ObservationIgnored private var playlist: [FrontierItem] = []
    @ObservationIgnored private var index = 0
    @ObservationIgnored private var scriptFor: ((FrontierItem) -> [String])?

    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var last: AVSpeechUtterance?
    @ObservationIgnored private var onFinish: (() -> Void)?
    @ObservationIgnored private let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return english.first { $0.quality == .premium } ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    override init() {
        let d = UserDefaults.standard
        autoAdvance = d.object(forKey: "reader.autoAdvance") as? Bool ?? true
        speed = Speed(rawValue: d.float(forKey: "reader.speed")) ?? .normal
        super.init()
        synth.delegate = self
        setUpRemoteCommands()
    }

    /// Reads `items` from `start`, continuing through the list when auto-advance is on.
    /// `script` builds each story's spoken text from data already on the device.
    func play(_ items: [FrontierItem], from start: Int, script: @escaping (FrontierItem) -> [String]) {
        guard items.indices.contains(start) else { return }
        playlist = items
        index = start
        scriptFor = script
        speakCurrent()
    }

    /// Jumps the playlist to another story (when the reader taps Previous / Next while listening).
    func jump(to id: String) {
        guard let i = playlist.firstIndex(where: { $0.id == id }), i != index else { return }
        index = i
        speakCurrent()
    }

    private func speakCurrent() {
        guard playlist.indices.contains(index), let makeScript = scriptFor else { stop(); return }
        let item = playlist[index]
        let keepList = playlist, keepIndex = index, keepScript = makeScript
        read(title: item.title, parts: [item.title] + makeScript(item)) { [weak self] in
            guard let self, self.autoAdvance, keepIndex + 1 < keepList.count else { return }
            self.playlist = keepList
            self.index = keepIndex + 1
            self.scriptFor = keepScript
            self.speakCurrent()
        }
        playlist = keepList; index = keepIndex; scriptFor = keepScript
        currentItemID = item.id
        updateNowPlaying()
    }

    /// Reads the parts in order; `onFinish` runs only if reading reached the end (not when stopped).
    func read(title: String, parts: [String], onFinish: (() -> Void)? = nil) {
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        self.title = title
        self.onFinish = onFinish
        isPaused = false
        updateNowPlaying()
        for part in parts.map(Self.plain) where !part.isEmpty {
            let u = AVSpeechUtterance(string: part)
            u.voice = voice
            u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * speed.rawValue)
            u.postUtteranceDelay = 0.35
            synth.speak(u)
            last = u
        }
    }

    func togglePause() {
        if isPaused { synth.continueSpeaking() } else { synth.pauseSpeaking(at: .word) }
        isPaused.toggle()
        updateNowPlaying()
    }

    func stop() {
        onFinish = nil
        last = nil
        playlist = []; scriptFor = nil; currentItemID = nil
        synth.stopSpeaking(at: .immediate)
        title = nil
        isPaused = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Ends the current reading as if it had finished, so auto-advance moves on.
    func skip() {
        let next = onFinish
        onFinish = nil
        last = nil
        synth.stopSpeaking(at: .immediate)
        title = nil
        next?()
    }

    private func finished(_ u: AVSpeechUtterance) {
        guard u === last else { return }
        let next = onFinish
        onFinish = nil
        last = nil
        title = nil
        next?()
    }

    // MARK: Lock screen and Control Center

    private func updateNowPlaying() {
        guard let title else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: "SooFrontier",
                                   MPNowPlayingInfoPropertyPlaybackRate: isPaused ? 0.0 : 1.0]
        if !playlist.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = "Story \(index + 1) of \(playlist.count)"
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPaused == true { self?.togglePause() } }; return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in if self?.isPaused == false { self?.togglePause() } }; return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePause() }; return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip() }; return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.index > 0, !self.playlist.isEmpty else { return }
                self.index -= 1; self.speakCurrent()
            }
            return .success
        }
    }

    /// Strips Markdown so the voice doesn't read symbols.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`", "#", "*", "_"] { t = t.replacingOccurrences(of: mark, with: "") }
        return t.replacingOccurrences(of: "TL;DR", with: "T L D R").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spoken script for anything in the house structure.
    static func script(tldr: String, takeaways: [String], math: [String] = [], opportunities: [String]) -> [String] {
        var parts = ["TL;DR.", tldr]
        if !takeaways.isEmpty { parts.append("Takeaways."); parts += takeaways }
        // Read the prose of the math section; equations are better seen than heard.
        let mathProse = math.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("`") }
        if !mathProse.isEmpty { parts.append("Mathematical analysis."); parts += mathProse }
        if !opportunities.isEmpty { parts.append("Potential opportunities."); parts += opportunities }
        return parts
    }
}

extension Reader: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let last = self.last, ObjectIdentifier(last) == id { self.finished(last) }
        }
    }
}

/// Floating player shown while something is being read aloud.
struct ReaderBar: View {
    @Environment(Reader.self) private var reader

    var body: some View {
        @Bindable var reader = reader
        if reader.isActive {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: !reader.isPaused)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(reader.isPaused ? "Paused" : (reader.autoAdvance ? "Reading · continues to next" : "Reading aloud"))
                        .eyebrow()
                    Text(reader.title ?? "").font(.system(.subheadline, design: Theme.design, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Menu {
                    Picker("Speed", selection: $reader.speed) {
                        ForEach(Reader.Speed.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Continue to next story", isOn: $reader.autoAdvance)
                } label: {
                    Text(reader.speed.label).font(.caption.monospacedDigit().weight(.semibold))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button { reader.togglePause() } label: {
                    Image(systemName: reader.isPaused ? "play.fill" : "pause.fill")
                }
                Button { reader.skip() } label: { Image(systemName: "forward.end.fill") }
                    .help("Skip to the next story")
                Button { reader.stop() } label: { Image(systemName: "xmark") }
                    .help("Stop reading")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Spoken scripts built only from what's already on the device, so reading works with no network or Mac bridge.
enum ReadAloud {
    @MainActor static func script(for item: FrontierItem, store: FrontierStore) -> [String] {
        let quick = store.quickReads[item.id]
        var sentences: [String] = []
        item.summary.enumerateSubstrings(in: item.summary.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s { sentences.append(s.trimmingCharacters(in: .whitespaces)) }
            if sentences.count == 3 { stop = true }
        }
        let tldr = sentences.isEmpty ? item.title : sentences.joined(separator: " ")
        var takeaways = quick?.takeaways ?? []
        if takeaways.isEmpty { takeaways = KeyPoints.extract(summary: item.summary, fullText: nil, exclude: tldr) }
        if takeaways.isEmpty { takeaways = item.assessment?.flags ?? [] }
        let opportunities = quick?.opportunities ?? []
        return Reader.script(tldr: tldr, takeaways: takeaways, opportunities: opportunities)
    }
}
