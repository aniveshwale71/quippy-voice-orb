import SwiftUI
import simd

/// Everything the orb's appearance is driven by. All values are provisional
/// prototype defaults (see plan.md "Provisional starting values"), not approved
/// specifications. Nothing here is configurable from inside the component's own
/// UI — the host owns it.
public struct OrbConfiguration: Equatable {

    // MARK: Layout

    /// Fraction of the (square) orb canvas that the particle sphere's diameter
    /// occupies at rest. The remainder is unclipped margin for audio expansion
    /// and gesture deformation.
    public var sphereFillFraction: Float = 0.74 * 0.85

    /// Core diameter as a fraction of the particle-sphere diameter.
    public var coreRadiusRatio: Float = 0.85  // Inner diameter is 85% of the nominal outer sphere diameter.

    public var fieldOfView: Float = .pi / 6  // 30°

    // MARK: Particles

    public var particleCount: Int = 2000

    /// Random seed for particle identities. Fixed so runs are comparable.
    public var particleSeed: UInt64 = 0x51EE_D0_0B

    /// World-space diameter of one particle, relative to an orb radius of 1.
    public var particlePointSize: Float = (0.0118 / 0.85) * 1.5  // Enlarge individual dots by 50%.

    /// Shell thickness as a fraction of the orb radius.
    public var shellThickness: Float = 0.055

    /// Fraction of particles allowed to sit outside the shell as sparse strays.
    public var strayFraction: Float = 0.022

    // MARK: Idle motion

    public var flowAmplitude: Float = 0.085
    public var flowFrequency: Float = 1.45
    public var flowSpeed: Float = 0.085
    public var radialAmplitude: Float = 0.028
    public var radialFrequency: Float = 2.1

    /// Radians per second of the slow global spin, and the axis it turns about.
    public var spinSpeed: Float = 0.085
    public var spinAxis: SIMD3<Float> = normalize(SIMD3<Float>(0.18, 1.0, 0.08))

    // MARK: Particle shading

    public var particleColor: SIMD3<Float> = SIMD3(0.106, 0.098, 0.090)  // #1B1917
    /// Darker Figma swatches keep dots visible against the light background.
    public var particleColorA: SIMD3<Float> = OrbPalette.yellow800
    public var particleColorB: SIMD3<Float> = OrbPalette.blue700
    public var particleOpacity: Float = 1.0
    /// Alpha of a particle facing straight at the camera.
    public var interiorAlpha: Float = 0.48
    /// Alpha of a particle on the silhouette.
    public var rimStrength: Float = 1.0
    public var rimExponent: Float = 1.35
    /// Multiplier applied to particles on the far side of the sphere.
    public var backDimming: Float = 0.65
    /// How much a particle grows between the far and near side.
    public var sizeDepthGain: Float = 0.30

    // MARK: Gestures

    public var gesturesEnabled: Bool = true

    /// How far past the orb radius a particle may ever travel. Sized from
    /// `sphereFillFraction` so motion cannot leave the component's bounds.
    /// The 0.90 keeps a margin for perspective — a displaced particle nearer the
    /// camera projects further out than its world radius alone suggests — and
    /// for the particle's own sprite width.
    public var maxRadius: Float { 0.90 / max(sphereFillFraction, 0.05) }

    /// Radians of arc the tap front crosses per second.
    public var rippleSpeed: Float = 2.3
    /// Angular thickness of the tap front.
    public var rippleWidth: Float = 0.42
    /// Per-second amplitude decay of a tap.
    public var rippleDecay: Float = 1.2
    public var tapStrength: Float = 28.0
    /// Concurrent taps kept alive. Older ones are dropped, so hammering the orb
    /// cannot accumulate unbounded force.
    public var maxConcurrentTaps: Int = 8
    public var tapLifetime: Float = 2.6

    /// Angular falloff of the drag grab.
    public var dragRadius: Float = 0.85
    public var dragStrength: Float = 26.0
    /// Cap on accumulated finger travel, in normalized units, so one very long
    /// drag cannot keep piling on force.
    public var maxDragTravel: Float = 1.2
    /// Normalized drag distance to radians of trackball rotation.
    public var dragRotationGain: Float = 2.2
    /// Per-second decay of the spin the finger imparted on release.
    public var dragInertiaDecay: Float = 1.7
    public var maxAngularSpeed: Float = 3.2

    public var springStiffness: Float = 42.0
    public var springDamping: Float = 5.6

    // MARK: Core
    //
    // The two colours are explicit inputs. Audio loudness never changes them.

    /// Figma Pop Colors, node 2130:9665. Shared by the core, dots and halo.
    public var coreColorA: SIMD3<Float> = OrbPalette.yellow500
    public var coreColorB: SIMD3<Float> = OrbPalette.blue500

