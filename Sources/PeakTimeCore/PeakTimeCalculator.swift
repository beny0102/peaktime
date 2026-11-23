import Foundation

public enum PriceZone: String, Sendable {
    case cheap = "Barato"
    case peak = "Doble"
}

public struct PriceStatus: Sendable {
    public let zone: PriceZone
    public let nextChange: Date?
    public let nextZone: PriceZone?
    public let isChineseHoliday: Bool
}

/// A segment of the menu timeline. Its on-screen width is proportional to `duration`.
public struct TimelineSegment: Sendable, Equatable {
    public let zone: PriceZone
    public let duration: TimeInterval

    public init(zone: PriceZone, duration: TimeInterval) {
        self.zone = zone
        self.duration = duration
    }
}

/// Pricing rules for the DeepSeek API.
///
/// Official docs: peak = 01:00–04:00 and 06:00–10:00 UTC, Monday to Friday,
/// excluding Chinese public holidays. Everything else (weekends and Chinese holidays) is off-peak.
///
/// Pricing is always evaluated in UTC, because that is DeepSeek's rule
/// and does not depend on the user's location. Only the presentation helpers convert
/// to the Mac's time zone (`autoupdatingCurrent`), so displayed times
/// adapt automatically to the user's country and to daylight saving changes.
/// Beijing is used separately because Chinese holidays are defined by Beijing calendar dates.
public enum PeakTimeCalculator {
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    // MARK: - Base rule

    private static func isPeakUTC(_ date: Date) -> Bool {
        let components = calendar(utc).dateComponents([.weekday, .hour], from: date)
        guard let weekday = components.weekday, let hour = components.hour else { return false }
        // weekday: 1 = Sunday ... 7 = Saturday
        guard (2...6).contains(weekday) else { return false }
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    public static func isChineseHoliday(_ date: Date) -> Bool {
        let components = calendar(beijing).dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return false
        }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        return ChineseHolidays.dates.contains(key)
    }

    public static func zone(at date: Date) -> PriceZone {
        if isChineseHoliday(date) { return .cheap }
        return isPeakUTC(date) ? .peak : .cheap
    }

    public static func status(at date: Date) -> PriceStatus {
        let next = transitions(after: date).first
        return PriceStatus(
            zone: zone(at: date),
            nextChange: next?.date,
            nextZone: next?.zone,
            isChineseHoliday: isChineseHoliday(date)
        )
    }

    // MARK: - Transitions

    /// Upcoming zone changes. Checks the UTC boundaries of the peak windows (01, 04, 06, 10)
    /// and Beijing midnight (16:00 UTC), where a holiday can change the price.
    public static func transitions(after date: Date, days: Int = 14) -> [(date: Date, zone: PriceZone)] {
        let cal = calendar(utc)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year, let month = comps.month, let day = comps.day,
              let base = cal.date(from: DateComponents(year: year, month: month, day: day)) else {
            return []
        }

        var results: [(date: Date, zone: PriceZone)] = []
        for offset in -1..<days {
            guard let dayDate = cal.date(byAdding: .day, value: offset, to: base) else { continue }
            let dc = cal.dateComponents([.year, .month, .day], from: dayDate)
            guard let y = dc.year, let m = dc.month, let d = dc.day else { continue }
            for hour in [1, 4, 6, 10, 16] {
                guard let moment = cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour)),
                      moment > date else { continue }
                let before = zone(at: moment.addingTimeInterval(-1))
                let after = zone(at: moment)
                if before != after {
                    results.append((moment, after))
                }
            }
        }
        return results.sorted { $0.date < $1.date }
    }

    public static func nextPeakStart(after date: Date) -> Date? {
        transitions(after: date).first(where: { $0.zone == .peak })?.date
    }

    /// Timeline for the menu: pricing periods from `date` to `date + horizon`.
    /// The window is anchored at "now", so green shrinks and orange grows as
    /// a peak approaches (and the reverse during a peak). Consecutive segments
    /// of the same color are merged. Durations always add up to `horizon`.
    public static func timelineSegments(
        at date: Date,
        horizon: TimeInterval = 8 * 3600
    ) -> [TimelineSegment] {
        guard horizon > 0 else { return [] }

        let end = date.addingTimeInterval(horizon)
        var segments: [TimelineSegment] = []
        var cursor = date
        var currentZone = zone(at: date)

        func append(_ zone: PriceZone, _ duration: TimeInterval) {
            guard duration > 0 else { return }
            if let last = segments.indices.last, segments[last].zone == zone {
                segments[last] = TimelineSegment(zone: zone, duration: segments[last].duration + duration)
            } else {
                segments.append(TimelineSegment(zone: zone, duration: duration))
            }
        }

        for transition in transitions(after: date) where transition.date < end {
            append(currentZone, transition.date.timeIntervalSince(cursor))
            cursor = transition.date
            currentZone = transition.zone
        }
        append(currentZone, end.timeIntervalSince(cursor))
        return segments
    }

    /// Countdown text used both in the menu bar and in the menu.
    public static func countdownText(from now: Date, to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Peak windows in local time, derived from the real next peak (not a fixed table).
    /// Windows last 3 h, start 5 h later, and the second ends 9 h after the first starts.
    public static func localPeakWindows(
        after date: Date,
        in timeZone: TimeZone = .autoupdatingCurrent
    ) -> (first: String, second: String)? {
        guard let start = nextPeakStart(after: date) else { return nil }
        let fmt = { (offset: TimeInterval) in localTime(start.addingTimeInterval(offset), in: timeZone) }
        return (first: "\(fmt(0))–\(fmt(3 * 3600))",
                second: "\(fmt(5 * 3600))–\(fmt(9 * 3600))")
    }

    // MARK: - Presentation in the Mac's time zone

    /// By default it uses the current system zone; `autoupdatingCurrent` also reflects
    /// zone changes while the app is running. The parameter allows injecting
    /// a specific zone in tests.
    public static func localTime(_ date: Date, in timeZone: TimeZone = .autoupdatingCurrent) -> String {
        formatter("HH:mm", timeZone: timeZone).string(from: date)
    }

    /// Full date in the system language. `locale` is injectable for tests.
    public static func localFull(
        _ date: Date,
        in timeZone: TimeZone = .autoupdatingCurrent,
        locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime
            .weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }
}
