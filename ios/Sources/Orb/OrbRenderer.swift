import MetalKit
import simd

final class OrbRenderer: NSObject, MTKViewDelegate {

    enum SetupError: Error, CustomStringConvertible {
        case noDevice
        case noLibrary
        case pipelineFailed(String)

        var description: String {
            switch self {
            case .noDevice: return "This device or simulator has no Metal device."
            case .noLibrary: return "The default Metal library could not be loaded."
            case .pipelineFailed(let reason): return "Metal pipeline creation failed: \(reason)"
            }
        }
    }

    var configuration: OrbConfiguration {
        didSet {
            if configuration.particleCount != oldValue.particleCount
                || configuration.particleSeed != oldValue.particleSeed
                || configuration.shellThickness != oldValue.shellThickness
                || configuration.strayFraction != oldValue.strayFraction {
                rebuildParticleBuffers()
            }
        }
    }

    var state: OrbState = .idle
    var audioLevel: Float = 0

    /// Optional per-frame source. When set it overrides `state` and
    /// `audioLevel`, which lets an audio source drive the orb without pushing
    /// sixty state updates a second through SwiftUI.
    weak var audioProvider: (any OrbAudioProviding)?

    /// Smoothed gate from the current state, so switching states ramps the
    /// audio response in and out instead of stepping it.
    private var idleBlend: Float = 1
    private var idlePhase: Float = 0
    private var stateResponse: Float = 0
    private var coreMotionPhase: Float = 0
    private var coreMotionIntensity: Float = 0.12
    private var referenceMotion = ReferencePlasmaMotion()

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let updatePipeline: MTLComputePipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let corePipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    private let glowDepthState: MTLDepthStencilState
    private let depthState: MTLDepthStencilState

    private var seedBuffer: MTLBuffer?
    private var stateBuffer: MTLBuffer?
    private var renderBuffer: MTLBuffer?
    private var particleCount: Int = 0

    private let clock = AnimationClock()
    private let frameRateLog = FrameRateLog()
    private var drawableSize: CGSize = .zero

    private var gestures = OrbGestureState()
    private var impulseBuffer: MTLBuffer?

    // Camera terms from the last frame, reused to project touches back onto the
    // sphere. One frame stale at most, which no finger can perceive.
    private var currentSpin = matrix_identity_float4x4
    private var currentCameraDistance: Float = 1
    private var currentTanHalfFov: Float = 1
    private var currentAspect: Float = 1

