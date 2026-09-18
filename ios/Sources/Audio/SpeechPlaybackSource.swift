import AVFoundation
import os

/// Plays the rendered sample speech and drives the orb from the envelope of the
/// audio that is *currently audible*.
///
/// The envelope is measured from the real PCM samples and looked up by the
/// player node's own playback position, corrected for output latency. There is
/// no timer, no word count, and no sentence-duration guess anywhere in here: if
/// the audio stops, the envelope reads zero because the samples at that
/// position are zero.
final class SpeechPlaybackSource: NSObject, OrbAudioProviding {

    enum Status: Equatable {
        case idle
        case preparing
        case ready
        case playing
        case failed(String)
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var buffer: AVAudioPCMBuffer?
    private var track: AudioEnvelopeTrack?
    private var follower = OrbEnvelopeFollower()

    /// Guards the handful of fields the render thread reads while the main
    /// thread mutates them.
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var isPlaying = false
        /// Bumped on every stop so a completion handler from a cancelled
        /// playback cannot clear the state of a newer one.
        var generation: UInt64 = 0
        var outputLatencyFrames: AVAudioFramePosition = 0
    }

    @MainActor private(set) var status: Status = .idle
    /// Last envelope value handed to the renderer, for the host's readout.
    private(set) var lastLevel: Float = 0

    var trackDuration: Double { track?.duration ?? 0 }

    // MARK: - Setup

    @MainActor
    func prepare() async {
        guard status == .idle || isFailed else { return }
        status = .preparing
        do {
            let rendered = try await SpeechSampleGenerator.render()
            try configureSession()
            try buildGraph(with: rendered)
            status = .ready
        } catch {
            status = .failed(String(describing: error))
        }
    }

    @MainActor
    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func buildGraph(with rendered: SpeechSampleGenerator.Rendered) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: rendered.sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(rendered.samples.count)) else {
            throw SpeechSampleGenerator.GenerationError.producedNoAudio
        }

        pcm.frameLength = AVAudioFrameCount(rendered.samples.count)
        rendered.samples.withUnsafeBufferPointer { source in
            pcm.floatChannelData![0].update(from: source.baseAddress!, count: rendered.samples.count)
        }

        buffer = pcm
        track = AudioEnvelopeTrack(samples: rendered.samples, sampleRate: rendered.sampleRate)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()

        let latency = AVAudioSession.sharedInstance().outputLatency
        lock.withLock { $0.outputLatencyFrames = AVAudioFramePosition(latency * rendered.sampleRate) }
    }

    // MARK: - Transport

    @MainActor
    func play() {
        guard status == .ready || status == .playing, let buffer else { return }
        stop()

        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            status = .failed("Audio engine failed to start: \(error)")
            return
        }

        let generation = lock.withLock { state -> UInt64 in
            state.generation &+= 1
            state.isPlaying = true
            return state.generation
        }
        follower.reset()

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            guard let self else { return }
            // Only the playback that scheduled this handler may end it. A stop
            // followed by a fresh play must not be cut short by the old one.
            self.lock.withLock { state in
                if state.generation == generation { state.isPlaying = false }
            }
            Task { @MainActor in
                if self.lock.withLock({ $0.generation }) == generation { self.status = .ready }
            }
        }
        player.play()
        status = .playing
    }

    @MainActor
    func stop() {
        lock.withLock { state in
            // Bumping the generation orphans the scheduled buffer's completion
            // handler, so a cancelled playback cannot clear the state of the
            // next one.
            state.generation &+= 1
            state.isPlaying = false
        }
        player.stop()   // also discards anything still queued

        // Deliberately *not* `follower.reset()`. Zeroing here would cut the orb
        // to a standstill in one frame. Leaving the follower where it is lets
        // the idle path decay it over the release time, so the orb eases back.
        if status == .playing { status = .ready }
    }

    @MainActor
    func teardown() {
        stop()
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - OrbAudioProviding

    func sample(at time: Float, deltaTime: Float) -> (state: OrbState, level: Float) {
        let snapshot = lock.withLock { ($0.isPlaying, $0.outputLatencyFrames) }
        let playing = snapshot.0

        guard playing, let track, !track.isEmpty else {
            let level = follower.update(rawLevel: 0, deltaTime: deltaTime)
            lastLevel = level
            if SpeechPlaybackSource.logsEnvelope && level > 0.001 {
                print(String(format: "[env] wall=%.3f playback=STOPPED raw=0.0000 level=%.4f",
                             Double(time), level))
            }
            // Keep reporting `.speaking` while the envelope tails out, so the
            // orb eases back instead of snapping the instant audio ends.
            return (level > 0.01 ? .speaking : .idle, level)
        }

        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            let level = follower.update(rawLevel: 0, deltaTime: deltaTime)
            lastLevel = level
            return (.speaking, level)
        }

        // `lastRenderTime` is the render clock, which runs ahead of the speaker
        // by the output latency. Subtracting it lines the visuals up with what
        // is actually being heard rather than with what has been rendered.
        let audibleFrame = playerTime.sampleTime - snapshot.1
        let raw = track.value(atFrame: Int(max(audibleFrame, 0)))
        let level = follower.update(rawLevel: raw, deltaTime: deltaTime)
        lastLevel = level

        if SpeechPlaybackSource.logsEnvelope {
            let seconds = Double(max(audibleFrame, 0)) / track.sampleRate
            print(String(format: "[env] wall=%.3f playback=%.3f raw=%.4f level=%.4f",
                         Double(time), seconds, raw, level))
        }
        return (.speaking, level)
    }

    /// Measurement aid for the phase report: prints the envelope against
    /// playback position so it can be correlated with the recorded video.
    static let logsEnvelope = ProcessInfo.processInfo.arguments.contains("-orbLogEnvelope")
}
