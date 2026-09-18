import Foundation

/// Turns a rectified audio level into the smooth 0...1 envelope both visual
/// layers share. Quick attack so speech onsets land on time, slower release so
/// the orb settles instead of flickering between syllables.
///
/// Phase 5 feeds this a simulated signal and phases 6 and 7 feed it real
/// samples. Nothing about the follower changes between them.
public struct OrbEnvelopeFollower {

    /// Seconds to close most of the gap when the signal is rising.
    public var attack: Float
    /// Seconds to close most of the gap when the signal is falling.
    public var release: Float
    /// Levels at or below this count as silence, so room tone cannot keep the
    /// orb moving. Subtracted and rescaled rather than hard-gated, which would
    /// make quiet speech pop in.
    public var noiseFloor: Float
    public var gain: Float

    private var value: Float = 0

    public init(attack: Float = 0.035,
                release: Float = 0.18,
                noiseFloor: Float = 0.04,
                gain: Float = 1.0) {
        self.attack = attack
        self.release = release
        self.noiseFloor = noiseFloor
        self.gain = gain
    }

    public var current: Float { value }

    @discardableResult
    public mutating func update(rawLevel: Float, deltaTime: Float) -> Float {
        // Gain first, then the floor. A microphone's raw RMS is far below 1, so
        // gating before the gain would mean no amount of gain could ever lift
        // quiet speech over the floor.
        let boosted = min(max(rawLevel * gain, 0), 1)
        let floor = min(max(noiseFloor, 0), 0.95)
        let target = max(boosted - floor, 0) / (1 - floor)

        let tau = max(target > value ? attack : release, 1e-4)
        // Frame-rate independent: the same wall-clock time gives the same
        // approach whatever the frame rate.
        let k = 1 - exp(-max(deltaTime, 0) / tau)
        value += (target - value) * k
        if value < 1e-4 { value = 0 }
        return value
    }

    /// Drop straight to silence. Used when a source stops so a stale tail cannot
    /// outlive the audio that produced it.
    public mutating func reset() {
        value = 0
    }
}
