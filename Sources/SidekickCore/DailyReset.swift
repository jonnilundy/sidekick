import Foundation

/// The session resets once a day at a set hour (5 AM by default), so each day starts clean.
public enum DailyReset {
    /// True when the reset hour has passed since `start`. A session started at 4:59 resets at 5:00;
    /// one started at 5:01 lasts until 5:00 the next day.
    public static func isDue(sessionStart start: Date, now: Date = Date(), hour: Int = 5, calendar: Calendar = .current) -> Bool {
        guard let boundary = nextBoundary(after: start, hour: hour, calendar: calendar) else { return false }
        return now >= boundary
    }

    /// The first moment at `hour`:00 strictly after `date`.
    public static func nextBoundary(after date: Date, hour: Int = 5, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, second: 0), matchingPolicy: .nextTime)
    }
}
