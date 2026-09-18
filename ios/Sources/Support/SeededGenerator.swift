import Foundation

/// SplitMix64. Deterministic across runs and platforms so two recordings of the
/// same phase can be compared frame for frame.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unitFloat() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func float(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + unitFloat() * (range.upperBound - range.lowerBound)
    }
}
