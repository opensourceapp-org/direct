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
        private let haptic = UIImpactFeedbackGenerator(style: .soft)

        init() {
            clip = SendFeedback.swoosh()
            haptic.prepare()
        }

        func play() {
            haptic.impactOccurred(intensity: 0.35)
            haptic.prepare()
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback {
                try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                try? session.setActive(true)
            }
            player = try? AVAudioPlayer(data: clip)
            player?.volume = 0.45
            player?.prepareToPlay()
            player?.play()
        }
    }

    /// A soft rising whoosh. The level is a smooth hump, so the start has no crack.
    private static func swoosh() -> Data {
        let sampleRate = 44_100
        let duration = 0.32
        let count = Int(Double(sampleRate) * duration)
        var samples = [Int16](repeating: 0, count: count)
        var low = 0.0
        var low2 = 0.0
        var phase = 0.0
        var seed: UInt32 = 0xA3C59AC3
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let hump = sin(.pi * t / duration)
            let envelope = hump * hump
            let glide = t / duration
            let frequency = 380 + 720 * glide
            phase += 2 * .pi * frequency / Double(sampleRate)
            let tone = sin(phase) * 0.55 + sin(phase * 0.5) * 0.22
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let white = Double(Int32(bitPattern: seed)) / Double(Int32.max)
            let cutoff = 500 + 700 * glide
            let alpha = 1 / (1 + (Double(sampleRate) / (2 * .pi * cutoff)))
            low += alpha * (white - low)
            low2 += alpha * (low - low2)
            let mixed = max(-1, min(1, (tone + low2 * 0.35) * envelope))
            samples[index] = Int16(mixed * 12_000)
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
