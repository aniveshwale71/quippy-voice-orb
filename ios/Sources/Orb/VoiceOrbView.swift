import MetalKit
import SwiftUI

/// The reusable orb. It owns rendering only: no microphone permission, no
/// navigation, no product chrome. The host supplies state, audio intensity and
/// configuration.
public struct VoiceOrbView: UIViewRepresentable {

    private let configuration: OrbConfiguration
    private let state: OrbState
    private let audioLevel: Float
    private let audioProvider: (any OrbAudioProviding)?

    public init(configuration: OrbConfiguration = OrbConfiguration(),
                state: OrbState = .idle,
                audioLevel: Float = 0,
                audioProvider: (any OrbAudioProviding)? = nil) {
        self.configuration = configuration
        self.state = state
        self.audioLevel = audioLevel
        self.audioProvider = audioProvider
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration)
    }

    public func makeUIView(context: Context) -> MTKView {
        let view = OrbInteractionView(frame: .zero, device: context.coordinator.renderer?.device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 1.0
        view.isOpaque = false
        view.backgroundColor = .clear
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator.renderer

        let renderer = context.coordinator.renderer
        view.onTap = { renderer?.handleTap(at: $0) }
        view.onDragBegan = { renderer?.handleDragBegan(at: $0) }
        view.onDragChanged = { renderer?.handleDragChanged(at: $0, translation: $1, deltaTime: $2) }
        view.onDragEnded = { renderer?.handleDragEnded() }
        // Returning from the background must not integrate the whole time away
        // into one frame.
        view.onResume = { renderer?.resumeClock() }
        view.onReduceMotionChange = { renderer?.reduceMotionEnabled = $0 }
        renderer?.reduceMotionEnabled = UIAccessibility.isReduceMotionEnabled

        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }
        renderer.configuration = configuration
        renderer.audioProvider = audioProvider
        if audioProvider == nil {
            renderer.state = state
            renderer.audioLevel = audioLevel
        }
    }

    public final class Coordinator {
        let renderer: OrbRenderer?
        let setupFailure: String?

        init(configuration: OrbConfiguration) {
            do {
                renderer = try OrbRenderer(configuration: configuration)
                setupFailure = nil
            } catch {
                renderer = nil
                setupFailure = String(describing: error)
            }
        }
    }
}

/// Square, centred container with unclipped margins. The orb never draws
/// outside this box.
public struct VoiceOrb: View {
    private let configuration: OrbConfiguration
    private let state: OrbState
    private let audioLevel: Float
    private let audioProvider: (any OrbAudioProviding)?

    public init(configuration: OrbConfiguration = OrbConfiguration(),
                state: OrbState = .idle,
                audioLevel: Float = 0,
                audioProvider: (any OrbAudioProviding)? = nil) {
        self.configuration = configuration
        self.state = state
        self.audioLevel = audioLevel
        self.audioProvider = audioProvider
    }

    public var body: some View {
        VoiceOrbView(configuration: configuration,
                     state: state,
                     audioLevel: audioLevel,
                     audioProvider: audioProvider)
            .aspectRatio(1, contentMode: .fit)
    }
}
