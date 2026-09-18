import Foundation

/// A loudness curve measured from real PCM samples, addressable by frame
/// position. Because it is indexed by *where the audio is*, the orb can be
/// driven from playback position rather than from when buffers happened to
/// arrive — those two are not the same thing, and only the first is in sync
/// with what the listener hears.
struct AudioEnvelopeTrack {

    /// Frames between successive envelope values.
    let hop: Int
    let sampleRate: Double
    private let values: [Float]

    var frameCount: Int { values.count * hop }
    var duration: Double { Double(frameCount) / sampleRate }
    var isEmpty: Bool { values.isEmpty }

    /// Builds an RMS curve and normalizes it so ordinary speech peaks near 1.
    /// Normalizing against a high percentile rather than the absolute maximum
    /// stops one stray click from flattening everything else.
    init(samples: [Float], sampleRate: Double, hop: Int = 256) {
        self.hop = max(hop, 1)
        self.sampleRate = sampleRate

        guard !samples.isEmpty else {
            values = []
            return
        }

        var rms: [Float] = []
        rms.reserveCapacity(samples.count / self.hop + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + self.hop, samples.count)
            var sum: Float = 0
            for i in index..<end { sum += samples[i] * samples[i] }
            rms.append((sum / Float(end - index)).squareRoot())
            index = end
        }

        let reference = AudioEnvelopeTrack.percentile(rms, 0.98)
        let scale = reference > 1e-5 ? 1 / reference : 1
        values = rms.map { min($0 * scale, 1) }
    }

    func value(atFrame frame: Int) -> Float {
        // Guard on the frame, not the index: integer division truncates toward
        // zero, so a small negative frame would otherwise land on index 0 and
        // return the first envelope value instead of silence.
        guard !values.isEmpty, frame >= 0 else { return 0 }
        let index = frame / hop
        guard index < values.count else { return 0 }
        return values[index]
    }

    private static func percentile(_ input: [Float], _ p: Float) -> Float {
        guard !input.isEmpty else { return 0 }
        let sorted = input.sorted()
        let position = Int(Float(sorted.count - 1) * p)
        return sorted[max(0, min(sorted.count - 1, position))]
    }
}
