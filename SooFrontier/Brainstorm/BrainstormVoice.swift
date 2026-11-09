import AVFoundation
import Speech

/// Voice for the Brainstorm room, adapted from SooTalky's Listener and Speaker:
/// on-device speech recognition that sends after a pause, and a distinct spoken voice per panelist.
@MainActor
final class BrainstormVoice: NSObject {
    var onHeard: ((String) -> Void)?
    var onCommit: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onFinishedSpeaking: (() -> Void)?

    private let engine = AVAudioEngine()
    private let synth = AVSpeechSynthesizer()
    private let sink = BufferSink()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var text = ""
    private var base = ""
    private var tapInstalled = false
    private(set) var isListening = false
    private var pending = 0
    /// Each panelist's voice and its pitch and pace, chosen once to fit their portrait.
    private var cast: [String: (voice: AVSpeechSynthesisVoice?, pitch: Float, rate: Float)] = [:]
    /// Which panelist each queued utterance belongs to.
    private var owners: [ObjectIdentifier: String] = [:]
    /// The panelist whose voice is playing now (drives the video-meeting faces).
    private(set) var speakingPanelist: String?
    private var word = ""
    private var wordStarted = Date()
    private var mouthNow = Mouth()

    struct Mouth { var open = 0.0, wide = 0.0, round = 0.0, energy = 0.0 }

