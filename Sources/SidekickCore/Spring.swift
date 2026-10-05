import Foundation

/// A damped spring in Apple's terms: `response` is roughly the time to reach the target in seconds,
/// `damping` is the damping ratio (1 = no overshoot, below 1 = bounce). Retargeting keeps the current
/// value and velocity, so every motion can be interrupted and reversed without a jump.
public struct Spring: Equatable, Sendable {
    public var response: Double
    public var damping: Double

    public init(response: Double, damping: Double) {
        self.response = response
        self.damping = damping
    }

    /// The panel arriving from the edge: quick, with a hint of bounce. It opens from a hotkey many
    /// times a day, so it settles in about 0.4 s.
    public static let arrive = Spring(response: 0.30, damping: 0.86)
    /// The panel leaving: faster than it came, no overshoot.
    public static let leave = Spring(response: 0.22, damping: 1)
    /// Height changes while an answer streams in.
    public static let grow = Spring(response: 0.32, damping: 1)
    /// Opacity, always critically damped.
    public static let fade = Spring(response: 0.2, damping: 1)

    var stiffness: Double { pow(2 * .pi / response, 2) }
    var friction: Double { 4 * .pi * damping / response }
}

/// One animated value driven by a `Spring`. Call `step` once per display frame.
public struct SpringValue: Equatable, Sendable {
    public var value: Double
    public var velocity: Double = 0
    public var target: Double
    public var spring: Spring

    public init(_ value: Double, spring: Spring) {
        self.value = value
        self.target = value
        self.spring = spring
    }

    public var isSettled: Bool { abs(value - target) < 0.05 && abs(velocity) < 0.5 }

    /// Advances by `dt` seconds. Sub-steps keep it stable when a frame is late.
    public mutating func step(_ dt: Double) {
        guard !isSettled else { value = target; velocity = 0; return }
        let steps = max(1, Int((min(dt, 0.1) / (1.0 / 240)).rounded(.up)))
        let h = min(dt, 0.1) / Double(steps)
        for _ in 0..<steps {
            let force = -spring.stiffness * (value - target) - spring.friction * velocity
            velocity += force * h
            value += velocity * h
        }
        if isSettled { value = target; velocity = 0 }
    }

    /// Jumps to the target with no motion.
    public mutating func snap(to target: Double) {
        self.target = target
        value = target
        velocity = 0
    }
}
