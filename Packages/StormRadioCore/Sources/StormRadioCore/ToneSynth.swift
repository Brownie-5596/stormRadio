import Foundation

/// Generates the built-in alert tones as mono PCM samples (-1...1).
public enum ToneSynth {
    public static func samples(_ id: ToneID, sampleRate: Double = 44_100) -> [Float] {
        var out: [Float] = []
        func silence(_ sec: Double) { out += [Float](repeating: 0, count: Int(sec * sampleRate)) }
        func tone(_ freqs: [Double], _ sec: Double, amp: Double = 0.5, decay: Double = 0) {
            let n = Int(sec * sampleRate)
            let edge = min(Int(0.006 * sampleRate), n / 2)
            for i in 0..<n {
                let t = Double(i) / sampleRate
                var v = 0.0
                for f in freqs { v += sin(2 * .pi * f * t) }
                v /= Double(max(freqs.count, 1))
                var env = 1.0
                if i < edge { env = Double(i) / Double(edge) }
                if i > n - edge { env = Double(n - i) / Double(edge) }
                if decay > 0 { env *= exp(-decay * t) }
                out.append(Float(v * amp * env))
            }
        }
        func sweep(_ f0: Double, _ f1: Double, _ sec: Double, amp: Double = 0.45) {
            let n = Int(sec * sampleRate)
            var phase = 0.0
            let edge = Int(0.01 * sampleRate)
            for i in 0..<n {
                let f = f0 + (f1 - f0) * Double(i) / Double(n)
                phase += 2 * .pi * f / sampleRate
                var env = 1.0
                if i < edge { env = Double(i) / Double(edge) }
                if i > n - edge { env = Double(n - i) / Double(edge) }
                out.append(Float(sin(phase) * amp * env))
            }
        }

        switch id {
        case .none:
            break
        case .eas:
            tone([853, 960], 1.6, amp: 0.55)
        case .nwr1050:
            tone([1050], 1.5, amp: 0.5)
        case .siren:
            sweep(600, 1250, 0.7); sweep(1250, 600, 0.7)
        case .alarm:
            for _ in 0..<4 { tone([960], 0.14); tone([770], 0.14) }
        case .tripleBeep:
            for _ in 0..<3 { tone([1000], 0.12); silence(0.08) }
        case .doubleBeep:
            for _ in 0..<2 { tone([880], 0.16); silence(0.1) }
        case .chimeUp:
            for f in [1046.5, 1318.5, 1568.0] { tone([f, f * 2], 0.22, amp: 0.45, decay: 6) }
        case .chimeDown:
            for f in [1568.0, 1318.5, 1046.5] { tone([f, f * 2], 0.22, amp: 0.45, decay: 6) }
        case .ping:
            tone([1568, 3136], 0.45, amp: 0.45, decay: 7)
        case .blip:
            tone([660], 0.12, amp: 0.35)
        }
        if !out.isEmpty { silence(0.15) }
        return out
    }
}