    /// Seconds of silence before what you said is sent.
    var pause: TimeInterval = 1.8

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { pending > 0 }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        #if os(iOS)
        let mic = await AVAudioApplication.requestRecordPermission()
        #else
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        return speech && mic
    }

    // MARK: Listening

    @discardableResult
    func startListening(locale: Locale = Locale(identifier: "en-US")) -> Bool {
        guard !isListening else { return true }
        stopSpeaking()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onError?("Speech recognition isn't available right now.")
            return false
        }
        self.recognizer = recognizer
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP, .duckOthers])
        try? session.setActive(true)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onError?("No microphone is available right now.")
            return false
        }
        input.removeTap(onBus: 0)
        let sink = sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        tapInstalled = true
        do { try engine.start() } catch {
            onError?("Couldn't start the microphone: \(error.localizedDescription)")
            stopListening()
            return false
        }
        isListening = true
        text = ""
        spawn()
        return true
    }

    private func spawn() {
        guard isListening, let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        // On-device when supported, so voice works offline and audio stays on the device.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request
        sink.set(request)
        base = text
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.isListening else { return }
                if let heard, !heard.isEmpty {
                    self.text = "\(self.base) \(heard)".trimmingCharacters(in: .whitespaces)
                    self.onHeard?(self.text)
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = Timer.scheduledTimer(withTimeInterval: self.pause, repeats: false) { _ in
                        Task { @MainActor in self.commit() }
                    }
                }
                // Recognition tasks end after silence or about a minute; keep listening.
                if final || error != nil { self.request?.endAudio(); self.spawn() }
            }
        }
    }

    private func commit() {
        let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        stopListening()
        onCommit?(heard)
    }

    func stopListening() {
        isListening = false
        silenceTimer?.invalidate()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        sink.set(nil)
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    // MARK: Speaking

    func speak(_ text: String, as panelist: String) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let u = AVSpeechUtterance(string: text)
        let c = castMember(panelist)
        u.voice = c.voice
        u.pitchMultiplier = c.pitch
        u.rate = AVSpeechUtteranceDefaultSpeechRate * c.rate
        u.postUtteranceDelay = 0.25
        pending += 1
        owners[ObjectIdentifier(u)] = panelist
        synth.speak(u)
    }

    func stopSpeaking() {
        pending = 0
        owners.removeAll()
        speakingPanelist = nil
        word = ""
        synth.stopSpeaking(at: .immediate)
    }

    /// Mouth shape for the current moment, eased like SooTalky's Speaker: vowels open the mouth,
    /// o/u round it, e/i widen it, and m/b/p close it, stepping through the word being spoken.
    func mouth(dt: Double) -> Mouth {
        var target = Mouth()
        if speakingPanelist != nil, !word.isEmpty {
            let letters = Array(word.lowercased().filter(\.isLetter))
            if !letters.isEmpty {
                let i = Int(Date().timeIntervalSince(wordStarted) * 13) % letters.count
                switch letters[i] {
                case "a": target = Mouth(open: 0.85, wide: 0.45, round: 0.1, energy: 0.9)
                case "o", "u", "w": target = Mouth(open: 0.6, wide: 0.1, round: 0.85, energy: 0.8)
                case "e", "i", "y": target = Mouth(open: 0.45, wide: 0.85, round: 0, energy: 0.7)
                case "m", "b", "p": target = Mouth(open: 0, wide: 0.2, round: 0, energy: 0.4)
                case "f", "v": target = Mouth(open: 0.15, wide: 0.4, round: 0, energy: 0.5)
                default: target = Mouth(open: 0.3, wide: 0.35, round: 0.15, energy: 0.6)
                }
            }
        }
        func ease(_ cur: Double, _ to: Double, _ up: Double, _ down: Double) -> Double {
            cur + (to - cur) * min(1, dt * (to > cur ? up : down))
        }
        mouthNow.open = ease(mouthNow.open, target.open, 30, 16)
        mouthNow.wide = ease(mouthNow.wide, target.wide, 14, 8)
        mouthNow.round = ease(mouthNow.round, target.round, 14, 8)
        mouthNow.energy = ease(mouthNow.energy, target.energy, 20, 6)
        return mouthNow
    }

    /// Novelty, robotic and child voices never suit a meeting.
    private static let unsuited: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos", "Eddy", "Flo", "Fred", "Good News",
        "Grandma", "Grandpa", "Jester", "Junior", "Kathy", "Organ", "Princess", "Ralph", "Reed", "Rocko", "Sandy",
        "Shelley", "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox",
    ]

    private func castMember(_ panelist: String) -> (voice: AVSpeechSynthesisVoice?, pitch: Float, rate: Float) {
        if cast.isEmpty { castPanel() }
        return cast[panelist] ?? (AVSpeechSynthesisVoice(language: "en-US"), 1, 1.05)
    }

    /// Gives each panelist a distinct English voice of their portrait's gender, best quality first.
    /// When there are more panelists than voices of a gender, voices repeat and pitch and pace keep them apart;
    /// when there are none, another voice is pitched towards the right register.
    private func castPanel() {
        var seen = Set<String>()
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { v in !Self.unsuited.contains { v.name.hasPrefix($0) } && !v.identifier.contains("eloquence") }
            .sorted { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0, $0.identifier) > ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0, $1.identifier) }
            .filter { seen.insert($0.name).inserted }
        let female = english.filter { $0.gender == .female }
        let male = english.filter { $0.gender == .male }
        var used: [Panelist.VoiceProfile.Gender: Int] = [:]
        for p in Panelist.all {
            let profile = p.voice
            let pool = profile.gender == .female ? female : male
            if !pool.isEmpty {
                let i = used[profile.gender, default: 0]
                used[profile.gender] = i + 1
                cast[p.id] = (pool[i % pool.count], profile.pitch, profile.rate)
            } else {
                let other = english.first ?? AVSpeechSynthesisVoice(language: "en-US")
                cast[p.id] = (other, profile.gender == .male ? profile.pitch * 0.8 : profile.pitch * 1.2, profile.rate)
            }
        }
    }
}

extension BrainstormVoice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.speakingPanelist = self.owners[id] }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        let w = (utterance.speechString as NSString).substring(with: range)
        Task { @MainActor in self.word = w; self.wordStarted = Date() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.owners[id] = nil
            self.word = ""
            self.speakingPanelist = nil
            self.pending = max(0, self.pending - 1)
            if self.pending == 0 { self.onFinishedSpeaking?() }
        }
    }
}

/// Hands microphone buffers from the audio thread to the current recognition request.
private final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { request = r } }
    func append(_ b: AVAudioPCMBuffer) { lock.withLock { request }?.append(b) }
}
