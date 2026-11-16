import AppKit
import QuartzCore
import SwiftUI

/// Motion curves from the Osmo vault in Rook (the studio's design library), so Recopy moves like
/// the studio's other work instead of with the system's plain ease-in-out.
enum Easing: Hashable, Sendable {
    /// CSS cubic-bezier(x1, y1, x2, y2).
    case cubic(Double, Double, Double, Double)
    /// CSS linear() stops, evenly spaced from start to end.
    case stops([Double])

    /// "Osmo" (vault #223): holds its breath, then a fast move into a long, soft settle.
    static let osmo = Easing.cubic(0.625, 0.05, 0, 1)

    /// "Bouncy" (vault #1446): a spring that overshoots by about 8% and settles.
    static let bouncy = Easing.stops([
        0, 0.0933, 0.1849, 0.2746, 0.3618, 0.446, 0.5267, 0.6032, 0.6749, 0.7412, 0.8018, 0.8561, 0.904,
        0.9453, 0.9803, 1.0092, 1.0323, 1.0501, 1.0632, 1.072, 1.0771, 1.0789, 1.0779, 1.0744, 1.0688,
        1.0615, 1.0526, 1.0424, 1.0317, 1.0213, 1.0114, 1.0025, 0.9954, 0.9914, 0.9915, 0.9952, 1.0008,
        1.007, 1.0124, 1.0145, 1.0143, 1.0127, 1.0102, 1.0073, 1.0042, 1.0013, 0.9989, 0.9973, 0.9967,
        0.9975, 1,
    ])

    /// Progress along the curve at `time` (0...1).
    func callAsFunction(_ time: Double) -> Double {
        let time = min(max(time, 0), 1)
        switch self {
        case .cubic(let x1, let y1, let x2, let y2):
            return Self.bezier(time, x1, y1, x2, y2)
        case .stops(let stops):
            let position = time * Double(stops.count - 1)
            let index = min(Int(position), stops.count - 2)
            let fraction = position - Double(index)
            return stops[index] + (stops[index + 1] - stops[index]) * fraction
        }
    }

    /// The curve's y where its x is `x`, solved the way browsers do (Newton's method, then
    /// bisection if that doesn't settle).
    private static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
        let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
        func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
        func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
        func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-7 { return sampleY(t) }
            let slope = slopeX(t)
            if abs(slope) < 1e-7 { break }
            t -= error / slope
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<40 {
            let value = sampleX(t)
            if abs(value - x) < 1e-7 { break }
            if x > value { low = t } else { high = t }
            t = (low + high) / 2
        }
        return sampleY(t)
    }
}

/// A SwiftUI animation along a vault curve.
struct EasedAnimation: CustomAnimation {
    let easing: Easing
    let duration: TimeInterval

    func animate<V: VectorArithmetic>(value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? {
        guard time < duration else { return nil }
        return value.scaled(by: easing(time / duration))
    }
}

extension Animation {
    static func eased(_ easing: Easing, duration: TimeInterval) -> Animation {
        Animation(EasedAnimation(easing: easing, duration: duration))
    }
}

/// Runs a step on every frame of the display (120 a second on ProMotion screens) for a set time,
/// passing how far along the curve it is. AppKit's own window animations only take simple
/// curves, and none that overshoot.
@MainActor
final class FrameMotion: NSObject {
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var duration: TimeInterval = 1
    private var easing = Easing.osmo
    private var step: ((Double) -> Void)?
    private var completion: (() -> Void)?

    func run(in view: NSView, duration: TimeInterval, easing: Easing,
             step: @escaping (Double) -> Void, completion: (() -> Void)? = nil) {
        cancel()
        self.duration = duration
        self.easing = easing
        self.step = step
        self.completion = completion
        startTime = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        step(easing(0))
    }

    func cancel() {
        link?.invalidate()
        link = nil
        step = nil
        completion = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let time = min((CACurrentMediaTime() - startTime) / duration, 1)
        step?(easing(time))
        if time >= 1 {
            let done = completion
            cancel()
            done?()
        }
    }
}

extension NSRect {
    /// Part of the way to another rect (past it, for curves that overshoot).
    func interpolated(to other: NSRect, _ progress: CGFloat) -> NSRect {
        NSRect(x: minX + (other.minX - minX) * progress,
               y: minY + (other.minY - minY) * progress,
               width: width + (other.width - width) * progress,
               height: height + (other.height - height) * progress)
    }
}
