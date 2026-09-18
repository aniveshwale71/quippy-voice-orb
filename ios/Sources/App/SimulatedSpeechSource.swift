import Foundation

/// TEMPORARY DEVELOPER TEST FACILITY — NOT REAL AUDIO.
///
/// A deterministic, scripted state and envelope timeline so phase 5 can be
/// reviewed and re-recorded identically. It runs a fixed loop through silence,
/// quiet speech, pauses, loud speech and state changes.
///
/// Phase 6 replaces this as the speaking source with a real playback envelope
/// and keeps this only behind an explicit developer flag. Nothing here may ever
/// stand in for real audio in a report.
final class SimulatedSpeechSource: OrbAudioProviding {

    /// One leg of the script.
    private struct Segment {
        let duration: Float
        let state: OrbState
        /// 0 means silence. Otherwise the speech loudness this leg plays at.
        let intensity: Float
        let label: String
    }

    private let script: [Segment] = [
        Segment(duration: 3.0, state: .idle,      intensity: 0.00, label: "idle, silent"),
        Segment(duration: 3.0, state: .listening, intensity: 0.00, label: "listening, silent"),
        Segment(duration: 6.0, state: .listening, intensity: 0.28, label: "listening, quiet speech"),
        Segment(duration: 1.5, state: .listening, intensity: 0.00, label: "listening, pause"),
        Segment(duration: 5.5, state: .listening, intensity: 0.95, label: "listening, loud speech"),
        Segment(duration: 2.0, state: .idle,      intensity: 0.00, label: "idle, silent"),
        Segment(duration: 6.0, state: .speaking,  intensity: 0.55, label: "speaking, normal"),
        Segment(duration: 1.0, state: .speaking,  intensity: 0.00, label: "speaking, pause"),
        Segment(duration: 5.0, state: .speaking,  intensity: 0.95, label: "speaking, loud"),
        Segment(duration: 3.0, state: .idle,      intensity: 0.00, label: "idle, silent"),
    ]

    private var follower = OrbEnvelopeFollower()

    /// Latest values, for the host's state label. Read at a lazy rate by the UI,
    /// never used to drive rendering.
    private(set) var currentLabel: String = "idle, silent"
    private(set) var currentState: OrbState = .idle

    var loopDuration: Float { script.reduce(0) { $0 + $1.duration } }

    func sample(at time: Float, deltaTime: Float) -> (state: OrbState, level: Float) {
        let total = loopDuration
        var cursor = total > 0 ? time.truncatingRemainder(dividingBy: total) : 0

        var segment = script[0]
        for candidate in script {
            if cursor < candidate.duration { segment = candidate; break }
            cursor -= candidate.duration
        }

        let raw = segment.intensity > 0 ? Self.speechLevel(at: time, intensity: segment.intensity) : 0
        let level = follower.update(rawLevel: raw, deltaTime: deltaTime)

        currentLabel = segment.label
        currentState = segment.state
        return (segment.state, level)
    }

    /// A speech-shaped envelope built from fixed sinusoids: a syllable rate, a
    /// slower gate that opens and closes between words, and a gentle drift in
    /// loudness. Entirely deterministic — no randomness, no timers.
    private static func speechLevel(at t: Float, intensity: Float) -> Float {
        let syllable = 0.55 + 0.45 * sin(t * 25.1)
        let gate = smoothstep(0.25, 0.48, 0.5 + 0.5 * sin(t * 4.4 + 1.3))
        let drift = 0.85 + 0.15 * sin(t * 1.7 + 0.6)
        return intensity * syllable * gate * drift
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
