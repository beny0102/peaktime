import SwiftUI
import AppKit
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

    /// Hora local en que empieza el siguiente tramo de precio.
    var nextStartText: String {
        guard let change = status.nextChange else { return "—" }
        return "Empieza: \(PeakTimeCalculator.localFull(change))"
    }

    var peakEndText: String {
        guard let end = PeakTimeCalculator.transitions(after: now).first(where: { $0.zone == .cheap })?.date else {
            return "—"
        }
        return PeakTimeCalculator.localTime(end)
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

/// La barra se dibuja como NSView nativa: dentro de un menú, las vistas SwiftUI
/// basadas en `Color` + `clipShape` no siempre se dibujan. Aquí el tamaño es
/// intrínseco y el dibujo es explícito, así que siempre se ve.
private final class TimelineNSView: NSView {
    var segments: [TimelineSegment] = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    private let barWidth: CGFloat = 240
    private let barHeight: CGFloat = 12

    override var intrinsicContentSize: NSSize {
        NSSize(width: barWidth, height: barHeight + 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let total = segments.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return }

        let rect = NSRect(
            x: (bounds.width - barWidth) / 2,
            y: (bounds.height - barHeight) / 2,
            width: barWidth,
            height: barHeight
        )
        NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).addClip()

        var x = rect.minX
        for segment in segments {
            let w = rect.width * CGFloat(segment.duration / total)
            let slice = NSRect(x: x, y: rect.minY, width: w, height: rect.height)
            let color: NSColor = segment.zone == .peak ? .systemOrange : .systemGreen
            color.setFill()
            NSBezierPath(rect: slice).fill()
            x += w
        }
    }
}

private struct TimelineBar: NSViewRepresentable {
    let segments: [TimelineSegment]

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView()
        view.segments = segments
        return view
    }

    func updateNSView(_ nsView: TimelineNSView, context: Context) {
        nsView.segments = segments
    }
}

@main
struct PeakTimeApp: App {
    @StateObject private var model = PeakTimeModel()

    var body: some Scene {
        MenuBarExtra {
            Text(model.countdownLeadText)
                .font(.headline)
                .monospacedDigit()
            TimelineBar(segments: model.timelineSegments)
            Text(model.nextStartText)
                .font(.caption)
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
