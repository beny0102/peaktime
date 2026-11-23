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

/// Un tramo de la línea de tiempo del menú. Su ancho en pantalla es proporcional a `duration`.
public struct TimelineSegment: Sendable, Equatable {
    public let zone: PriceZone
    public let duration: TimeInterval

    public init(zone: PriceZone, duration: TimeInterval) {
        self.zone = zone
        self.duration = duration
    }
}

/// Reglas de precio de la API de DeepSeek.
///
/// Documentación oficial: peak = 01:00–04:00 y 06:00–10:00 UTC, lunes a viernes,
/// excluyendo festivos chinos. Todo lo demás (fines de semana y festivos chinos) es off-peak.
///
/// La decisión de precio se evalúa SIEMPRE en UTC, porque esa es la regla de DeepSeek
/// y no depende de dónde esté el usuario. Solo las funciones de presentación convierten
/// al huso horario de la Mac (`autoupdatingCurrent`), así que los horarios mostrados se
/// adaptan automáticamente al país del usuario y a los cambios de horario/DST.
/// Pekín se usa aparte porque los festivos chinos se definen en fecha de Beijing.
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

    // MARK: - Regla base

    private static func isPeakUTC(_ date: Date) -> Bool {
        let components = calendar(utc).dateComponents([.weekday, .hour], from: date)
        guard let weekday = components.weekday, let hour = components.hour else { return false }
        // weekday: 1 = domingo ... 7 = sábado
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

    // MARK: - Transiciones

    /// Próximos cambios de zona. Se revisan los límites UTC de las franjas (01, 04, 06, 10)
    /// y la medianoche de Pekín (16:00 UTC), que es donde un festivo puede cambiar el precio.
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

    /// Línea de tiempo para el menú: tramos de precio desde `date` hasta `date + horizon`.
    /// La ventana se ancla en "ahora", así que el verde se acorta y el naranja crece a medida
    /// que se acerca un pico (y al revés cuando ya estamos en pico). Los tramos consecutivos
    /// del mismo color se fusionan. La suma de duraciones es siempre `horizon`.
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

    /// Texto de cuenta atrás usado tanto en la barra superior como en el menú.
    public static func countdownText(from now: Date, to date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Franjas dobles en hora local, derivadas del próximo pico real (no de una tabla fija).
    /// Las franjas duran 3 h, empiezan 5 h después y la segunda termina a las 9 h del inicio.
    public static func localPeakWindows(
        after date: Date,
        in timeZone: TimeZone = .autoupdatingCurrent
    ) -> (first: String, second: String)? {
        guard let start = nextPeakStart(after: date) else { return nil }
        let fmt = { (offset: TimeInterval) in localTime(start.addingTimeInterval(offset), in: timeZone) }
        return (first: "\(fmt(0))–\(fmt(3 * 3600))",
                second: "\(fmt(5 * 3600))–\(fmt(9 * 3600))")
    }

    // MARK: - Presentación en el huso horario de la Mac

    /// Por defecto usa el huso actual del sistema; `autoupdatingCurrent` también refleja
    /// cambios de zona mientras la app sigue abierta. El parámetro permite inyectar
    /// una zona concreta en los tests.
    public static func localTime(_ date: Date, in timeZone: TimeZone = .autoupdatingCurrent) -> String {
        formatter("HH:mm", timeZone: timeZone).string(from: date)
    }

    public static func localFull(_ date: Date, in timeZone: TimeZone = .autoupdatingCurrent) -> String {
        formatter("EEE d MMM HH:mm", timeZone: timeZone).string(from: date)
    }
}
