import Foundation

/// The pull at the bottom of the card: drag down to show earlier turns, up to tuck them away.
/// The card follows the pointer with rubber banding, and a flick counts by where it would land.
public enum HistoryDrag {
    /// How far the pull must land (after the flick projection) to open or close.
    public static let threshold: Double = 44

    /// Apple's rubber band: the further past the edge, the less the card follows.
    public static func rubberband(_ offset: Double, dimension: Double = 300, constant: Double = 0.55) -> Double {
        let sign: Double = offset < 0 ? -1 : 1
        let distance = abs(offset)
        return sign * (distance * dimension * constant) / (dimension + constant * distance)
    }

    /// Where a flick would come to rest, the way scrolling decelerates. Velocity in points per second.
    public static func project(velocity: Double, decelerationRate: Double = 0.998) -> Double {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    public enum Outcome: Equatable, Sendable { case open, close, stay }

    /// Decides at release. Down past the threshold opens the history; up past it closes it.
    public static func outcome(translation: Double, velocity: Double, isOpen: Bool) -> Outcome {
        // The snappier rate: the scroll rate (0.998) throws a gentle pull on a small handle too far.
        let landing = translation + project(velocity: velocity, decelerationRate: 0.99)
        if !isOpen && landing > threshold { return .open }
        if isOpen && landing < -threshold { return .close }
        return .stay
    }
}

/// When the panel opens after a quiet spell, it shows only the empty field. The session stays.
public enum IdleCollapse {
    public static let defaultAfter: TimeInterval = 3 * 60

    public static func isDue(lastActivity: Date?, now: Date = Date(), after: TimeInterval = defaultAfter) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= after
    }
}