    /// Broad feather retains two regions without a painted dividing seam.
    public var coreBoundarySoftness: Float = 0.38
    /// Radians per second the colour axis turns. Deliberately slow.
    public var coreRegionDrift: Float = 0.055
    /// How far noise bends the boundary off a perfect great circle.
    public var coreWarpAmount: Float = 0.45
    public var coreWarpFrequency: Float = 1.25

    public var coreLightDirection: SIMD3<Float> = normalize(SIMD3<Float>(-0.65, 0.68, 0.42))
    public var coreAmbient: Float = 0.74
    public var coreSpecular: Float = 0.025
    public var coreEdgeDarkening: Float = 0.055

    // MARK: Audio response
    //
    // Both layers read one shared envelope. Only the gains differ, so they can
    // never fall out of rhythm with each other.

    /// Outer sphere expansion at full envelope. The stronger of the two.
    public var outerAudioGain: Float = 0.14
    /// Core scaling at full envelope. Deliberately restrained.
    public var coreAudioGain: Float = 0.06

    /// How much of the envelope each state lets through. Idle ignores audio
    /// entirely; speaking responds harder than listening.
    public var idleResponse: Float = 0.0
    public var listeningResponse: Float = 1.0
    public var speakingResponse: Float = 1.25

    /// Seconds for a state change to take effect. Long enough that switching
    /// states cannot pop, short enough to feel immediate.
    public var stateTransition: Float = 0.30

    // MARK: Accessibility

    /// When the system's Reduce Motion setting is on, the orb damps its
    /// movement rather than freezing. Set false to opt out entirely.
    public var respectsReduceMotion: Bool = true

    /// Fraction of the normal movement that survives under Reduce Motion.
    /// Deliberately not zero: the orb still has to show idle, listening and
    /// speaking apart, just with far less motion.
    public var reducedMotionScale: Float = 0.3

    // MARK: Development-only layer switches
    //
    // Not product settings. They let one phase work on one layer without
    // deleting the other, and they are never exposed in the component's UI.

    public var showsParticles: Bool = true
    public var showsCore: Bool = false

    public var background: SIMD3<Float> = SIMD3(0.996, 0.988, 0.980)  // #FEFCFA

    public init() {}
}

public extension OrbConfiguration {
    var backgroundColor: Color {
        Color(red: Double(background.x), green: Double(background.y), blue: Double(background.z))
    }

    /// Phases 2 and 3: outer particle sphere only, core hidden.
    static var particlesOnly: OrbConfiguration {
        var c = OrbConfiguration()
        c.showsParticles = true
        c.showsCore = false
        return c
    }

    /// Phase 4: core only, particles hidden.
    static var coreOnly: OrbConfiguration {
        var c = OrbConfiguration()
        c.showsParticles = false
        c.showsCore = true
        return c
    }

    /// Phase 5 onwards: the whole orb.
    static var combined: OrbConfiguration {
        var c = OrbConfiguration()
        c.showsParticles = true
        c.showsCore = true
        return c
    }

    /// The Reduce Motion variant. Everything that *moves* is damped; nothing
    /// that *identifies* is touched — the colours, the particle count, the
    /// layout and the seed are all unchanged, so the orb still looks like
    /// itself and still distinguishes its states.
    func applyingReducedMotion() -> OrbConfiguration {
        var c = self
        let scale = max(min(reducedMotionScale, 1), 0)

        c.flowAmplitude *= scale
        c.flowSpeed *= scale
        c.radialAmplitude *= scale
        c.spinSpeed *= scale
        c.coreRegionDrift *= scale

        // Audio response is damped but kept clearly visible: it is the only
        // thing that tells a viewer the orb is hearing them.
        let audioScale = max(scale, 0.45)
        c.outerAudioGain *= audioScale
        c.coreAudioGain *= audioScale

        // Gestures stay responsive but settle sooner and travel less far.
        c.tapStrength *= scale
        c.dragStrength *= scale
        c.dragRotationGain *= scale
        c.dragInertiaDecay /= max(scale, 0.2)

        return c
    }
}

/// Verified against Figma Pop Colors (2130:9665), 2026-09-18.
/// Two active colours are chosen by the host; audio never switches emotions.
public enum OrbPalette {
    public static let blue500 = rgb(0x00AEFA)
    public static let blue700 = rgb(0x0074D5)
    public static let yellow500 = rgb(0xFFE600)
    public static let yellow800 = rgb(0xF59400)
    public static let green500 = rgb(0x83F300)
    public static let purple500 = rgb(0xA948E5)
    public static let pink500 = rgb(0xFF339F)

    private static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
    }
}
