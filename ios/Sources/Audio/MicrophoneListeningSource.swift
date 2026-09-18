import AVFoundation
import os

/// Drives the orb from live microphone samples.
///
/// The input node is tapped but never connected to the output, so nothing the
/// microphone hears is played back through the speaker. The tap does the least
/// work it can — one pass for a sum of squares — and hands the result off
/// through a lock; no rendering or allocation happens on the audio thread.
final class MicrophoneListeningSource: NSObject, OrbAudioProviding {

    enum Status: Equatable {
        case idle
        case denied
        case unavailable(String)
        case listening
        case failed(String)
    }

    private let engine = AVAudioEngine()
    private var follower: OrbEnvelopeFollower
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var isListening = false
        /// Most recent RMS from the tap, already scaled.
        var level: Float = 0
        /// Frames seen since listening began — proof that real samples arrived.
        var framesCaptured: Int = 0
        var peak: Float = 0
    }

    @MainActor private(set) var status: Status = .idle

    /// Microphone RMS is small and device-dependent, so it needs its own gain
    /// and a floor set above room tone. Measured ambient on the test Mac was
    /// an RMS of about 0.0011, which these values reject outright. Provisional:
    /// they want a live check against real speech on real hardware.
    init(gain: Float = 9.0, noiseFloor: Float = 0.06) {
        follower = OrbEnvelopeFollower(attack: 0.035, release: 0.22,
                                       noiseFloor: noiseFloor, gain: gain)
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
    }

    /// Counters for the phase report: how much real audio actually arrived.
    var capturedFrames: Int { lock.withLock { $0.framesCaptured } }
    var observedPeak: Float { lock.withLock { $0.peak } }

    // MARK: - Transport

    @MainActor
    func start() async {
        guard status != .listening else { return }

        guard await Self.requestPermission() else {
            status = .denied
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            // `.record`, not `.playAndRecord`: this prototype never needs both
            // at once, and choosing record outright removes any chance of the
            // microphone reaching the speaker.
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
        } catch {
            status = .failed("Audio session refused to activate: \(error.localizedDescription)")
            return
        }

        guard session.isInputAvailable else {
            status = .unavailable("No audio input device is available.")
            try? session.setActive(false)
            return
        }

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            status = .unavailable("The input node reports a zero-rate format, so no microphone is connected.")
            try? session.setActive(false)
            return
        }

        input.removeTap(onBus: 0)   // belt and braces against a duplicate tap
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }

        lock.withLock { state in
            state.isListening = true
            state.level = 0
            state.framesCaptured = 0
            state.peak = 0
        }
        follower.reset()

        do {
            engine.prepare()
            try engine.start()
            status = .listening
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { $0.isListening = false }
            status = .failed("Audio engine failed to start: \(error.localizedDescription)")
            try? session.setActive(false)
        }
    }

    @MainActor
    func stop() {
        lock.withLock { state in
            state.isListening = false
            state.level = 0
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if status == .listening { status = .idle }
    }

    // MARK: - Audio thread

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        let samples = channels[0]
        for index in 0..<frames {
            let value = samples[index]
            sum += value * value
        }
        let rms = (sum / Float(frames)).squareRoot()

        lock.withLock { state in
            guard state.isListening else { return }
            state.level = rms
            state.framesCaptured += frames
            state.peak = max(state.peak, rms)
        }
    }

    // MARK: - Interruptions

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // A call or another app taking the input ends the session. Stop rather
        // than resume silently, so the orb never sits pretending to listen.
        if type == .began {
            Task { @MainActor in self.stop() }
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        if reason == .oldDeviceUnavailable || reason == .noSuitableRouteForCategory {
            Task { @MainActor in self.stop() }
        }
    }

    private static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - OrbAudioProviding

    func sample(at time: Float, deltaTime: Float) -> (state: OrbState, level: Float) {
        let snapshot = lock.withLock { ($0.isListening, $0.level) }
        let raw = snapshot.0 ? snapshot.1 : 0
        let level = follower.update(rawLevel: raw, deltaTime: deltaTime)

        if MicrophoneListeningSource.logsLevels && snapshot.0 {
            print(String(format: "[mic] wall=%.3f rms=%.5f level=%.4f", Double(time), raw, level))
        }

        if snapshot.0 { return (.listening, level) }
        // Ease out rather than cutting when listening stops.
        return (level > 0.01 ? .listening : .idle, level)
    }

    static let logsLevels = ProcessInfo.processInfo.arguments.contains("-orbLogMic")
}
