import Foundation

/// The single provider the orb sees. It owns both real sources and guarantees
/// exactly one of them is live, so the renderer never has to know which is
/// which and the two can never overlap.
///
/// Mutual exclusion lives here rather than in the host, so there is one place
/// to be right about it.
@MainActor
final class OrbAudioRouter: OrbAudioProviding {

    enum Source: Equatable {
        case none
        case playback
        case microphone
    }

    // `nonisolated` because the render thread samples them every frame; both
    // sources guard their own mutable state with a lock.
    nonisolated let playback = SpeechPlaybackSource()
    nonisolated let microphone = MicrophoneListeningSource()

    private(set) var active: Source = .none

    // MARK: - Transport

    func preparePlayback() async {
        await playback.prepare()
    }

    func startPlayback() {
        // Starting one source always stops the other first, in that order, so
        // there is never a window where both sessions are active.
        microphone.stop()
        active = .playback
        playback.play()
    }

    func stopPlayback() {
        playback.stop()
        if active == .playback { active = .none }
    }

    func startListening() async {
        playback.stop()
        active = .microphone
        await microphone.start()
        if microphone.status != .listening { active = .none }
    }

    func stopListening() {
        microphone.stop()
        if active == .microphone { active = .none }
    }

    func stopAll() {
        playback.teardown()
        microphone.stop()
        active = .none
    }

    // MARK: - OrbAudioProviding

    nonisolated func sample(at time: Float, deltaTime: Float) -> (state: OrbState, level: Float) {
        // Both sources ease their own envelope out after stopping, so polling
        // the inactive one would fight that. Ask whichever is current; when
        // neither is, ask both and take the one still decaying.
        let fromPlayback = playback.sample(at: time, deltaTime: deltaTime)
        let fromMicrophone = microphone.sample(at: time, deltaTime: deltaTime)
        return fromPlayback.level >= fromMicrophone.level ? fromPlayback : fromMicrophone
    }
}