    init(configuration: OrbConfiguration) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SetupError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw SetupError.noDevice }
        guard let library = device.makeDefaultLibrary() else { throw SetupError.noLibrary }

        self.configuration = configuration
        self.device = device
        self.queue = queue

        do {
            guard let updateFn = library.makeFunction(name: "orbParticleUpdate") else {
                throw SetupError.noLibrary
            }
            updatePipeline = try device.makeComputePipelineState(function: updateFn)

            let particleDescriptor = MTLRenderPipelineDescriptor()
            particleDescriptor.vertexFunction = library.makeFunction(name: "orbParticleVertex")
            particleDescriptor.fragmentFunction = library.makeFunction(name: "orbParticleFragment")
            particleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            particleDescriptor.depthAttachmentPixelFormat = .depth32Float
            OrbRenderer.applyAlphaBlending(to: particleDescriptor.colorAttachments[0]!)
            particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)

            let coreDescriptor = MTLRenderPipelineDescriptor()
            coreDescriptor.vertexFunction = library.makeFunction(name: "orbCoreVertex")
            coreDescriptor.fragmentFunction = library.makeFunction(name: "orbCoreFragment")
            coreDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            coreDescriptor.depthAttachmentPixelFormat = .depth32Float
            OrbRenderer.applyAlphaBlending(to: coreDescriptor.colorAttachments[0]!)
            corePipeline = try device.makeRenderPipelineState(descriptor: coreDescriptor)
            coreDescriptor.fragmentFunction = library.makeFunction(name: "orbGlowFragment")
            glowPipeline = try device.makeRenderPipelineState(descriptor: coreDescriptor)
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError.pipelineFailed(error.localizedDescription)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw SetupError.pipelineFailed("depth stencil state")
        }
        self.depthState = depthState
        depthDescriptor.isDepthWriteEnabled = false
        depthDescriptor.depthCompareFunction = .always
        guard let glowDepth = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            throw SetupError.pipelineFailed("glow depth state")
        }
        self.glowDepthState = glowDepth

        super.init()
        rebuildParticleBuffers()
    }

    private static func applyAlphaBlending(to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    // MARK: - Buffers

    private func rebuildParticleBuffers() {
        let seeds = OrbParticleSeeds.make(configuration: configuration)
        particleCount = seeds.count

        seedBuffer = seeds.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        stateBuffer = device.makeBuffer(
            length: MemoryLayout<OrbParticleState>.stride * particleCount,
            options: .storageModePrivate
        )
        renderBuffer = device.makeBuffer(
            length: MemoryLayout<OrbParticleRender>.stride * particleCount,
            options: .storageModePrivate
        )
        impulseBuffer = device.makeBuffer(
            length: MemoryLayout<OrbImpulse>.stride * max(configuration.maxConcurrentTaps, 1),
            options: .storageModeShared
        )

        // storageModePrivate starts undefined; zero the simulation state once.
        if let stateBuffer,
           let commandBuffer = queue.makeCommandBuffer(),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.fill(buffer: stateBuffer, range: 0..<stateBuffer.length, value: 0)
            blit.endEncoding()
            commandBuffer.commit()
        }
    }

    // MARK: - Uniforms

    /// Reduce Motion is an accessibility setting, so the component honours it
    /// itself rather than making every host remember to.
    var reduceMotionEnabled = false

    private var effectiveConfiguration: OrbConfiguration {
        guard reduceMotionEnabled, configuration.respectsReduceMotion else { return configuration }
        return configuration.applyingReducedMotion()
    }

    private func makeUniforms() -> OrbUniforms {
        let c = effectiveConfiguration
        let aspect = drawableSize.height > 0 ? Float(drawableSize.width / drawableSize.height) : 1

        // Place the camera so a unit-radius sphere fills `sphereFillFraction` of
        // the canvas, leaving the rest as unclipped margin. Clip space spans
        // -1...1 over the full height, so the sphere's NDC radius and its
        // diameter-as-a-fraction-of-the-canvas are the same number.
        let tanHalfFov = tan(c.fieldOfView * 0.5)
        let projectedRadius = max(c.sphereFillFraction, 0.05)
        let cameraDistance = 1.0 / (projectedRadius * tanHalfFov)
        let eye = SIMD3<Float>(0, 0, cameraDistance)

        let nearPlane = max(cameraDistance - 3, 0.05)
        let farPlane = cameraDistance + 3
        let projection = MatrixMath.perspective(
            fovY: c.fieldOfView,
            aspect: aspect,
            near: nearPlane,
            far: farPlane
        )
        let view = MatrixMath.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))

        let pointScale = Float(drawableSize.height) * 0.5 / tanHalfFov
        let idleSpin = MatrixMath.rotation(axis: c.spinAxis, angle: clock.time * c.spinSpeed)
        let spin = matrix_float4x4(gestures.rotation) * idleSpin
        currentSpin = spin
        currentCameraDistance = cameraDistance
        currentTanHalfFov = tanHalfFov
        currentAspect = aspect

        return OrbUniforms(
            viewProjection: projection * view,
            spin: spin,
            cameraPosition: SIMD4(eye, 0),
            particleColor: SIMD4(c.particleColor, c.particleOpacity),
            coreColorA: SIMD4(c.coreColorA, 1),
            coreColorB: SIMD4(c.coreColorB, 1),
            particleColorA: SIMD4(c.particleColorA, 1),
            particleColorB: SIMD4(c.particleColorB, 1),
            dragOrigin: SIMD4(gestures.dragOrigin ?? .zero, gestures.dragOrigin == nil ? 0 : 1),
            dragVector: SIMD4(gestures.dragVector, 0),
            coreLightDirection: SIMD4(normalize(c.coreLightDirection), 0),
            idleMotion: SIMD4(idlePhase, c.tapStrength * 0.25 * idleBlend,
                              1 + 0.03 * (0.5 - 0.5 * cos(idlePhase)) * idleBlend
                                * ((reduceMotionEnabled && configuration.respectsReduceMotion) ? c.reducedMotionScale : 1), Float(c.material.rawValue)),
            meshMotion: SIMD4(referenceMotion.time, referenceMotion.distortion,
                              referenceMotion.swirl, referenceMotion.grain),
            meshPaletteTo: SIMD4(c.referenceColorTo,
                c.material == .flowingPlasmaGlass && (c.usesReferencePlasma || referenceMotion.errorMix > 0.001) ? 1 : 0),
            meshError: SIMD4(referenceMotion.errorMix, 0, 0, 0),
            time: clock.time,
            deltaTime: clock.deltaTime,
            orbRadius: 1,
            pointScale: pointScale,
            particlePointSize: c.particlePointSize,
            flowAmplitude: c.flowAmplitude,
            flowFrequency: c.flowFrequency,
            flowSpeed: c.flowSpeed,
            radialAmplitude: c.radialAmplitude,
            radialFrequency: c.radialFrequency,
            shellThickness: c.shellThickness,
            rimStrength: c.rimStrength,
            rimExponent: c.rimExponent,
            interiorAlpha: c.interiorAlpha,
            backDimming: c.backDimming,
            sizeDepthGain: c.sizeDepthGain,
            audioLevel: effectiveAudio,
            outerAudioGain: c.outerAudioGain,
            coreAudioGain: c.coreAudioGain,
            coreRadiusRatio: c.coreRadiusRatio,
            tanHalfFov: tanHalfFov,
            particleCount: UInt32(particleCount),
            nearPlane: nearPlane,
            farPlane: farPlane,
            maxRadius: c.maxRadius,
            rippleSpeed: c.rippleSpeed,
            rippleWidth: c.rippleWidth,
            rippleDecay: c.rippleDecay,
            dragRadius: c.dragRadius,
            dragStrength: c.dragStrength,
            springStiffness: c.springStiffness,
            springDamping: c.springDamping,
            impulseCount: UInt32(gestures.impulses.count),
            aspect: aspect,
            coreBoundarySoftness: c.coreBoundarySoftness,
            coreRegionDrift: c.coreRegionDrift,
            coreWarpAmount: c.coreWarpAmount,
            coreWarpFrequency: c.coreWarpFrequency,
            coreAmbient: c.coreAmbient,
            coreSpecular: c.coreSpecular,
            coreEdgeDarkening: c.coreEdgeDarkening,
            coreMotionPhase: coreMotionPhase,
            coreMotionIntensity: coreMotionIntensity
        )
    }

    // MARK: - Gestures

    /// Projects a touch in the orb's normalized -1...1 space onto the sphere and
    /// returns the direction in pre-spin space, so the grabbed spot stays with
    /// the surface as the orb turns.
    private func localDirection(for point: SIMD2<Float>) -> SIMD3<Float> {
        let eye = SIMD3<Float>(0, 0, currentCameraDistance)
        let ray = normalize(SIMD3(point.x * currentTanHalfFov * currentAspect,
                                  point.y * currentTanHalfFov,
                                  -1))

        let b = dot(ray, eye)
        let c = dot(eye, eye) - 1
        let discriminant = b * b - c

        let surface: SIMD3<Float>
        if discriminant >= 0 {
            surface = normalize(eye + ray * (-b - sqrt(discriminant)))
        } else {
            // A touch past the silhouette still grabs the nearest point on the
            // rim rather than doing nothing.
            surface = normalize(eye + ray * max(-b, 0))
        }

        let inverseSpin = currentSpin.transpose  // pure rotation
        let local = inverseSpin * SIMD4(surface, 0)
        return normalize(SIMD3(local.x, local.y, local.z))
    }

    func handleTap(at point: SIMD2<Float>) {
        guard configuration.gesturesEnabled else { return }
        gestures.tap(localDirection: localDirection(for: point),
                     time: clock.time,
                     configuration: effectiveConfiguration)
    }

    func handleDragBegan(at point: SIMD2<Float>) {
        guard configuration.gesturesEnabled else { return }
        gestures.beginDrag(localDirection: localDirection(for: point))
    }

    func handleDragChanged(at point: SIMD2<Float>, translation: SIMD2<Float>, deltaTime: Float) {
        guard configuration.gesturesEnabled else { return }
        gestures.updateDrag(localDirection: localDirection(for: point),
                            translation: translation,
                            deltaTime: deltaTime,
                            configuration: effectiveConfiguration)
    }

    func handleDragEnded() {
        gestures.endDrag()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        clock.tick()
        frameRateLog.record(deltaTime: clock.deltaTime)
        gestures.advance(time: clock.time, deltaTime: clock.deltaTime, configuration: effectiveConfiguration)
        advanceAudioResponse()

        var uniforms = makeUniforms()
        uploadImpulses()

        if configuration.showsParticles,
           let seedBuffer, let stateBuffer, let renderBuffer, let impulseBuffer, particleCount > 0,
           let compute = commandBuffer.makeComputeCommandEncoder() {
            compute.setComputePipelineState(updatePipeline)
            compute.setBuffer(seedBuffer, offset: 0, index: 0)
            compute.setBuffer(stateBuffer, offset: 0, index: 1)
            compute.setBuffer(renderBuffer, offset: 0, index: 2)
            compute.setBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 3)
            compute.setBuffer(impulseBuffer, offset: 0, index: 4)

            let width = min(updatePipeline.maxTotalThreadsPerThreadgroup, 64)
            compute.dispatchThreadgroups(
                MTLSize(width: (particleCount + width - 1) / width, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
            )
            compute.endEncoding()
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()
            return
        }
        // Coloured haze is drawn behind the sphere and never occludes particles.
        if configuration.showsCore {
            encoder.setDepthStencilState(glowDepthState)
            encoder.setRenderPipelineState(glowPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setDepthStencilState(depthState)

        // The core writes depth first so rear particles cannot paint over it.
        if configuration.showsCore {
            encoder.setRenderPipelineState(corePipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if configuration.showsParticles, let renderBuffer, particleCount > 0 {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(renderBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// One shared envelope, one shared clock. Both layers read `effectiveAudio`
    /// in the same frame, so they cannot lag one another.
    private func advanceAudioResponse() {
        if let provider = audioProvider {
            let sample = provider.sample(at: clock.time, deltaTime: clock.deltaTime)
            state = sample.state
            audioLevel = sample.level
        }

        let c = effectiveConfiguration
        referenceMotion.update(deltaTime: clock.deltaTime, state: state,
            level: effectiveAudio, error: c.material == .flowingPlasmaGlass && c.previewsError,
            reducedMotion: reduceMotionEnabled && c.respectsReduceMotion)
        let idleTarget: Float = state == .idle ? 1 : 0
        idleBlend += (idleTarget - idleBlend) * (1 - exp(-clock.deltaTime / 0.65))
        // One 4.8-second cycle drives both the surface wave and core breathing.
        idlePhase = (idlePhase + clock.deltaTime * 2 * .pi / 4.8).truncatingRemainder(dividingBy: 2 * .pi)
        let target: Float
        switch state {
        case .idle: target = c.idleResponse
        case .listening: target = c.listeningResponse
        case .speaking: target = c.speakingResponse
        }

        let k = 1 - exp(-clock.deltaTime / max(c.stateTransition, 1e-4))
        stateResponse += (target - stateResponse) * k
        let motionTarget: Float
        switch state {
        case .idle: motionTarget = 0.12
        case .listening: motionTarget = 0.22 + effectiveAudio * 1.05
        case .speaking: motionTarget = 0.78 + effectiveAudio * 0.55
        }
        // Smooth both speed and deformation across syllables and state changes.
        let motionTime: Float = motionTarget > coreMotionIntensity ? 0.40 : 0.70
        let motionBlend = 1 - exp(-clock.deltaTime / motionTime)
        coreMotionIntensity += (motionTarget - coreMotionIntensity) * motionBlend
        // Integrate velocity, rather than multiplying absolute time by a
        // changing speed, to keep every transition continuous.
        coreMotionPhase += clock.deltaTime * c.coreRegionDrift * (1 + coreMotionIntensity * 7 + max(coreMotionIntensity - 0.25, 0) * 6)

    }

    private var effectiveAudio: Float {
        min(max(audioLevel, 0) * stateResponse, 1)
    }

    private func uploadImpulses() {
        guard let impulseBuffer, !gestures.impulses.isEmpty else { return }
        gestures.impulses.withUnsafeBytes { source in
            memcpy(impulseBuffer.contents(),
                   source.baseAddress!,
                   min(source.count, impulseBuffer.length))
        }
    }

    func resumeClock() {
        clock.resume()
    }
}

// Timing port from VoiceOrbs plasma-orb (MIT). See THIRD_PARTY_NOTICES.md.
// Paper's frame=8000 means 8 seconds, not 8000 animation frames.
struct ReferencePlasmaMotion {
    private(set) var time: Float = 8
    private(set) var distortion: Float = 0.42
    private(set) var swirl: Float = 0.26
    private(set) var grain: Float = 0.06
    private(set) var errorMix: Float = 0
    private var energy: Float = 0
    private var smoothDistortion: Float = 0.42
    private var smoothSwirl: Float = 0.26
    private var smoothSpeed: Float = 0.3
    private var smoothGrain: Float = 0.06
    private var smoothError: Float = 0
    private var speed: Float = 0.3
    private var sincePush: Float = 0

    mutating func update(deltaTime: Float, state: OrbState, level: Float,
                         error: Bool, reducedMotion: Bool) {
        let dt = min(max(deltaTime, 0), 0.1)
        let targetEnergy: Float = error ? 0.2 : (state == .idle ? 0 : max(0, min(1, level)))
        func approach(_ current: Float, _ target: Float, _ rate: Float) -> Float {
            current + (target - current) * (1 - exp(-rate * dt))
        }
        energy = approach(energy, targetEnergy, 7.5)
        let active = state == .listening || state == .speaking
        let targetDistortion: Float = error ? 0.85 : (active ? min(1, 0.5 + energy * 0.4) : 0.42)
        let targetSwirl: Float = error ? 0.55 : (active ? min(1, 0.3 + energy * 0.25) : 0.26)
        let targetSpeed: Float = error ? 1.8 : (state == .listening ? 1.6 : state == .speaking ? 1.1 : 0.3)
        let targetGrain: Float = error ? 0.2 : (state == .listening ? 0.16 : state == .speaking ? 0.18 : 0.06)
        smoothDistortion = approach(smoothDistortion, targetDistortion, 6)
        smoothSwirl = approach(smoothSwirl, targetSwirl, 6)
        smoothSpeed = approach(smoothSpeed, targetSpeed, 5)
        smoothGrain = approach(smoothGrain, targetGrain, 6)
        smoothError = approach(smoothError, error ? 1 : 0, 6)
        if !reducedMotion { time += dt * speed }
        sincePush += dt
        if reducedMotion {
            time = 8
            distortion = targetDistortion
            swirl = targetSwirl
            grain = targetGrain
            errorMix = error ? 1 : 0
        } else if sincePush > 0.066 {
            sincePush = 0
            distortion = (smoothDistortion * 100).rounded() / 100
            swirl = (smoothSwirl * 100).rounded() / 100
            speed = (smoothSpeed * 100).rounded() / 100
            grain = (smoothGrain * 200).rounded() / 200
            errorMix = (smoothError * 100).rounded() / 100
        }
    }
}
