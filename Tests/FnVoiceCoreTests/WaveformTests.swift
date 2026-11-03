import Foundation
import Testing
@testable import FnVoiceCore

@Suite struct WaveformTests {
    @Test func rmsOfFullScaleSineIsOneOverRootTwo() {
        let samples = (0..<4800).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        let rms = samples.withUnsafeBufferPointer(LevelMeter.rms)
        #expect(abs(rms - 1 / 2.0.squareRoot().float) < 0.001)
    }

    @Test func silenceAndEmptyBuffersAreZero() {
        let zeros = [Float](repeating: 0, count: 512)
        #expect(zeros.withUnsafeBufferPointer(LevelMeter.level) == 0)
        #expect([Float]().withUnsafeBufferPointer(LevelMeter.rms) == 0)
    }

    @Test func dbMappingIsClampedBetweenNoiseFloorAndCeiling() {
        #expect(LevelMeter.normalized(dBFS: -80) == 0)
        #expect(LevelMeter.normalized(dBFS: -50) == 0)
        #expect(LevelMeter.normalized(dBFS: -31) == 0.5)
        #expect(LevelMeter.normalized(dBFS: -12) == 1)
        #expect(LevelMeter.normalized(dBFS: 0) == 1)
    }

    @Test func louderInputGivesHigherLevel() {
        let quiet = [Float](repeating: 0.01, count: 256).withUnsafeBufferPointer(LevelMeter.level)
        let loud = [Float](repeating: 0.2, count: 256).withUnsafeBufferPointer(LevelMeter.level)
        #expect(loud > quiet)
    }

    @Test func attackClosesFortyPercentReleaseFifteen() {
        var e = WaveformEnvelope()
        e.step(target: 1)
        #expect(abs(e.level - 0.40) < 1e-6)
        e.step(target: 0)
        #expect(abs(e.level - 0.40 * 0.85) < 1e-6)
    }

    @Test func barsFollowWeightsWithoutJitter() {
        var e = WaveformEnvelope()
        for _ in 0..<60 { e.step(target: 1) }
        let bars = e.barLevels { _ in 0 }
        #expect(bars.count == 5)
        for (bar, w) in zip(bars, WaveformEnvelope.weights) { #expect(abs(bar - w * e.level) < 1e-5) }
        #expect(bars[2] == bars.max()) // centre highest
    }

    @Test func jitterStaysWithinFourPercent() {
        var e = WaveformEnvelope()
        for _ in 0..<60 { e.step(target: 0.6) }
        for _ in 0..<1000 {
            for (bar, w) in zip(e.barLevels(), WaveformEnvelope.weights) {
                let base = e.level * w
                #expect(bar >= base * 0.96 - 1e-6 && bar <= base * 1.04 + 1e-6)
            }
        }
    }
}

private extension Double {
    var float: Float { Float(self) }
}
