import SwiftUI

/// The playground host. Neutral background, centred orb, small state label, and
/// the two transport controls. The controls and the permission flow live here,
/// never in the reusable component.
struct OrbTestScreen: View {
    @State private var selectedMaterial: OrbMaterial = DeveloperOptions.initialMaterial
    @State private var firstColour: Double = 0
    @State private var secondColour: Double = 1
    @State private var selectedPair = OrbColourPair.initial
    @State private var previewsError = ProcessInfo.processInfo.arguments.contains("-orbErrorPreview")

    private var configuration: OrbConfiguration {
        var c = DeveloperOptions.configuration
        let a = OrbPreviewColour.allCases[Int(firstColour.rounded())]
        let b = OrbPreviewColour.allCases[Int(secondColour.rounded())]
        c.coreColorA = a.pigment
        c.coreColorB = b.pigment
        c.particleColorA = a.particle
        c.particleColorB = b.particle
        return c
    }
    @StateObject private var host = OrbTestHost()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            configuration.backgroundColor.ignoresSafeArea()

            VStack(spacing: 12) {
                TabView(selection: $selectedMaterial) {
                    ForEach(OrbMaterial.allCases) { material in
                        GeometryReader { proxy in
                            let side = min(proxy.size.width, proxy.size.height) * 0.92
                            VoiceOrb(configuration: configuration(for: material), audioProvider: host.provider)
                                .frame(width: side, height: side)
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        }
                        .tag(material)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack(spacing: 8) {
                    Text("\(selectedMaterial.rawValue + 1) / \(OrbMaterial.allCases.count) · \(selectedMaterial.title)")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .accessibilityIdentifier("orbVariantTitle")
                    HStack(spacing: 12) {
                        ForEach(OrbMaterial.allCases) { material in
                            Button {
                                withAnimation(.easeInOut(duration: 0.3)) { selectedMaterial = material }
                            } label: {
                                Circle()
                                    .fill(selectedMaterial == material ? Color.primary : Color.secondary.opacity(0.25))
                                    .frame(width: 7, height: 7)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(material.title)
                        }
                    }
                    Text("Swipe beside the orb to compare · Drag the orb to move it")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {

                    Text(host.label)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    if !DeveloperOptions.usesSimulatedAudio {
                        HStack(spacing: 12) {
                            Button(host.isPlaying ? "Stop" : "Play sample") {
                                host.togglePlayback()
                            }
                            .disabled(!host.canPlay)

                            Button(host.isListening ? "Stop listening" : "Listen") {
                                host.toggleListening()
                            }
                            .disabled(!host.canListen)
                        }
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .buttonStyle(.bordered)
                        .tint(.primary)

                        if host.showsSettingsHint {
                            Text("Enable the microphone in Settings › Privacy › Microphone, then tap Listen again.")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                        }
                    }
                    if selectedMaterial == .flowingPlasmaGlass {
                        colourPairGrid
                    } else {
                        colourSlider("Colour 1", selection: $firstColour)
                        colourSlider("Colour 2", selection: $secondColour)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 16)
            }
        }
        .task { await host.start() }
        .onDisappear { host.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Leaving the foreground releases the microphone and halts
            // playback; nothing keeps running behind the user's back.
            if phase != .active { host.releaseAudio() }
        }
    }

    private func configuration(for material: OrbMaterial) -> OrbConfiguration {
        var c = configuration
        c.material = material
        if material == .flowingPlasmaGlass {
            c.usesReferencePlasma = selectedPair.first == selectedPair.second || previewsError || host.hasAudioError
            c.previewsError = previewsError || host.hasAudioError
            c.referenceColorTo = selectedPair.first.adjacentPigment
            c.coreColorA = selectedPair.first.pigment
            c.coreColorB = selectedPair.second.pigment
            c.particleColorA = selectedPair.first.particle
            c.particleColorB = selectedPair.second.particle
        }
        c.renderingEnabled = selectedMaterial == material
        return c
    }

    private var colourPairGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(previewsError || host.hasAudioError ? "Error" : selectedPair.title)
                Spacer()
                Button(previewsError ? "End error preview" : "Preview error") {
                    previewsError.toggle()
                }
                .foregroundStyle(.red)
                .accessibilityIdentifier("orbErrorPreview")
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                ForEach(OrbColourPair.all) { pair in
                    Button { selectedPair = pair; previewsError = false } label: {
                        HStack(spacing: 0) {
                            pair.first.color
                            pair.second.color
                        }
                        .frame(height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(3)
                        .overlay {
                            RoundedRectangle(cornerRadius: 13)
                                .strokeBorder(selectedPair == pair ? Color.primary : Color.clear, lineWidth: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pair.title)
                    .accessibilityAddTraits(selectedPair == pair ? .isSelected : [])
                    .accessibilityIdentifier("orbColourPair-\(pair.id)")
                }
            }
        }
    }

    private func colourSlider(_ title: String, selection: Binding<Double>) -> some View {
        let selected = OrbPreviewColour.allCases[Int(selection.wrappedValue.rounded())]
        return VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(selected.rawValue).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            Slider(value: selection, in: 0...4, step: 1)
                .tint(selected.color)
                .accessibilityLabel(title)
                .accessibilityValue(selected.rawValue)
            HStack {
                ForEach(Array(OrbPreviewColour.allCases.enumerated()), id: \.offset) { index, colour in
                    if index > 0 { Spacer() }
                    Circle().fill(colour.color)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
        }
    }

}

/// Unordered pairs including matching colours: five colours produce 15 choices.
private struct OrbColourPair: Identifiable, Equatable {
    let first: OrbPreviewColour
    let second: OrbPreviewColour
    var id: String { "\(first.rawValue)-\(second.rawValue)" }
    var title: String { "\(first.rawValue) + \(second.rawValue)" }

    static var initial: OrbColourPair {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "-orbSameColour"), args.indices.contains(flag + 1),
           let colour = OrbPreviewColour(rawValue: args[flag + 1]) {
            return OrbColourPair(first: colour, second: colour)
        }
        return OrbColourPair(first: .yellow, second: .blue)
    }

    static let all: [OrbColourPair] = OrbPreviewColour.allCases.enumerated().flatMap { index, first in
        OrbPreviewColour.allCases.dropFirst(index).map { second in
            OrbColourPair(first: first, second: second)
        }
    }
}

/// Owns the router and polls it slowly, only so the labels and buttons can
/// update. Rendering never goes through this — the renderer reads the router
/// directly, once per frame.
@MainActor
final class OrbTestHost: ObservableObject {
    @Published private(set) var label = "idle"
    @Published private(set) var isPlaying = false
    @Published private(set) var isListening = false
    @Published private(set) var canPlay = false
    @Published private(set) var canListen = true
    @Published private(set) var showsSettingsHint = false
    @Published private(set) var hasAudioError = false

    private let simulated = SimulatedSpeechSource()
    private let router = OrbAudioRouter()
    private var timer: Timer?

    var provider: any OrbAudioProviding {
        DeveloperOptions.usesSimulatedAudio ? simulated : router
    }

    func start() async {
        startPolling()
        guard !DeveloperOptions.usesSimulatedAudio else { return }
        label = "preparing speech…"
        await router.preparePlayback()
        refresh()
    }

    func togglePlayback() {
        if isPlaying { router.stopPlayback() } else { router.startPlayback() }
        refresh()
    }

    func toggleListening() {
        if isListening {
            router.stopListening()
            refresh()
        } else {
            Task {
                await router.startListening()
                refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        router.stopAll()
    }

    /// Backgrounding: drop both audio sources but keep the prepared speech
    /// buffer, so returning does not have to re-synthesize.
    func releaseAudio() {
        router.stopPlayback()
        router.stopListening()
        refresh()
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        if DeveloperOptions.usesSimulatedAudio {
            set(label: "SIMULATED — " + simulated.currentLabel)
            return
        }

        let playbackFailed: Bool
        if case .failed = router.playback.status { playbackFailed = true } else { playbackFailed = false }
        let microphoneFailed: Bool
        switch router.microphone.status {
        case .failed, .unavailable, .denied: microphoneFailed = true
        default: microphoneFailed = false
        }
        let audioError = playbackFailed || microphoneFailed
        if hasAudioError != audioError { hasAudioError = audioError }
        let playing = router.playback.status == .playing
        let listening = router.microphone.status == .listening
        if isPlaying != playing { isPlaying = playing }
        if isListening != listening { isListening = listening }

        let playbackReady = router.playback.canPlay
        // The two sources are mutually exclusive, so each control is disabled
        // while the other owns the audio session.
        if canPlay != (playbackReady && !listening) { canPlay = playbackReady && !listening }
        if canListen != !playing { canListen = !playing }

        var hint = false
        let next: String
        switch router.microphone.status {
        case .listening:
            next = "listening"
        case .denied:
            next = "microphone access denied"
            hint = true
        case .unavailable(let reason):
            next = "microphone unavailable — \(reason)"
        case .failed(let reason):
            next = "microphone error — \(reason)"
        case .idle:
            switch router.playback.status {
            case .playing: next = "speaking"
            case .preparing: next = "preparing speech…"
            case .failed:
                next = playbackReady
                    ? "Couldn’t play the sample. Tap Play sample to try again."
                    : "The speech sample is unavailable. Reopen the app to try again."
            case .idle, .ready: next = "idle"
            }
        }
        if showsSettingsHint != hint { showsSettingsHint = hint }
        set(label: next)
    }

    private func set(label next: String) {
        if label != next { label = next }
    }
}

/// Launch-argument switches for capturing per-phase evidence. Not product
/// settings, not visible in the UI, and removable in one deletion.
enum DeveloperOptions {
    static var initialMaterial: OrbMaterial {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-orbVariant"),
              arguments.indices.contains(flag + 1),
              let value = Int(arguments[flag + 1]),
              let material = OrbMaterial(rawValue: value) else { return .baseline }
        return material
    }

    static var configuration: OrbConfiguration {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-orbLayerCore") { return .coreOnly }
        if arguments.contains("-orbLayerParticles") { return .particlesOnly }
        return .combined
    }

    /// Phase 5's scripted envelope. Kept only as an explicitly labelled test
    /// facility; real audio is the default from phase 6 onwards.
    static var usesSimulatedAudio: Bool {
        ProcessInfo.processInfo.arguments.contains("-orbSimulatedAudio")
    }
}

#Preview {
    OrbTestScreen()
}


/// Playground controls only; the reusable renderer receives its colours from the host.
private enum OrbPreviewColour: String, CaseIterable {
    case yellow = "Yellow", blue = "Blue", green = "Green", purple = "Purple", pink = "Pink"

    var pigment: SIMD3<Float> {
        switch self {
        case .yellow: return OrbPalette.yellow500
        case .blue: return OrbPalette.blue500
        case .green: return OrbPalette.green500
        case .purple: return OrbPalette.purple500
        case .pink: return OrbPalette.pink500
        }
    }

    // Neighbouring hues preserve the main colour while revealing the mesh flow.
    var adjacentPigment: SIMD3<Float> {
        switch self {
        case .yellow: return SIMD3(1, 158.0 / 255, 0)
        case .blue: return SIMD3(88.0 / 255, 101.0 / 255, 242.0 / 255)
        case .green: return SIMD3(22.0 / 255, 199.0 / 255, 132.0 / 255)
        case .purple: return SIMD3(236.0 / 255, 72.0 / 255, 153.0 / 255)
        case .pink: return SIMD3(244.0 / 255, 63.0 / 255, 94.0 / 255)
        }
    }

    var particle: SIMD3<Float> {
        switch self {
        case .yellow: return OrbPalette.yellow800
        case .blue: return OrbPalette.blue700
        // Darker previews derived from the verified 500 pigments, not new Figma tokens.
        case .green, .purple, .pink: return pigment * 0.65
        }
    }

    var color: Color {
        Color(red: Double(pigment.x), green: Double(pigment.y), blue: Double(pigment.z))
    }
}
