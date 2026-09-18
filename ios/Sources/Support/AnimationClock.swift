import QuartzCore

/// One monotonic clock for every layer. Both the particle sphere and the core
/// read the same `time`, so their motion can never desynchronise.
final class AnimationClock {
    private var origin: CFTimeInterval
    private var lastTick: CFTimeInterval

    private(set) var time: Float = 0
    private(set) var deltaTime: Float = 1.0 / 60.0

    init() {
        let now = CACurrentMediaTime()
        origin = now
        lastTick = now
    }

    func tick() {
        let now = CACurrentMediaTime()
        // Clamp so a stall (backgrounding, breakpoint) cannot fire a huge step
        // through the simulation.
        deltaTime = Float(min(max(now - lastTick, 1.0 / 240.0), 1.0 / 20.0))
        lastTick = now
        time = Float(now - origin)
    }

    /// Call after a pause so the next tick is a normal-sized step.
    func resume() {
        lastTick = CACurrentMediaTime()
    }
}

/// Frame-rate reporting for the phase reports. Off unless the app is launched
/// with `-orbLogFrameRate`; it is a measurement tool, not a product feature.
final class FrameRateLog {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-orbLogFrameRate")

    private var frames = 0
    private var windowStart = CACurrentMediaTime()
    private var worstFrame: Double = 0

    func record(deltaTime: Float) {
        guard FrameRateLog.isEnabled else { return }
        frames += 1
        worstFrame = max(worstFrame, Double(deltaTime))

        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        guard elapsed >= 1 else { return }
        print(String(format: "[orb] %.1f fps over %.2fs, worst frame %.1f ms",
                     Double(frames) / elapsed, elapsed, worstFrame * 1000))
        frames = 0
        worstFrame = 0
        windowStart = now
    }
}
