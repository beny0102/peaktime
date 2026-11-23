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
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
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
        let seconds = Int(max(0, change.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
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
