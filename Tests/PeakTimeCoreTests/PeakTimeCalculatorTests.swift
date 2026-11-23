import XCTest
import PeakTimeCore

final class PeakTimeCalculatorTests: XCTestCase {
    private func tijuana(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Tijuana")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - User's table (winter time, UTC−8)

    func testSaturdayAfternoonIsCheap() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 21, 17, 15)), .cheap)
    }

    func testSundayBeforePeakIsCheap() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 22, 16, 30)), .cheap)
    }

    func testSundayPeakStartsAt17() {
        // Sunday 17:00 Tijuana = Monday 01:00 UTC
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 22, 17, 30)), .peak)
    }

    func testMondayEveningIsPeakAndLateEveningIsCheap() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 23, 19, 0)), .peak)
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 23, 21, 0)), .cheap)
    }

    func testFridayEarlyMorningIsPeakThenCheapAt2AM() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 20, 1, 0)), .peak)
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 20, 3, 0)), .cheap)
    }

    // MARK: - Daylight saving time (UTC−7)

    func testSummerWindowShiftsOneHour() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 7, 20, 17, 30)), .cheap)
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 7, 20, 18, 30)), .peak)
    }

    // MARK: - Chinese holidays

    func testChineseHolidayOverridesPeak() {
        // 1 Oct 2026 is National Day: in Beijing it is already 2 Oct morning, a holiday.
        XCTAssertTrue(PeakTimeCalculator.isChineseHoliday(tijuana(2026, 10, 1, 19, 0)))
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 10, 1, 19, 0)), .cheap)

        // 17 Feb 2026 is Chinese New Year.
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 2, 17, 19, 0)), .cheap)
    }

    func testOrdinaryWeekdayIsNotHoliday() {
        XCTAssertFalse(PeakTimeCalculator.isChineseHoliday(tijuana(2026, 11, 23, 19, 0)))
    }

    // MARK: - Upcoming changes

    func testNextTransitionOutOfPeak() {
        let status = PeakTimeCalculator.status(at: tijuana(2026, 11, 22, 17, 30))
        XCTAssertEqual(status.zone, .peak)
        XCTAssertEqual(status.nextZone, .cheap)
        XCTAssertEqual(status.nextChange, tijuana(2026, 11, 22, 20, 0))
    }

    func testNextTransitionFromCheapWeekend() {
        let status = PeakTimeCalculator.status(at: tijuana(2026, 11, 21, 10, 0))
        XCTAssertEqual(status.zone, .cheap)
        XCTAssertEqual(status.nextZone, .peak)
        XCTAssertEqual(status.nextChange, tijuana(2026, 11, 22, 17, 0))
        XCTAssertEqual(PeakTimeCalculator.nextPeakStart(after: tijuana(2026, 11, 21, 10, 0)),
                       tijuana(2026, 11, 22, 17, 0))
    }

    func testHolidayHasNoPeakAheadUntilHolidayEnds() {
        // 1 Oct 2026 (holiday). On the night of 2 Oct it is already Saturday in UTC → off-peak.
        // 5–7 Oct are still holidays, so the first real peak is
        // Wednesday 7 Oct at 18:00 in Tijuana (Thursday 8 Oct 01:00 UTC).
        let peak = PeakTimeCalculator.nextPeakStart(after: tijuana(2026, 10, 1, 19, 0))
        XCTAssertNotNil(peak)
        XCTAssertEqual(peak, tijuana(2026, 10, 7, 18, 0))
    }

    // MARK: - UTC rule vs. local presentation

    /// The decision is made on the UTC instant, not on the local "wall clock" time.
    func testRuleIsEvaluatedInUTC() {
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
        func utc(_ hour: Int, _ minute: Int = 0) -> Date {
            utcCal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: hour, minute: minute))!
        }
        XCTAssertEqual(PeakTimeCalculator.zone(at: utc(1)), .peak)
        XCTAssertEqual(PeakTimeCalculator.zone(at: utc(4, 30)), .cheap)
        XCTAssertEqual(PeakTimeCalculator.zone(at: utc(6)), .peak)
        XCTAssertEqual(PeakTimeCalculator.zone(at: utc(10)), .cheap)
        // That same 01:00 UTC instant is Sunday 17:00 in Tijuana.
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 22, 17, 0)), .peak)
    }

    func testDisplayConvertsToRequestedTimeZone() {
        // 2026-11-23 01:00 UTC, real start of a peak window.
        let instant = tijuana(2026, 11, 22, 17, 0)
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(secondsFromGMT: 0)!), "01:00")
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(identifier: "America/Tijuana")!), "17:00")
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(identifier: "America/New_York")!), "20:00")
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(identifier: "Asia/Shanghai")!), "09:00")
    }

    /// The menu date follows the system language, not a fixed English locale.
    func testLocalFullUsesRequestedLocale() {
        let instant = tijuana(2026, 11, 22, 17, 0)
        let tz = TimeZone(identifier: "America/Tijuana")!

        let spanish = PeakTimeCalculator.localFull(instant, in: tz, locale: Locale(identifier: "es_ES"))
        XCTAssertTrue(spanish.contains("dom"))
        XCTAssertTrue(spanish.contains("nov"))
        XCTAssertTrue(spanish.contains("17:00"))

        let english = PeakTimeCalculator.localFull(instant, in: tz, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(english.contains("Sun"))
        XCTAssertTrue(english.contains("Nov"))
        XCTAssertTrue(english.contains("5:00"))
    }

    /// Menu windows are not a fixed table: they are derived from the real peak and
    /// converted to the requested time zone, changing with DST and with the user's country.
    func testLocalPeakWindowsAdaptToTimeZone() {
        let tj = TimeZone(identifier: "America/Tijuana")!
        let ny = TimeZone(identifier: "America/New_York")!

        let winter = PeakTimeCalculator.localPeakWindows(
            after: tijuana(2026, 11, 21, 10, 0), in: tj
        )
        XCTAssertEqual(winter?.first, "17:00–20:00")
        XCTAssertEqual(winter?.second, "22:00–02:00")

        let summer = PeakTimeCalculator.localPeakWindows(
            after: tijuana(2026, 7, 18, 10, 0), in: tj
        )
        XCTAssertEqual(summer?.first, "18:00–21:00")
        XCTAssertEqual(summer?.second, "23:00–03:00")

        let newYork = PeakTimeCalculator.localPeakWindows(
            after: tijuana(2026, 11, 21, 10, 0), in: ny
        )
        XCTAssertEqual(newYork?.first, "20:00–23:00")
        XCTAssertEqual(newYork?.second, "01:00–05:00")
    }

    // MARK: - Menu timeline

    func testTimelineIsAllGreenWhenNextPeakIsFar() {
        // Saturday 10:00 Tijuana: the next peak is Sunday 17:00 (31 h later).
        let after = tijuana(2026, 11, 21, 10, 0)
        let segments = PeakTimeCalculator.timelineSegments(at: after)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].zone, .cheap)
        XCTAssertEqual(segments[0].duration, 8 * 3600, accuracy: 1)
    }

    func testTimelineSplitsGreenAndOrangeAroundPeaks() {
        // Sunday 15:00 Tijuana = 23:00 UTC. Both night peaks fit into 8 h.
        let after = tijuana(2026, 11, 22, 15, 0)
        let segments = PeakTimeCalculator.timelineSegments(at: after)
        XCTAssertEqual(segments.map(\.zone), [.cheap, .peak, .cheap, .peak])
        XCTAssertEqual(segments[0].duration, 2 * 3600, accuracy: 1)
        XCTAssertEqual(segments[1].duration, 3 * 3600, accuracy: 1)
        XCTAssertEqual(segments[2].duration, 2 * 3600, accuracy: 1)
        XCTAssertEqual(segments[3].duration, 1 * 3600, accuracy: 1)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.duration }, 8 * 3600, accuracy: 1)
    }

    func testTimelineDuringPeakStartsWithOrange() {
        // Sunday 19:00 Tijuana = Monday 03:00 UTC: 1 h of peak remains.
        let after = tijuana(2026, 11, 22, 19, 0)
        let segments = PeakTimeCalculator.timelineSegments(at: after)
        XCTAssertEqual(segments.map(\.zone), [.peak, .cheap, .peak, .cheap])
        XCTAssertEqual(segments[0].duration, 1 * 3600, accuracy: 1)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.duration }, 8 * 3600, accuracy: 1)
    }

    func testChineseHolidayTimelineIsAllGreen() {
        let after = tijuana(2026, 10, 1, 19, 0)
        let segments = PeakTimeCalculator.timelineSegments(at: after)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].zone, .cheap)
    }

    func testCountdownText() {
        let from = tijuana(2026, 11, 22, 15, 0)
        XCTAssertEqual(PeakTimeCalculator.countdownText(from: from, to: tijuana(2026, 11, 22, 17, 0)), "2h 0m")
        XCTAssertEqual(PeakTimeCalculator.countdownText(from: from, to: from.addingTimeInterval(95)), "1m")
    }
}
