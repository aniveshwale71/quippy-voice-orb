import simd

/// Turns normalized touches into orb-space forces.
///
/// All input arrives in a -1...1 square with y pointing up, so the same gesture
/// produces the same motion at any component size. Nothing here knows about
/// UIKit, points, or the view's frame.
struct OrbGestureState {

    private(set) var impulses: [OrbImpulse] = []

    /// Pre-spin direction the finger is currently holding, if any.
    private(set) var dragOrigin: SIMD3<Float>?
    /// World-space direction and magnitude the finger is pulling toward.
    private(set) var dragVector: SIMD3<Float> = .zero

    /// Total finger travel since the drag began, in normalized units. The force
    /// follows this rather than the per-frame delta, so holding the finger still
    /// holds the deformation and the result does not depend on frame rate.
    private var dragTravel: SIMD2<Float> = .zero

    /// Trackball rotation the finger has accumulated, and its current rate.
    private(set) var rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
    private(set) var angularVelocity: SIMD3<Float> = .zero

    // MARK: Input

    mutating func tap(localDirection: SIMD3<Float>, time: Float, configuration: OrbConfiguration) {
        impulses.append(
            OrbImpulse(
                origin: SIMD4(localDirection, time),
                params: SIMD4(configuration.tapStrength, 0, 0, 0)
            )
        )
        if impulses.count > configuration.maxConcurrentTaps {
            impulses.removeFirst(impulses.count - configuration.maxConcurrentTaps)
        }
    }

    mutating func beginDrag(localDirection: SIMD3<Float>) {
        dragOrigin = localDirection
        dragVector = .zero
        dragTravel = .zero
        angularVelocity = .zero
    }

    /// - Parameters:
    ///   - translation: frame-to-frame finger movement in normalized units.
    ///   - deltaTime: seconds since the previous movement.
    mutating func updateDrag(localDirection: SIMD3<Float>,
                             translation: SIMD2<Float>,
                             deltaTime: Float,
                             configuration: OrbConfiguration) {
        dragOrigin = localDirection

        // The finger pulls in the screen plane; the camera looks down -z, so
        // screen x/y are world x/y.
        dragTravel += translation
        let travel = length(dragTravel)
        if travel > configuration.maxDragTravel {
            dragTravel *= configuration.maxDragTravel / travel
        }
        dragVector = SIMD3(dragTravel.x, dragTravel.y, 0)

        guard deltaTime > 0 else { return }
        let rate = translation / deltaTime
        // Horizontal drag spins about +y, vertical about -x: a trackball.
        let axisRate = SIMD3(-rate.y, rate.x, 0) * configuration.dragRotationGain
        angularVelocity = clampMagnitude(axisRate, to: configuration.maxAngularSpeed)
    }

    mutating func endDrag() {
        dragOrigin = nil
        dragVector = .zero
        dragTravel = .zero
        // angularVelocity survives: that is the release inertia.
    }

    // MARK: Per-frame

    mutating func advance(time: Float, deltaTime: Float, configuration: OrbConfiguration) {
        impulses.removeAll { time - $0.origin.w > configuration.tapLifetime }

        let speed = length(angularVelocity)
        if speed > 1e-5 {
            let step = simd_quatf(angle: speed * deltaTime, axis: angularVelocity / speed)
            rotation = simd_normalize(step * rotation)
        }

        // While the finger is down the drag keeps setting the rate; once it
        // lifts, this is what bleeds the spin away.
        if dragOrigin == nil {
            angularVelocity *= exp(-configuration.dragInertiaDecay * deltaTime)
            if length(angularVelocity) < 1e-4 { angularVelocity = .zero }
        }
    }

    private func clampMagnitude(_ v: SIMD3<Float>, to limit: Float) -> SIMD3<Float> {
        let m = length(v)
        return m > limit ? v * (limit / m) : v
    }
}
