import AVFoundation
import Combine
import StormRadioCore

/// The "radio": a priority queue of announcements that plays tones and speaks text,
/// lets urgent messages interrupt less important ones, and remembers the last thing it said.
@MainActor
final class SpeechCenter: NSObject, ObservableObject {
    @Published private(set) var current: Announcement?
    @Published private(set) var queue: [Announcement] = []
    @Published private(set) var lastSpoken: Announcement?
    @Published private(set) var history: [Announcement] = []

    var voice = VoiceSettings() { didSet { tones.customMaxSeconds = voice.customSoundMaxSeconds } }

    /// While reading a product with "tap a word to start", which text is being read and which word (offsets in that text).
    @Published private(set) var readingSourceID: String?
    @Published private(set) var readingHighlight: NSRange?

    private struct ReadingContext {
        var sourceID: String
        var baseOffset: Int
    }
    private var contexts: [String: ReadingContext] = [:]
    private var spokenLocation = 0
    var interrupts = InterruptSettings()
    var keepAlive = false { didSet { updateIdleAudio() } }

    private let synth = AVSpeechSynthesizer()
    private let tones = TonePlayer()
    private var currentUtterance: AVSpeechUtterance?
    private var gapTask: Task<Void, Never>?
    private var deactivateTask: Task<Void, Never>?
    private var sessionDucking = false

    override init() {
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
    }

    var isBusy: Bool { current != nil }

    // MARK: Queue

    /// Adds an announcement. Silent / off modes are ignored here (they only go to the feed).
    func enqueue(_ a: Announcement) {
        guard a.mode != .off, a.mode != .notifyOnly else { return }
        if let cur = current, shouldInterrupt(cur, with: a) {
            interruptCurrent(requeue: interrupts.resumeInterrupted)
        }
        insert(a)
        if current == nil { playNext() }
    }

    /// Plays something right now because the user asked for it (buttons, "speak" in the feed).
    func speakNow(_ a: Announcement) {
        var item = a
        if item.mode == .off || item.mode == .notifyOnly || item.mode == .tone { item.mode = .speak }
        if current != nil { interruptCurrent(requeue: true) }
        queue.insert(item, at: 0)
        playNext()
    }

    /// Reads `text` starting at a UTF-16 offset (from tapping a word), highlighting words as they're spoken.
    func read(text: String, from offset: Int, sourceID: String, title: String) {
        let ns = text as NSString
        let start = max(0, min(offset, ns.length))
        let spoken = Self.speakable(ns.substring(from: start))
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Tapping a new spot in the same text replaces that reading instead of queueing it.
        queue.removeAll { contexts[$0.id]?.sourceID == sourceID }
        if let cur = current, contexts[cur.id]?.sourceID == sourceID { interruptCurrent(requeue: false) }
        let a = Announcement(date: Date(), category: .system, title: title, spokenText: spoken, mode: .speak, priority: 5, notify: false)
        contexts[a.id] = ReadingContext(sourceID: sourceID, baseOffset: start)
        speakNow(a)
    }

