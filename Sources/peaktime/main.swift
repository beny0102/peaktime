import SwiftUI
import UserNotifications
import OSLog
import PeakTimeCore

private let notificationLog = Logger(subsystem: "com.local.peaktime", category: "avisos")

// MARK: - Notificaciones visibles con la app en primer plano

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Modelo: estado en vivo, temporizador y avisos

private final class PeakTimeModel: ObservableObject {
    @Published private(set) var now: Date = Date()
    @Published private(set) var status: PriceStatus = PeakTimeCalculator.status(at: Date())

    private let notificationCenter = UNUserNotificationCenter.current()
    // `delegate` es weak: hay que conservar una referencia fuerte o se desasigna al salir de init().
    private let notificationDelegate = NotificationDelegate()
    private let realStart = Date()
    private let simulationStart: Date? = {
        guard let value = ProcessInfo.processInfo.environment["PEAKTIME_SIMULATE"] else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }()
    private var timer: Timer?

    /// Para probar sin esperar: PEAKTIME_SIMULATE=2026-11-22T17:29:00Z open dist/peaktime.app
    private var simulatedNow: Date {
        if let simulationStart {
            return simulationStart.addingTimeInterval(Date().timeIntervalSince(realStart))
        }
        return Date()
    }

    private var lastNotifiedKey: String? {
        get { UserDefaults.standard.string(forKey: "peaktime.lastNotified") }
        set { UserDefaults.standard.set(newValue, forKey: "peaktime.lastNotified") }
    }

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Evita un aviso espurio al arrancar si el reloj va simulado.
        let start = simulatedNow
        now = start
        status = PeakTimeCalculator.status(at: start)

        refresh()
        // 1 s para que la cuenta atrás y el borde de la barra se muevan de verdad.
        // Las notificaciones tienen dedup por clave, así que no se repiten.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Si el sistema cambia de huso (viaje o ajuste automático), repintamos al instante.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemTimeZoneDidChange),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func systemTimeZoneDidChange() {
        refresh()
    }

    // MARK: Textos de la barra y del menú

    var iconName: String {
        status.zone == .peak ? "exclamationmark.triangle.fill" : "dollarsign.circle.fill"
    }

    var titleText: String {
        "\(status.zone.rawValue) · \(countdownText)"
    }

    var countdownText: String {
        guard let change = status.nextChange else { return "—" }
        return PeakTimeCalculator.countdownText(from: now, to: change)
    }

    /// Fila protagonista del menú: cuenta atrás hacia el siguiente cambio de precio.
    var countdownLeadText: String {
        guard status.nextChange != nil else { return "Sin cambios próximos" }
        let destination = status.nextZone == .peak ? "precio doble" : "mitad de precio"
        return "Faltan \(countdownText) para \(destination)"
    }

    /// Segmentos de la línea de tiempo, derivados del estado en vivo.
    var timelineSegments: [TimelineSegment] {
        PeakTimeCalculator.timelineSegments(at: now)
    }

    var detailLine: String {
        if status.isChineseHoliday {
            return "Festivo chino: todo el día a mitad de precio"
        }
        return status.zone == .peak
            ? "Pagas el doble en la API de DeepSeek"
            : "API de DeepSeek a mitad de precio"
    }

    var nextChangeText: String {
        guard let change = status.nextChange else { return "—" }
        let destination = status.nextZone?.rawValue ?? "?"
        return "\(PeakTimeCalculator.localFull(change)) → \(destination)"
    }

    var nextPeakText: String {
        guard let peak = PeakTimeCalculator.nextPeakStart(after: now) else { return "—" }
        return PeakTimeCalculator.localFull(peak)
    }

    var peakEndText: String {
        guard let end = PeakTimeCalculator.transitions(after: now).first(where: { $0.zone == .cheap })?.date else {
            return "—"
        }
        return PeakTimeCalculator.localTime(end)
    }

    /// Franjas dobles en la hora local de la Mac. Se derivan del próximo pico real,
    /// así que respetan el DST vigente y el huso del usuario sin tablas hardcodeadas.
    var localWindowsText: String {
        let zoneName = TimeZone.autoupdatingCurrent.abbreviation() ?? "hora local"
        guard let windows = PeakTimeCalculator.localPeakWindows(after: now) else {
            return "Dobles: 01:00–04:00 y 06:00–10:00 UTC (lun–vie)"
        }
        return "Dobles (\(zoneName)): \(windows.first) y \(windows.second)"
    }

    // MARK: Motor de avisos

    func refresh() {
        let current = simulatedNow
        let newStatus = PeakTimeCalculator.status(at: current)
        let previousZone = status.zone

        now = current
        status = newStatus

        switch (previousZone, newStatus.zone) {
        case (.cheap, .peak):
            notify(
                title: "⚠️ Precio doble en DeepSeek",
                body: "Ahora pagas el doble. Vuelve a la mitad a las \(peakEndText)."
            )
        case (.peak, .cheap):
            notify(
                title: "✅ Mitad de precio en DeepSeek",
                body: "Sigue barato hasta las \(nextChangeLocal)."
            )
        default:
            break
        }

        if newStatus.zone == .cheap, let change = newStatus.nextChange {
            let key = "pre-\(Int(change.timeIntervalSince1970))"
            let remaining = change.timeIntervalSince(current)
            if remaining > 0, remaining <= 15 * 60, lastNotifiedKey != key {
                lastNotifiedKey = key
                notify(
                    title: "⏰ DeepSeek sube en 15 min",
                    body: "El precio doble empieza a las \(PeakTimeCalculator.localTime(change))."
                )
            }
        }
    }

    private var nextChangeLocal: String {
        guard let change = status.nextChange else { return "—" }
        return PeakTimeCalculator.localTime(change)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        notificationLog.info("Aviso enviado: \(title) — \(body)")
        notificationCenter.add(request)
    }
}

// MARK: - Interfaz

private extension PriceZone {
    var timelineColor: Color {
        switch self {
        case .cheap: return .green
        case .peak: return .orange
        }
    }
}

private struct TimelineLegend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
    }
}

/// Una sola línea con el precio actual y el venidero. Cada bloque es proporcional
/// a su duración dentro de la ventana de 8 h que empieza en "ahora".
private struct TimelineBar: View {
    let segments: [TimelineSegment]
    private let width: CGFloat = 220
    private let height: CGFloat = 10

    private var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    segment.zone.timelineColor
                        .frame(width: totalDuration > 0
                               ? width * CGFloat(segment.duration / totalDuration)
                               : 0)
                }
            }
            .frame(width: width, height: height, alignment: .leading)
            .clipShape(Capsule())

            HStack(spacing: 12) {
                TimelineLegend(color: .green, text: "Mitad de precio")
                TimelineLegend(color: .orange, text: "Doble")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .animation(.linear(duration: 0.5), value: segments)
    }
}

@main
struct PeakTimeApp: App {
    @StateObject private var model = PeakTimeModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.status.zone == .peak ? "⚠️ Precio doble" : "💰 Mitad de precio")
                .font(.headline)
            Text(model.detailLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.status.isChineseHoliday {
                Text("Festivo chino")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(model.countdownLeadText)
                .font(.headline)
                .monospacedDigit()
                .padding(.top, 2)
            TimelineBar(segments: model.timelineSegments)
            Divider()
            Text("Próximo cambio: \(model.nextChangeText)")
            Text("Siguiente doble: \(model.nextPeakText)")
            Divider()
            Text(model.localWindowsText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
            Button("Salir") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label(model.titleText, systemImage: model.iconName)
        }
    }
}
