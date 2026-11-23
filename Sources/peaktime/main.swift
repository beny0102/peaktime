import Foundation
import AppKit
import UserNotifications
import OSLog
import PeakTimeCore

private let notificationLog = Logger(subsystem: "com.local.peaktime", category: "notifications")
private let appLog = Logger(subsystem: "com.local.peaktime", category: "app")

/// Strings from the catalog (Localizable.xcstrings). Pick the `.lproj` based on the
/// system language so it does not depend on the resource bundle's
/// `CFBundleDevelopmentRegion`; a language change takes effect after relaunch.
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

// MARK: - Notifications shown while the app is in the foreground

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Model: live state, timer, and notifications

private final class PeakTimeModel {
    private(set) var now: Date = Date()
    private(set) var status: PriceStatus = PeakTimeCalculator.status(at: Date())

    private let notificationCenter = UNUserNotificationCenter.current()
    // `delegate` is weak: keep a strong reference or it is deallocated when init() returns.
    private let notificationDelegate = NotificationDelegate()
    private let realStart = Date()
    private let simulationStart: Date? = {
        guard let value = ProcessInfo.processInfo.environment["PEAKTIME_SIMULATE"] else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }()

    /// For a quick test: PEAKTIME_SIMULATE=2026-11-22T17:29:00Z open dist/peaktime.app
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

        // Avoid a spurious notification on launch when the clock is simulated.
        let start = simulatedNow
        now = start
        status = PeakTimeCalculator.status(at: start)

        refresh()
        // The AppDelegate drives the one-second refresh; only initialize state here.
        // If the system time zone changes (travel or automatic adjustment), repaint immediately.
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

    // MARK: Menu bar and menu text

    /// Icon selected by the user from the comparison sheet.
    /// Rendered as a native template: macOS paints it in black and white,
    /// like the other menu bar icons.
    var iconName: String {
        status.zone == .peak
            ? "chart.line.uptrend.xyaxis.circle.fill"
            : "tag.circle.fill"
    }

    var countdownText: String {
        guard let change = status.nextChange else { return "—" }
        return PeakTimeCalculator.countdownText(from: now, to: change)
    }

    /// Primary menu row: short countdown to the next change.
    var countdownLeadText: String {
        guard status.nextChange != nil else { return L10n.string("Sin cambios próximos") }
        let destination = status.nextZone == .peak
            ? L10n.string("hora pico")
            : L10n.string("descuento")
        return L10n.format("%@ para %@", countdownText, destination)
    }

    /// Timeline segments derived from the live state.
    var timelineSegments: [TimelineSegment] {
        PeakTimeCalculator.timelineSegments(at: now)
    }

    /// Local time when the next pricing period starts.
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

    // MARK: Notification engine

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
        notificationLog.info("Notification sent: \(title, privacy: .public) — \(body, privacy: .public)")
        notificationCenter.add(request)
    }
}

// MARK: - UI (pure AppKit)

/// Menu metrics. Apple HIG: align elements along the leading edge,
/// group related items with a separator, and use the standard spacing
/// system (multiples of 8 pt). Here 4 pt on each side of every item gives
/// 8 pt between components, with the same 20 pt horizontal inset everywhere.
private enum MenuLayout {
    static let width: CGFloat = 260
    static let horizontalInset: CGFloat = 20
    static let verticalPadding: CGFloat = 4
    static let countdownRowHeight: CGFloat = 26   // 18 pt of text + 4 + 4
    static let barRowHeight: CGFloat = 28         // 20 pt of bar + 4 + 4
    static let startRowHeight: CGFloat = 24       // 16 pt of text + 4 + 4
}

/// The bar is drawn as a native NSView inside an NSMenuItem. SwiftUI drops
/// custom views in a MenuBarExtra menu; AppKit respects the item's `view`
/// and its frame, so it is always visible here.
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

        // Faint track + border give the bar body without adding menu items.
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

/// Container with internal padding: NSMenuItem repositions the view it is given, so
/// setting the margin on the NSTextField's `frame.x` does not work. The text goes
/// inside this NSView and keeps its x even when the menu moves the container.
/// Vertical `padding` centers the text in the row and leaves 8 pt between components.
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
        fatalError("init(coder:) is not used")
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
        appLog.info("AppKit delegate started")
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
        // `.common` includes `.eventTracking`: without it the timer freezes while
        // the menu is open, because AppKit changes the run loop mode.
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
        // Native template symbol: macOS applies the monochrome appearance
        // of the system (black in light, white in dark) and scales without clipping.
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image = NSImage(systemSymbolName: model.iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button?.image = image
        // The user wants only the icon in the menu bar; the text lives in the menu.
        button?.title = ""

        countdownBox.text = model.countdownLeadText
        barView.segments = model.timelineSegments
        startBox.text = model.nextStartText
    }
}

// Explicit startup: with @main on an NSApplicationDelegate and no nib, AppKit
// never calls applicationDidFinishLaunching. We do it here.
let application = NSApplication.shared
let delegate = PeakTimeAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