    /// Makes product text read smoothly without changing its length (so highlights line up).
    static func speakable(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "...", with: ",  ")
            .replacingOccurrences(of: "&&", with: "  ")
            .replacingOccurrences(of: "$$", with: "  ")
    }

    func isReading(_ sourceID: String) -> Bool { readingSourceID == sourceID && current != nil }

    func repeatLast() {
        guard let last = lastSpoken else {
            speakNow(Announcement(date: Date(), category: .system, title: "Nothing to repeat", spokenText: "Nothing has been read yet.", notify: false))
            return
        }
        var again = last
        again.id = UUID().uuidString
        again.mode = .speak
        speakNow(again)
    }

    /// Stops talking and clears the queue.
    func stopAll() {
        for a in queue { contexts[a.id] = nil }
        queue.removeAll()
        interruptCurrent(requeue: false)
        scheduleDeactivate()
    }

    /// Stops the current message and moves to the next one.
    func skip() {
        interruptCurrent(requeue: false)
        playNext()
    }

    func preview(tone: ToneID) {
        activateSession(duck: false)
        tones.play(tone, volume: voice.toneVolume) { [weak self] in self?.scheduleDeactivate() }
    }

    private func insert(_ a: Announcement) {
        let i = queue.firstIndex(where: { $0.priority < a.priority }) ?? queue.endIndex
        queue.insert(a, at: i)
    }

    private func shouldInterrupt(_ cur: Announcement, with new: Announcement) -> Bool {
        guard interrupts.enabled, new.canInterrupt else { return false }
        return new.priority >= interrupts.minimumPriority && new.priority >= cur.priority + interrupts.minimumGap
    }

    private func interruptCurrent(requeue: Bool) {
        gapTask?.cancel()
        tones.stop()
        if var cur = current {
            let wasSpeaking = currentUtterance != nil
            current = nil
            currentUtterance = nil
            synth.stopSpeaking(at: .immediate)
            if requeue {
                // Long readings resume where they were cut off; short alerts start over.
                let ns = cur.spokenText as NSString
                if wasSpeaking, spokenLocation > 0, spokenLocation < ns.length, contexts[cur.id] != nil || ns.length > 400 {
                    cur.spokenText = ns.substring(from: spokenLocation)
                    cur.mode = .speak
                    contexts[cur.id]?.baseOffset += spokenLocation
                }
                queue.insert(cur, at: 0)
            } else {
                contexts[cur.id] = nil
            }
            clearReading()
        }
        spokenLocation = 0
    }

    private func clearReading() {
        readingSourceID = nil
        readingHighlight = nil
    }

    private func playNext() {
        guard current == nil else { return }
        guard !queue.isEmpty else { scheduleDeactivate(); return }
        let a = queue.removeFirst()
        current = a
        deactivateTask?.cancel()
        activateSession(duck: true)
        if a.mode.playsTone && a.tone != .none {
            let id = a.id
            tones.play(a.tone, volume: voice.toneVolume) { [weak self] in
                guard let self, self.current?.id == id else { return }
                if a.mode.speaks { self.speak(a) } else { self.finishCurrent(spoken: false) }
            }
        } else if a.mode.speaks || a.mode == .tone {
            if a.mode.speaks { speak(a) } else { finishCurrent(spoken: false) }
        } else {
            finishCurrent(spoken: false)
        }
    }

    private func speak(_ a: Announcement) {
        spokenLocation = 0
        if let ctx = contexts[a.id] { readingSourceID = ctx.sourceID } else { clearReading() }
        let u = AVSpeechUtterance(string: a.spokenText)
        u.rate = Float(max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, Float(voice.rate))))
        u.pitchMultiplier = Float(max(0.5, min(2.0, voice.pitch)))
        u.volume = Float(max(0, min(1, voice.volume)))
        if !voice.voiceIdentifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voice.voiceIdentifier) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        u.postUtteranceDelay = 0
        currentUtterance = u
        synth.speak(u)
    }

    fileprivate func utteranceFinished(_ u: AVSpeechUtterance) {
        guard u === currentUtterance else { return }
        finishCurrent(spoken: true)
    }

    fileprivate func willSpeak(_ range: NSRange, of u: AVSpeechUtterance) {
        guard u === currentUtterance, let cur = current else { return }
        spokenLocation = range.location
        if let ctx = contexts[cur.id] {
            readingHighlight = NSRange(location: ctx.baseOffset + range.location, length: range.length)
        }
    }

    private func finishCurrent(spoken: Bool) {
        if let cur = current { contexts[cur.id] = nil }
        clearReading()
        spokenLocation = 0
        if let cur = current {
            if spoken {
                lastSpoken = cur
                history.insert(cur, at: 0)
                if history.count > 50 { history.removeLast() }
            }
        }
        current = nil
        currentUtterance = nil
        gapTask?.cancel()
        let gap = voice.gapSeconds
        gapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, gap) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.playNext()
        }
    }

    // MARK: Audio session

    private func activateSession(duck: Bool) {
        let s = AVAudioSession.sharedInstance()
        var opts: AVAudioSession.CategoryOptions = []
        if duck {
            if voice.duckOtherAudio { opts.insert(.duckOthers) }
            if voice.interruptSpokenAudio { opts.insert(.interruptSpokenAudioAndMixWithOthers) }
            if opts.isEmpty { opts.insert(.mixWithOthers) }
        } else {
            opts.insert(.mixWithOthers)
        }
        if sessionDucking != duck || s.category != .playback || s.categoryOptions != opts {
            // Ducking only takes effect when the session (re)activates, and deactivating requires audio I/O to be stopped.
            tones.pauseEngine()
            try? s.setActive(false, options: .notifyOthersOnDeactivation)
            do {
                try s.setCategory(.playback, mode: .voicePrompt, options: opts)
            } catch {
                print("Audio session category error: \(error)")
            }
            sessionDucking = duck
        }
        do {
            try s.setActive(true)
        } catch {
            print("Audio session activation error: \(error)")
        }
        tones.restartIfNeeded()
    }

    /// After speaking, release the ducking so music comes back up (but keep silent audio alive if enabled).
    private func scheduleDeactivate() {
        deactivateTask?.cancel()
        deactivateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled, self.current == nil, self.queue.isEmpty else { return }
            self.updateIdleAudio()
        }
    }

    func updateIdleAudio() {
        guard current == nil else { return }
        let s = AVAudioSession.sharedInstance()
        tones.pauseEngine()
        try? s.setActive(false, options: .notifyOthersOnDeactivation)
        sessionDucking = false
        if keepAlive {
            try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? s.setActive(true)
            tones.startSilence()
        } else {
            tones.stopSilence()
        }
    }

    @objc private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo, let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            if type == .ended {
                self.tones.restartIfNeeded()
                if self.keepAlive { self.updateIdleAudio() }
                if self.current == nil { self.playNext() }
            }
        }
    }
}

extension SpeechCenter: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.utteranceFinished(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in self.willSpeak(characterRange, of: utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cancellation only happens through interruptCurrent/stopAll, which already moved on.
    }
}
