import XCTest
import AVFoundation
@testable import VoiceOrbPlayground

/// Focused tests for the parts where a wrong answer is invisible on screen:
/// envelope normalization and smoothing, and the reduced-motion transform.
/// These do not replace watching and listening to the orb.
final class OrbEnvelopeFollowerTests: XCTestCase {

    func testSilenceStaysAtZero() {
        var follower = OrbEnvelopeFollower()
        for _ in 0..<120 { follower.update(rawLevel: 0, deltaTime: 1.0 / 60) }
        XCTAssertEqual(follower.current, 0, accuracy: 1e-6)
    }

    func testNoiseBelowTheFloorProducesNoMotion() {
        var follower = OrbEnvelopeFollower(noiseFloor: 0.06, gain: 9)
        // The ambient RMS measured on the test Mac.
        for _ in 0..<600 { follower.update(rawLevel: 0.0011, deltaTime: 1.0 / 60) }
        XCTAssertEqual(follower.current, 0, accuracy: 1e-6)
    }

    func testGainIsAppliedBeforeTheFloor() {
        // A quiet microphone signal must still be liftable over the floor by
        // gain. Applying the floor first would make this impossible.
        var follower = OrbEnvelopeFollower(noiseFloor: 0.06, gain: 9)
        for _ in 0..<60 { follower.update(rawLevel: 0.03, deltaTime: 1.0 / 60) }
        XCTAssertGreaterThan(follower.current, 0.1)
    }

    func testOutputIsNeverAboveOne() {
        var follower = OrbEnvelopeFollower(gain: 20)
        for _ in 0..<120 { follower.update(rawLevel: 5, deltaTime: 1.0 / 60) }
        XCTAssertLessThanOrEqual(follower.current, 1.0)
    }

    func testAttackIsFasterThanRelease() {
        var rising = OrbEnvelopeFollower(attack: 0.035, release: 0.18, noiseFloor: 0)
        for _ in 0..<6 { rising.update(rawLevel: 1, deltaTime: 1.0 / 60) }
        let afterRise = rising.current

        var falling = OrbEnvelopeFollower(attack: 0.035, release: 0.18, noiseFloor: 0)
        for _ in 0..<600 { falling.update(rawLevel: 1, deltaTime: 1.0 / 60) }
        for _ in 0..<6 { falling.update(rawLevel: 0, deltaTime: 1.0 / 60) }
        let afterFall = 1 - falling.current

        XCTAssertGreaterThan(afterRise, afterFall,
                             "A quick attack must cover more ground in six frames than the release does.")
    }

    func testSmoothingIsFrameRateIndependent() {
        // The same wall-clock time must reach the same place whatever the step.
        var sixty = OrbEnvelopeFollower(noiseFloor: 0)
        for _ in 0..<60 { sixty.update(rawLevel: 1, deltaTime: 1.0 / 60) }

        var thirty = OrbEnvelopeFollower(noiseFloor: 0)
        for _ in 0..<30 { thirty.update(rawLevel: 1, deltaTime: 1.0 / 30) }

        XCTAssertEqual(sixty.current, thirty.current, accuracy: 0.01)
    }

    func testResetDropsToSilenceImmediately() {
        var follower = OrbEnvelopeFollower(noiseFloor: 0)
        for _ in 0..<60 { follower.update(rawLevel: 1, deltaTime: 1.0 / 60) }
        XCTAssertGreaterThan(follower.current, 0.5)
        follower.reset()
        XCTAssertEqual(follower.current, 0, accuracy: 1e-6)
    }
}

final class AudioEnvelopeTrackTests: XCTestCase {

    func testSilentAudioProducesNoEnvelope() {
        let track = AudioEnvelopeTrack(samples: [Float](repeating: 0, count: 4096), sampleRate: 22050)
        XCTAssertEqual(track.value(atFrame: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(track.value(atFrame: 2048), 0, accuracy: 1e-6)
    }

    func testLoudSectionReadsHigherThanQuietSection() {
        // First half quiet, second half loud.
        var samples = [Float](repeating: 0.02, count: 4096)
        samples.append(contentsOf: [Float](repeating: 0.6, count: 4096))
        let track = AudioEnvelopeTrack(samples: samples, sampleRate: 22050)
        XCTAssertLessThan(track.value(atFrame: 1024), track.value(atFrame: 6144))
    }

    func testPositionsPastTheEndReadSilent() {
        let track = AudioEnvelopeTrack(samples: [Float](repeating: 0.5, count: 2048), sampleRate: 22050)
        XCTAssertEqual(track.value(atFrame: 1_000_000), 0, accuracy: 1e-6)
        XCTAssertEqual(track.value(atFrame: -50), 0, accuracy: 1e-6)
    }

    func testEmptyAudioIsHandled() {
        let track = AudioEnvelopeTrack(samples: [], sampleRate: 22050)
        XCTAssertTrue(track.isEmpty)
        XCTAssertEqual(track.value(atFrame: 0), 0, accuracy: 1e-6)
    }
}

final class OrbConfigurationTests: XCTestCase {

    func testReducedMotionDampsMovementButKeepsIdentity() {
        let normal = OrbConfiguration.combined
        let reduced = normal.applyingReducedMotion()

        XCTAssertLessThan(reduced.flowAmplitude, normal.flowAmplitude)
        XCTAssertLessThan(reduced.spinSpeed, normal.spinSpeed)
        XCTAssertLessThan(reduced.coreRegionDrift, normal.coreRegionDrift)
        XCTAssertLessThan(reduced.tapStrength, normal.tapStrength)

        // Identity must survive: same colours, same layout, same particles.
        XCTAssertEqual(reduced.coreColorA, normal.coreColorA)
        XCTAssertEqual(reduced.coreColorB, normal.coreColorB)
        XCTAssertEqual(reduced.particleCount, normal.particleCount)
        XCTAssertEqual(reduced.particleSeed, normal.particleSeed)
        XCTAssertEqual(reduced.sphereFillFraction, normal.sphereFillFraction)
    }

    func testReducedMotionKeepsAudioResponseVisible() {
        let normal = OrbConfiguration.combined
        let reduced = normal.applyingReducedMotion()
        // Damped, but not so far that the orb stops showing it is hearing you.
        XCTAssertLessThan(reduced.outerAudioGain, normal.outerAudioGain)
        XCTAssertGreaterThan(reduced.outerAudioGain, normal.outerAudioGain * 0.4)
    }

    func testMaxRadiusLeavesRoomInsideTheCanvas() {
        let c = OrbConfiguration.combined
        // A particle at maxRadius must still project inside the canvas.
        XCTAssertLessThan(c.maxRadius * c.sphereFillFraction, 1.0)
    }
}

final class OrbParticleSeedTests: XCTestCase {

    func testSeedsAreDeterministic() {
        let c = OrbConfiguration.combined
        let first = OrbParticleSeeds.make(configuration: c)
        let second = OrbParticleSeeds.make(configuration: c)
        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.base, b.base)
            XCTAssertEqual(a.params, b.params)
        }
    }

