import MetalKit
import QuartzCore
import simd

/// An `MTKView` that reports touches in the orb's own normalized space:
/// a -1...1 square with y pointing up. Because nothing leaves this class in
/// points, gestures behave identically whatever size the component is given.
final class OrbInteractionView: MTKView, UIGestureRecognizerDelegate {

    var onTap: ((SIMD2<Float>) -> Void)?
    var onDragBegan: ((SIMD2<Float>) -> Void)?
    var onDragChanged: ((SIMD2<Float>, SIMD2<Float>, Float) -> Void)?
    var onDragEnded: (() -> Void)?

    private var lastDragPoint: SIMD2<Float> = .zero
    private var lastDragTime: CFTimeInterval = 0

    /// Called when the view pauses or resumes, so the renderer can restart its
    /// clock rather than integrating the whole time spent in the background.
    var onResume: (() -> Void)?
    var onReduceMotionChange: ((Bool) -> Void)?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isUserInteractionEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(reduceMotionChanged),
                           name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = normalized(touch.location(in: self))
        // Sphere occupies 63% of the canvas; retain a little interaction margin.
        return simd_length(point) < 0.73
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Touching Metal while backgrounded is not allowed, so stop drawing before
    /// the app is suspended rather than after.
    @objc private func appDidEnterBackground() {
        isPaused = true
    }

    @objc private func appWillEnterForeground() {
        isPaused = false
        onResume?()
    }

    @objc private func reduceMotionChanged() {
        onReduceMotionChange?(UIAccessibility.isReduceMotionEnabled)
    }

    private func normalized(_ point: CGPoint) -> SIMD2<Float> {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return SIMD2(Float(point.x / bounds.width) * 2 - 1,
                     1 - Float(point.y / bounds.height) * 2)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        onTap?(normalized(recognizer.location(in: self)))
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let point = normalized(recognizer.location(in: self))
        let now = CACurrentMediaTime()

        switch recognizer.state {
        case .began:
            lastDragPoint = point
            lastDragTime = now
            onDragBegan?(point)

        case .changed:
            let deltaTime = Float(max(now - lastDragTime, 1.0 / 240.0))
            onDragChanged?(point, point - lastDragPoint, deltaTime)
            lastDragPoint = point
            lastDragTime = now

        case .ended, .cancelled, .failed:
            onDragEnded?()

        default:
            break
        }
    }
}
