import Foundation

/// What the orb reads once per rendered frame: the state to be in, and the
/// shared normalized envelope both layers respond to.
///
/// The component never captures, plays, or analyses audio itself. Phase 5
/// supplies a simulated source; phases 6 and 7 supply real playback and
/// microphone sources through this same interface.
public protocol OrbAudioProviding: AnyObject {

    /// - Parameters:
    ///   - time: the renderer's monotonic clock, so a source that is a pure
    ///     function of time stays in step with the animation.
    ///   - deltaTime: seconds since the previous frame.
    /// - Returns: the state to render and a 0...1 envelope.
    func sample(at time: Float, deltaTime: Float) -> (state: OrbState, level: Float)
}