    func testEveryParticleRestsInsideMaxRadius() {
        let c = OrbConfiguration.combined
        for seed in OrbParticleSeeds.make(configuration: c) {
            // params.x is the radius scale; breathing can add radialAmplitude.
            XCTAssertLessThanOrEqual(seed.params.x + c.radialAmplitude, c.maxRadius,
                                     "A particle resting past maxRadius would be hauled back by the clamp.")
        }
    }
}

/// Reproduces the shared-session handoff that previously left playback unable
/// to start after microphone stop or backgrounding.
@MainActor
final class OrbPlaybackSessionTests: XCTestCase {
    func testPlaybackRestoresSessionAfterMicrophoneAndCanReplay() async throws {
        let playback = SpeechPlaybackSource()
        defer { playback.teardown() }
        await playback.prepare()
        XCTAssertEqual(playback.status, .ready)
        guard playback.canPlay else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        try session.setActive(false)
        playback.play()
        XCTAssertEqual(session.category, .playback)
        XCTAssertEqual(playback.status, .playing)
        playback.stop()
        try session.setActive(false)
        XCTAssertTrue(playback.canPlay)
        playback.play()
        XCTAssertEqual(playback.status, .playing)
    }
}


final class ReferencePlasmaMotionTests: XCTestCase {
    func testIdleMatchesReferenceClockAndMesh() {
        var motion = ReferencePlasmaMotion()
        for _ in 0..<600 { motion.update(deltaTime: 1 / 60, state: .idle, level: 0, error: false, reducedMotion: false) }
        XCTAssertEqual(motion.time, 11, accuracy: 0.001)
        XCTAssertEqual(motion.distortion, 0.42, accuracy: 0.001)
        XCTAssertEqual(motion.swirl, 0.26, accuracy: 0.001)
        XCTAssertEqual(motion.grain, 0.06, accuracy: 0.001)
    }

    func testErrorEasesInAndReturnsToIdle() {
        var motion = ReferencePlasmaMotion()
        for _ in 0..<6 { motion.update(deltaTime: 1 / 60, state: .idle, level: 0, error: true, reducedMotion: false) }
        XCTAssertGreaterThan(motion.errorMix, 0)
        XCTAssertLessThan(motion.errorMix, 1)
        XCTAssertLessThan(motion.distortion, 0.85)
        for _ in 0..<300 { motion.update(deltaTime: 1 / 60, state: .idle, level: 0, error: true, reducedMotion: false) }
        XCTAssertEqual(motion.errorMix, 1)
        XCTAssertEqual(motion.distortion, 0.85, accuracy: 0.001)
        XCTAssertEqual(motion.swirl, 0.55, accuracy: 0.001)
        XCTAssertEqual(motion.grain, 0.2, accuracy: 0.001)
        for _ in 0..<300 { motion.update(deltaTime: 1 / 60, state: .idle, level: 0, error: false, reducedMotion: false) }
        XCTAssertEqual(motion.errorMix, 0)
        XCTAssertEqual(motion.distortion, 0.42, accuracy: 0.001)
    }

    func testSpeechUsesReferenceTargetsAndReducedMotionFreezesClock() {
        var motion = ReferencePlasmaMotion()
        for _ in 0..<300 { motion.update(deltaTime: 1 / 60, state: .speaking, level: 1, error: false, reducedMotion: false) }
        XCTAssertEqual(motion.distortion, 0.9, accuracy: 0.001)
        XCTAssertEqual(motion.swirl, 0.55, accuracy: 0.001)
        XCTAssertEqual(motion.grain, 0.18, accuracy: 0.001)
        for _ in 0..<300 { motion.update(deltaTime: 1 / 60, state: .idle, level: 0, error: true, reducedMotion: true) }
        XCTAssertEqual(motion.time, 8)
        XCTAssertEqual(motion.errorMix, 1)
    }
}
