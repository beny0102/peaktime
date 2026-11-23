import SwiftUI
import AppKit
import UserNotifications
import OSLog
import PeakTimeCore

private let notificationLog = Logger(subsystem: "com.local.peaktime", category: "avisos")
private let appLog = Logger(subsystem: "com.local.peaktime", category: "app")

/// Cadenas del catálogo (Localizable.xcstrings). Elegimos el `.lproj` según el
/// idioma del sistema para que no dependa del `CFBundleDevelopmentRegion` del
/// bundle de recursos; si el usuario cambia de idioma, se aplica al relanzar.
private enum L10n {
    private static var bundle: Bundle {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let preferred = code == "es" ? "es" : "en"
        if let path = Bundle.module.path(forResource: preferred, ofType: "lproj"),
           let localized = Bundle(path: path) {
            return localized
        }
        return .module
    }

    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: string(key), arguments: args)
    }
}

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

    /// Icono elegido por el usuario en la lámina comparativa.
    var iconName: String {
        status.zone == .peak
            ? "chart.line.uptrend.xyaxis.circle.fill"
            : "tag.circle.fill"
    }

    var iconColor: NSColor {
        status.zone == .peak ? .systemOrange : .systemGreen
    }

    var countdownText: String {
        guard let change = status.nextChange else { return "—" }
        return PeakTimeCalculator.countdownText(from: now, to: change)
    }

    /// Fila protagonista del menú: cuenta atrás corta hacia el siguiente cambio.
    var countdownLeadText: String {
        guard status.nextChange != nil else { return L10n.string("Sin cambios próximos") }
        let destination = status.nextZone == .peak
            ? L10n.string("hora pico")
            : L10n.string("descuento")
        return L10n.format("%@ para %@", countdownText, destination)
    }

    /// Segmentos de la línea de tiempo, derivados del estado en vivo.
    var timelineSegments: [TimelineSegment] {
        PeakTimeCalculator.timelineSegments(at: now)
    }

    /// Hora local en que empieza el siguiente tramo de precio.
    var nextStartText: String {
        guard let change = status.nextChange else { return "—" }
        return L10n.format("Empieza: %@", PeakTimeCalculator.localFull(change))
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
                title: L10n.string("📈 Precio doble en DeepSeek"),
                body: L10n.format("Ahora pagas el doble. Vuelve a la mitad a las %@.", peakEndText)
            )
        case (.peak, .cheap):
            notify(
                title: L10n.string("📉 Mitad de precio en DeepSeek"),
                body: L10n.format("Sigue barato hasta las %@.", nextChangeLocal)
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
                    title: L10n.string("⏰ DeepSeek sube en 15 min"),
                    body: L10n.format(
                        "El precio doble empieza a las %@.",
                        PeakTimeCalculator.localTime(change)
                    )
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
        notificationLog.info("Aviso enviado: \(title, privacy: .public) — \(body, privacy: .public)")
        notificationCenter.add(request)
    }
}

// MARK: - Interfaz (AppKit puro)

/// Métricas del menú. HIG de Apple: alinear los elementos por el borde leading,
/// agrupar los relacionados con un separador y usar el sistema de espaciado
/// estándar (múltiplos de 8 pt). Aquí 4 pt a cada lado de cada contenido dan
/// 8 pt entre componentes, con el mismo inset horizontal de 20 pt en todos.
private enum MenuLayout {
    static let width: CGFloat = 260
    static let horizontalInset: CGFloat = 20
    static let verticalPadding: CGFloat = 4
    static let countdownRowHeight: CGFloat = 26   // 18 de texto + 4 + 4
    static let barRowHeight: CGFloat = 28         // 20 de barra + 4 + 4
    static let startRowHeight: CGFloat = 24       // 16 de texto + 4 + 4
}

/// La barra se dibuja como NSView nativa dentro de un NSMenuItem. SwiftUI descarta
/// las vistas personalizadas en el menú de MenuBarExtra; AppKit respeta el `view`
/// del item y su frame, así que aquí siempre se ve.
private final class TimelineNSView: NSView {
    var segments: [TimelineSegment] = [] {
        didSet { setNeedsDisplay(bounds) }
    }

    private let sideInset: CGFloat = MenuLayout.horizontalInset
    private let barHeight: CGFloat = 10

    override var intrinsicContentSize: NSSize {
        NSSize(width: MenuLayout.width, height: MenuLayout.barRowHeight)
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

/// Contenedor con padding interno: NSMenuItem reubica la vista que le das, así que
/// poner el margen en el `frame.x` del NSTextField no sirve. Aquí el texto va
/// dentro de este NSView y conserva su x aunque el menú mueva el contenedor.
/// El `padding` vertical centra el texto en la fila y deja 8 pt entre componentes.
private final class PaddedLabelView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let inset: CGFloat = MenuLayout.horizontalInset
    private let padding: CGFloat = MenuLayout.verticalPadding

    init(height: CGFloat, font: NSFont, color: NSColor) {
        super.init(frame: NSRect(x: 0, y: 0, width: MenuLayout.width, height: height))
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.font = font
        label.textColor = color
        label.frame = NSRect(
            x: inset,
            y: padding,
            width: MenuLayout.width - 2 * inset,
            height: height - 2 * padding
        )
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no usado")
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: MenuLayout.width, height: frame.height)
    }
}

final class PeakTimeAppDelegate: NSObject, NSApplicationDelegate {
    private let model = PeakTimeModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let countdownItem = NSMenuItem()
    private let startItem = NSMenuItem()
    private let barView = TimelineNSView()

    private let countdownBox = PaddedLabelView(
        height: MenuLayout.countdownRowHeight,
        font: .systemFont(ofSize: 12, weight: .semibold),
        color: .labelColor
    )
    private let startBox = PaddedLabelView(
        height: MenuLayout.startRowHeight,
        font: .systemFont(ofSize: 11),
        color: .secondaryLabelColor
    )

    private var uiTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog.info("AppKit delegate arrancó")
        let menu = NSMenu()
        menu.autoenablesItems = false

        countdownItem.isEnabled = false
        countdownItem.view = countdownBox

        startItem.isEnabled = false
        startItem.view = startBox

        let barItem = NSMenuItem()
        barItem.isEnabled = false
        barView.frame = NSRect(x: 0, y: 0, width: MenuLayout.width, height: MenuLayout.barRowHeight)
        barItem.view = barView

        menu.addItem(countdownItem)
        menu.addItem(barItem)
        menu.addItem(startItem)
        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: L10n.string("Salir"), action: #selector(quitApp), keyEquivalent: "q")
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

    /// SF Symbol teñido con el color de la zona, tal como se vio en la lámina.
    private func statusImage() -> NSImage? {
        let size: CGFloat = 18
        guard let base = NSImage(systemSymbolName: model.iconName, accessibilityDescription: nil)
        else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let symbol = base.withSymbolConfiguration(config) ?? base

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        model.iconColor.setFill()
        rect.fill()
        symbol.draw(in: rect, from: rect, operation: .destinationIn, fraction: 1)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func updateUI() {
        let button = statusItem.button
        button?.image = statusImage()
        // El usuario quiere solo el icono en la barra superior; el texto vive en el menú.
        button?.title = ""

        countdownBox.text = model.countdownLeadText
        barView.segments = model.timelineSegments
        startBox.text = model.nextStartText
    }
}

// Arranque explícito: con @main sobre un NSApplicationDelegate y sin nib, AppKit
// no llega a llamar a applicationDidFinishLaunching. Aquí sí lo hacemos.
let application = NSApplication.shared
let delegate = PeakTimeAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
