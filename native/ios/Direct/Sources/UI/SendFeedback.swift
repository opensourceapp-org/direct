import AVFoundation
import UIKit

/// A short original send swoosh. It is not Apple's Messages recording.
enum SendFeedback {
    private static let playback = Playback()

    static func play() {
        playback.play()
    }

    private final class Playback {
        private var player: AVAudioPlayer?
        private let clip: Data
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        init() {
            clip = SendFeedback.swoosh()
            haptic.prepare()
        }

        func play() {
            haptic.impactOccurred(intensity: 0.6)
            haptic.prepare()
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                try? session.setActive(true)
            }
            player = try? AVAudioPlayer(data: clip)
            player?.volume = 0.85
            player?.prepareToPlay()
            player?.play()
        }
    }

    /// Rising filtered noise, about a fifth of a second, with a soft fade so it does not click.
    private static func swoosh() -> Data {
        let sampleRate = 44_100
        let duration = 0.22
        let count = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: count)
        var low = 0.0
        var seed: UInt32 = 0xA3C59AC3
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let attack = min(1, t / 0.012)
            let release = exp(-max(0, t - 0.02) * 14)
            let fade = min(1, max(0, (duration - t) / 0.018))
            let envelope = attack * release * fade
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let cutoff = 320 + 2_600 * pow(t / duration, 0.65)
            let alpha = 1 / (1 + (Double(sampleRate) / (2 * Double.pi * cutoff)))
            low += alpha * (white - low)
            let air = (white - low) * 0.18
            let mixed = max(-1, min(1, (low * 1.35 + air) * envelope))
            samples[index] = Int16(mixed * 15_000)
        }
        return wav(samples, sampleRate: sampleRate)
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * MemoryLayout<Int16>.size
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(integer: UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(integer: UInt32(16))
        data.append(integer: UInt16(1))
        data.append(integer: UInt16(1))
        data.append(integer: UInt32(sampleRate))
        data.append(integer: UInt32(sampleRate * 2))
        data.append(integer: UInt16(2))
        data.append(integer: UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.append(integer: UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(integer: T) {
        var little = integer.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
