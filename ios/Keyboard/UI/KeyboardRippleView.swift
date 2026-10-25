import UIKit
import ChirpIOSCore

/// The Pond Ripple for the keyboard strip: three koi rings scaling 1 → 1.8 while their opacity goes 0.5 → 0, staggered by
/// a third. A Core Animation port of `ChirpIOSCore.Ripple` (same geometry and tempo, `Ripple.period(level:)`): the
/// keyboard extension has a small memory and CPU budget, and layer animations run on the render server instead of
/// redrawing a SwiftUI `Canvas` every frame inside the extension. Reduce Motion shows one static koi ring.
///
/// The bridge carries no input level (the microphone lives in the app), so the tempo is a calm fixed one.
final class KeyboardRippleView: UIView {
    static let level = 0.35
    private let rings = (0..<3).map { _ in CAShapeLayer() }
    private let still = CAShapeLayer()
    private var running = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        for ring in rings {
            ring.fillColor = nil
            ring.opacity = 0
            layer.addSublayer(ring)
        }
        still.fillColor = nil
        layer.addSublayer(still)
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Starts or stops the animation; a stopped ripple is invisible.
    func setActive(_ active: Bool) {
        running = active
        restart()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // The outermost ring (scale 1.8) just fits the box.
        let base = side / 1.8
        let line = max(side / 12, 1.2)
        for ring in rings {
            ring.frame = bounds
            ring.path = UIBezierPath(arcCenter: center, radius: base / 2, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
            ring.lineWidth = line
        }
        let stillInset = side * 0.14
        let stillLine = max(side / 14, 1.2) + side / 8 * Self.level
        still.frame = bounds
        still.path = UIBezierPath(arcCenter: center, radius: (side - stillInset * 2 - stillLine) / 2, startAngle: 0,
                                  endAngle: .pi * 2, clockwise: true).cgPath
        still.lineWidth = stillLine
        updateColors()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateColors()
    }

    private func updateColors() {
        for ring in rings { ring.strokeColor = KeyboardPalette.koiDecor.resolvedColor(with: traitCollection).cgColor }
        still.strokeColor = KeyboardPalette.koi.resolvedColor(with: traitCollection).cgColor
    }

    @objc private func motionChanged() { restart() }

    @objc private func restart() {
        for ring in rings { ring.removeAllAnimations(); ring.opacity = 0 }
        still.isHidden = true
        guard running, window != nil else { return }
        if UIAccessibility.isReduceMotionEnabled { still.isHidden = false; return }
        let period = Ripple.period(level: Self.level)
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        for (index, ring) in rings.enumerated() {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1; scale.toValue = 1.8
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.5; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = period
            group.repeatCount = .infinity
            group.timeOffset = 0
            group.beginTime = now - period * Double(index) / 3
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "ripple")
        }
    }
}
