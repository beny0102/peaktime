import SwiftUI
import AppKit
import UserNotifications
import OSLog
import PeakTimeCore

private let notificationLog = Logger(subsystem: "com.local.peaktime", category: "avisos")
private let appLog = Logger(subsystem: "com.local.peaktime", category: "app")

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
        // El AppDelegate impulsa el refresco cada segundo; aquí solo se inicializa el estado.
        // Si el sistema cambia de huso (viaje o ajuste automático), repintamos al instante.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(systemTimeZoneDidChange),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func systemTimeZoneDidChange() {
        refresh()
    }

    // MARK: Textos de la barra y del menú

    var iconName: String {
        status.zone == .peak ? "exclamationmark.triangle.fill" : "dollarsign.circle.fill"
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

// MARK: - Interfaz (AppKit puro)

/// La barra se dibuja como NSView nativa dentro de un NSMenuItem. SwiftUI descarta
/// las vistas personalizadas en el menú de MenuBarExtra; AppKit respeta el `view`
/// del item y su frame, así que aquí siempre se ve.
private final class TimelineNSView: NSView {
    var segments: [TimelineSegment] = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    private let sideInset: CGFloat = 16
    private let barHeight: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        NSSize(width: 260, height: 20)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let total = segments.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return }

        let rect = NSRect(
            x: sideInset,
            y: (bounds.height - barHeight) / 2,
            width: max(0, bounds.width - 2 * sideInset),
            height: barHeight
        )
        let capsule = NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2)

        // Pista tenue + borde: dan cuerpo a la barra sin añadir elementos al menú.
        NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
        capsule.fill()
        capsule.lineWidth = 1
        NSColor.separatorColor.setStroke()
        capsule.stroke()

        NSGraphicsContext.saveGraphicsState()
        capsule.addClip()

        var x = rect.minX
        for segment in segments {
            let w = rect.width * CGFloat(segment.duration / total)
            let slice = NSRect(x: x, y: rect.minY, width: max(0, w - 1), height: rect.height)
            let color: NSColor = segment.zone == .peak ? .systemOrange : .systemGreen
            color.setFill()
            NSBezierPath(rect: slice).fill()
            x += w
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class PeakTimeAppDelegate: NSObject, NSApplicationDelegate {
    private let model = PeakTimeModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let countdownItem = NSMenuItem()
    private let startItem = NSMenuItem()
    private let barView = TimelineNSView()

    private let countdownLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.font = .boldSystemFont(ofSize: 13)
        label.textColor = .labelColor
        return label
    }()

    private let startLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }()

    private var uiTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog.info("AppKit delegate arrancó")
        let menu = NSMenu()
        menu.autoenablesItems = false

        countdownItem.isEnabled = false
        countdownLabel.frame = NSRect(x: 16, y: 0, width: 244, height: 18)
        countdownItem.view = countdownLabel

        startItem.isEnabled = false
        startLabel.frame = NSRect(x: 16, y: 0, width: 244, height: 16)
        startItem.view = startLabel

        let barItem = NSMenuItem()
        barItem.isEnabled = false
        barView.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        barItem.view = barView

        menu.addItem(countdownItem)
        menu.addItem(barItem)
        menu.addItem(startItem)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Salir", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu

        updateUI()
        // `.common` incluye `.eventTracking`: sin esto el timer se congela mientras
        // el menú está abierto, porque AppKit cambia el modo del run loop.
        uiTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(uiTimer!, forMode: .common)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(timeZoneChanged),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
    }

    deinit {
        uiTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func timeZoneChanged() {
        tick()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func tick() {
        model.refresh()
        updateUI()
    }

    private func updateUI() {
        let button = statusItem.button
        let image = NSImage(systemSymbolName: model.iconName, accessibilityDescription: nil)
        image?.size = NSSize(width: 18, height: 18)
        button?.image = image
        // El usuario quiere solo el icono en la barra superior; el texto vive en el menú.
        button?.title = ""

        countdownLabel.stringValue = model.countdownLeadText
        countdownLabel.setNeedsDisplay()
        barView.segments = model.timelineSegments
        startLabel.stringValue = model.nextStartText
        startLabel.setNeedsDisplay()
    }
}

// Arranque explícito: con @main sobre un NSApplicationDelegate y sin nib, AppKit
// no llega a llamar a applicationDidFinishLaunching. Aquí sí lo hacemos.
let application = NSApplication.shared
let delegate = PeakTimeAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
