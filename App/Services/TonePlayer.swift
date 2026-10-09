import AVFoundation
import StormRadioCore

/// Plays the synthesized alert tones, and optional inaudible audio that keeps the app alive in the background.
@MainActor
final class TonePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silencePlayer = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [ToneID: AVAudioPCMBuffer] = [:]
    private var configured = false
    private(set) var silenceRunning = false
    private var playToken = 0

    private func configure() {
        guard !configured else { return }
        engine.attach(player)
        engine.attach(silencePlayer)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(silencePlayer, to: engine.mainMixerNode, format: format)
        configured = true
    }

    private func ensureRunning() -> Bool {
        configure()
        if engine.isRunning { return true }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            print("Tone engine failed to start: \(error)")
            return false
        }
    }

    private func buffer(for tone: ToneID) -> AVAudioPCMBuffer? {
        if let b = buffers[tone] { return b }
        let samples = ToneSynth.samples(tone)
        guard !samples.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        if let ch = b.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                ch.update(from: src.baseAddress!, count: samples.count)
            }
        }
        buffers[tone] = b
        return b
    }

    private var customPlayer: AVAudioPlayer?
    private var customDelegate: CustomSoundDelegate?
    private var customLimitTask: Task<Void, Never>?

    /// Longest a custom sound may play before it's cut off (seconds).
    var customMaxSeconds: Double = 10

    /// Plays a tone and calls `completion` on the main actor when it finishes (or immediately if it can't play).
    /// Custom sounds that aren't on this device fall back to the double beep.
    func play(_ tone: ToneID, volume: Double, completion: @escaping @MainActor () -> Void) {
        if tone.isCustom {
            if let url = SoundLibrary.fileURL(for: tone) {
                playCustom(url, volume: volume, completion: completion)
            } else {
                play(.doubleBeep, volume: volume, completion: completion)
            }
            return
        }
        guard tone != .none, let buf = buffer(for: tone), ensureRunning() else { completion(); return }
        playToken += 1
        let token = playToken
        player.stop()
        player.volume = Float(max(0, min(1, volume)))
        player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.playToken == token else { return }
                completion()
            }
        }
        player.play()
    }

    private func playCustom(_ url: URL, volume: Double, completion: @escaping @MainActor () -> Void) {
        stopCustom()
        playToken += 1
        let token = playToken
        guard let p = try? AVAudioPlayer(contentsOf: url) else { completion(); return }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.playToken == token else { return }
            self.stopCustom()
            completion()
        }
        let delegate = CustomSoundDelegate { Task { @MainActor in finish() } }
        p.delegate = delegate
        p.volume = Float(max(0, min(1, volume)))
        customDelegate = delegate
        customPlayer = p
        guard p.play() else { completion(); return }
        let limit = customMaxSeconds
        if p.duration > limit {
            customLimitTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard !Task.isCancelled, let self, self.playToken == token else { return }
                finish()
            }
        }
    }

    private func stopCustom() {
        customLimitTask?.cancel()
        customLimitTask = nil
        customPlayer?.stop()
        customPlayer = nil
        customDelegate = nil
    }

    /// Stops any tone; its completion is not called.
    func stop() {
        playToken += 1
        player.stop()
        stopCustom()
    }

    /// Stops audio I/O so the audio session can be deactivated (needed for other apps' audio to un-duck).
    func pauseEngine() {
        if configured && engine.isRunning { engine.pause() }
    }

    /// Loops silence so iOS keeps the app's audio (and therefore the app) running.
    func startSilence() {
        guard ensureRunning(), !silenceRunning else { return }
        let frames = AVAudioFrameCount(44_100)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        b.frameLength = frames // zero-filled
        silencePlayer.stop() // clears anything previously scheduled
        silencePlayer.volume = 0
        silencePlayer.scheduleBuffer(b, at: nil, options: .loops, completionHandler: nil)
        silencePlayer.play()
        silenceRunning = true
    }

    func stopSilence() {
        guard silenceRunning else { return }
        silencePlayer.stop()
        silenceRunning = false
    }

    /// Call after an audio interruption ends (phone call, Siri...).
    func restartIfNeeded() {
        guard configured else { return }
        if !engine.isRunning { _ = ensureRunning() }
        if silenceRunning && !silencePlayer.isPlaying {
            silenceRunning = false
            startSilence()
        }
    }
}

/// Bridges AVAudioPlayer's delegate callback to a closure.
final class CustomSoundDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish() }
}
