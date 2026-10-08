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

    /// Plays a tone and calls `completion` on the main actor when it finishes (or immediately if it can't play).
    func play(_ tone: ToneID, volume: Double, completion: @escaping @MainActor () -> Void) {
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

    /// Stops any tone; its completion is not called.
    func stop() {
        playToken += 1
        player.stop()
    }

    /// Loops silence so iOS keeps the app's audio (and therefore the app) running.
    func startSilence() {
        guard !silenceRunning, ensureRunning() else { return }
        let frames = AVAudioFrameCount(44_100)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        b.frameLength = frames // zero-filled
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
        if silenceRunning {
            silenceRunning = false
            startSilence()
        }
    }
}
