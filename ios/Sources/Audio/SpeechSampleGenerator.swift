import AVFoundation

/// Renders the fixed sample lines to PCM with the on-device speech synthesizer.
/// No network, no API key, no bundled audio file.
///
/// `AVSpeechSynthesizer.write` hands back buffers as fast as it can generate
/// them, which is far ahead of playback. This type only *collects* them; timing
/// is the playback source's problem, and it uses the player's own clock.
enum SpeechSampleGenerator {

    enum GenerationError: Error, CustomStringConvertible {
        case noVoice
        case producedNoAudio
        case unsupportedFormat(String)

        var description: String {
            switch self {
            case .noVoice:
                return "No speech voice is installed on this device or simulator."
            case .producedNoAudio:
                return "The speech synthesizer returned no audio frames."
            case .unsupportedFormat(let detail):
                return "Unexpected speech buffer format: \(detail)"
            }
        }
    }

    struct Rendered {
        let samples: [Float]
        let sampleRate: Double
        /// Where each line begins, in frames. Useful when reporting which line
        /// a given moment belongs to.
        let lineStarts: [Int]
    }

    /// The fixed lines from the plan. Do not edit without being asked.
    static let lines = [
        "Hey. How has your day been?",
        "Tell me about something small that surprised you today. Take your time.",
        "That sounds interesting. What happened next?",
    ]

    /// Silence inserted between lines, so the pauses the orb has to show are
    /// real gaps in the audio rather than something the visuals invent.
    static let gapBetweenLines: Double = 0.55

    static func render() async throws -> Rendered {
        guard let voice = preferredVoice() else { throw GenerationError.noVoice }

        var samples: [Float] = []
        var lineStarts: [Int] = []
        var sampleRate: Double = 0

        for line in lines {
            lineStarts.append(samples.count)

            let utterance = AVSpeechUtterance(string: line)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            let (lineSamples, rate) = try await renderOne(utterance)
            if sampleRate == 0 { sampleRate = rate }
            samples.append(contentsOf: lineSamples)

            if rate > 0 {
                samples.append(contentsOf: [Float](repeating: 0, count: Int(gapBetweenLines * rate)))
            }
        }

        guard !samples.isEmpty, sampleRate > 0 else { throw GenerationError.producedNoAudio }
        return Rendered(samples: samples, sampleRate: sampleRate, lineStarts: lineStarts)
    }

    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let english = voices.filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .enhanced }
            ?? english.first
            ?? AVSpeechSynthesisVoice(language: "en-US")
            ?? voices.first
    }

    private static func renderOne(_ utterance: AVSpeechUtterance) async throws -> ([Float], Double) {
        // The synthesizer must outlive the write; a local `let` would be
        // released the moment this function suspends.
        let synthesizer = AVSpeechSynthesizer()

        return try await withCheckedThrowingContinuation { continuation in
            var collected: [Float] = []
            var rate: Double = 0
            var finished = false

            synthesizer.write(utterance) { buffer in
                guard !finished else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    finished = true
                    continuation.resume(throwing: GenerationError.unsupportedFormat(
                        String(describing: type(of: buffer))))
                    return
                }

                // A zero-length buffer is how `write` signals the end.
                guard pcm.frameLength > 0 else {
                    finished = true
                    withExtendedLifetime(synthesizer) {}
                    continuation.resume(returning: (collected, rate))
                    return
                }

                rate = pcm.format.sampleRate
                do {
                    collected.append(contentsOf: try monoFloats(from: pcm))
                } catch {
                    finished = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The synthesizer may hand back 16-bit or floating-point frames depending
    /// on the voice, so handle both rather than assuming.
    private static func monoFloats(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }

        if let data = buffer.floatChannelData {
            var out = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[channel][frame] }
                out[frame] = sum / Float(channels)
            }
            return out
        }

        if let data = buffer.int16ChannelData {
            var out = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(data[channel][frame]) / 32768 }
                out[frame] = sum / Float(channels)
            }
            return out
        }

        if let data = buffer.int32ChannelData {
            var out = [Float](repeating: 0, count: frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(data[channel][frame]) / 2_147_483_648 }
                out[frame] = sum / Float(channels)
            }
            return out
        }

        throw GenerationError.unsupportedFormat(buffer.format.description)
    }
}
