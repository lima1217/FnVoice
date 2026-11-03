import Foundation

/// Converts raw audio samples to a 0...1 loudness value.
public enum LevelMeter {
    /// Below this is treated as silence (room noise on a laptop mic sits around -55…-45 dBFS).
    public static let noiseFloorDB: Float = -50
    /// At or above this the waveform is at full height (normal close-mic speech peaks here).
    public static let ceilingDB: Float = -12

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func dBFS(rms: Float) -> Float {
        20 * log10(max(rms, 1e-7))
    }

    public static func normalized(dBFS db: Float, floor: Float = noiseFloorDB, ceiling: Float = ceilingDB) -> Float {
        guard ceiling > floor else { return 0 }
        return min(max((db - floor) / (ceiling - floor), 0), 1)
    }

    public static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        normalized(dBFS: dBFS(rms: rms(samples)))
    }
}

/// Smooths the loudness into a per-frame envelope and spreads it across five bars.
public struct WaveformEnvelope: Sendable {
    public static let weights: [Float] = [0.5, 0.8, 1.0, 0.75, 0.55]

    /// Fraction of the gap closed per frame when getting louder / quieter.
    public var attack: Float = 0.40
    public var release: Float = 0.15
    /// Per-bar random jitter, as a fraction of the bar height.
    public var jitter: Float = 0.04

    public private(set) var level: Float = 0

    public init() {}

    public mutating func step(target: Float) {
        let t = min(max(target, 0), 1)
        let k = t > level ? attack : release
        level += (t - level) * k
    }

    /// Bar heights in 0...1. `random` returns a value in the given range; injected for tests.
    public func barLevels(random: (ClosedRange<Float>) -> Float = { Float.random(in: $0) }) -> [Float] {
        Self.weights.map { w in
            let j = jitter > 0 ? random(-jitter...jitter) : 0
            return min(max(level * w * (1 + j), 0), 1)
        }
    }
}
