import XCTest
import PeakTimeCore

final class PeakTimeCalculatorTests: XCTestCase {
    private func tijuana(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Tijuana")!
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Tabla del usuario (horario de invierno, UTC−8)

    func testSaturdayAfternoonIsCheap() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 21, 17, 15)), .cheap)
    }

    func testSundayBeforePeakIsCheap() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 22, 16, 30)), .cheap)
    }

    func testSundayPeakStartsAt17() {
        // Domingo 17:00 Tijuana = lunes 01:00 UTC
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

    // MARK: - Horario de verano (UTC−7)

    func testSummerWindowShiftsOneHour() {
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 7, 20, 17, 30)), .cheap)
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 7, 20, 18, 30)), .peak)
    }

    // MARK: - Festivos chinos

    func testChineseHolidayOverridesPeak() {
        // 1 oct 2026 es Día Nacional: en Pekín es 2 oct por la mañana, festivo.
        XCTAssertTrue(PeakTimeCalculator.isChineseHoliday(tijuana(2026, 10, 1, 19, 0)))
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 10, 1, 19, 0)), .cheap)

        // 17 feb 2026 es Año Nuevo Chino.
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 2, 17, 19, 0)), .cheap)
    }

    func testOrdinaryWeekdayIsNotHoliday() {
        XCTAssertFalse(PeakTimeCalculator.isChineseHoliday(tijuana(2026, 11, 23, 19, 0)))
    }

    // MARK: - Próximos cambios

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
        // 1 oct 2026 (festivo). El 2 oct por la noche ya es sábado en UTC → off-peak.
        // Del 5 al 7 oct sigue siendo festivo, así que el primer pico real es
        // miércoles 7 oct a las 18:00 en Tijuana (jueves 8 oct 01:00 UTC).
        let peak = PeakTimeCalculator.nextPeakStart(after: tijuana(2026, 10, 1, 19, 0))
        XCTAssertNotNil(peak)
        XCTAssertEqual(peak, tijuana(2026, 10, 7, 18, 0))
    }

    // MARK: - Regla UTC vs. presentación local

    /// La decisión se toma sobre el instante en UTC, no sobre la hora "de pared" local.
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
        // Ese mismo instante de las 01:00 UTC es domingo 17:00 en Tijuana.
        XCTAssertEqual(PeakTimeCalculator.zone(at: tijuana(2026, 11, 22, 17, 0)), .peak)
    }

    func testDisplayConvertsToRequestedTimeZone() {
        // 2026-11-23 01:00 UTC, inicio real de una franja doble.
        let instant = tijuana(2026, 11, 22, 17, 0)
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(secondsFromGMT: 0)!), "01:00")
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(identifier: "America/Tijuana")!), "17:00")
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(identifier: "America/New_York")!), "20:00")
        XCTAssertEqual(PeakTimeCalculator.localTime(instant, in: TimeZone(identifier: "Asia/Shanghai")!), "09:00")
    }

    /// Las franjas del menú no son una tabla fija: se derivan del pico real y se
    /// convierten al huso que se pida, cambiando con el DST y con el país del usuario.
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
}
