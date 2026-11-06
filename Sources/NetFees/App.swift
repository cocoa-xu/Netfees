import AppKit

@main
struct NetFeesApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class MeterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let dashboardSize = NSSize(width: 440, height: 680)
    private let glassInset: CGFloat = 2
    private var statusItem: NSStatusItem!
    private var panel: MeterPanel!
    private var model: UsageModel!
    private var dashboard: DashboardView!
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "moe.uwucocoa.Netfees"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        #if DEBUG
        let directory = ProcessInfo.processInfo.environment["NETFEES_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        model = UsageModel(directory: directory)
        #else
        model = UsageModel()
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.setAccessibilityLabel("NetFees: today's download and network cost")
        }
        createPanel()
        model.onUpdate = { [weak self] in
            guard let self else { return }
            self.updateStatus()
            if self.panel.isVisible { self.dashboard.refresh() }
        }
        model.start()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.keyCode == 53, event.window === self.panel {
                    self.panel.orderOut(nil)
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.prepareForSleep() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.wake() }
        })
        if CommandLine.arguments.contains("--show") || model.pendingInitialImport != nil { togglePanel() }
    }

    private func createPanel() {
        let panelSize = NSSize(width: dashboardSize.width + glassInset * 2,
                               height: dashboardSize.height + glassInset * 2)
        panel = MeterPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.title = "NetFees"
        dashboard = DashboardView(model: model)
        let host = dashboard!
        host.frame = NSRect(origin: .zero, size: dashboardSize)
        host.autoresizingMask = [.width, .height]
        let surface = NSView(frame: NSRect(origin: .zero, size: panelSize))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 28 + glassInset
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        let glassFrame = host.frame.offsetBy(dx: glassInset, dy: glassInset)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: glassFrame)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.cornerRadius = 28
            glass.contentView = host
            surface.addSubview(glass)
        } else {
            let visual = NSVisualEffectView(frame: glassFrame)
            visual.autoresizingMask = [.width, .height]
            visual.material = .hudWindow
            visual.blendingMode = .behindWindow
            visual.state = .active
            visual.wantsLayer = true
            visual.layer?.cornerRadius = 28
            visual.layer?.masksToBounds = true
            visual.addSubview(host)
            surface.addSubview(visual)
        }
        panel.contentView = surface
        panel.invalidateShadow()
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        if model.unifi.showsInMenuBar {
            let report = model.unifi.todayReport
            let cached = report != nil && model.unifi.isTodayStale
            let download = report.map { Display.bytes($0.traffic.received) } ?? "UniFi"
            let fee = report.map { Display.euros($0.fee, precise: true) } ?? "N/A"
            button.image = MenuBarReadout.image(download: cached ? "\(download)*" : download, fee: fee)
            statusItem.length = max(60, (button.image?.size.width ?? 0) + 16)
            let state = cached ? "Cached" : report == nil ? "Unavailable" : "Today"
            let label = "UniFi: \(state), \(download), \(fee)"
            button.setAccessibilityLabel("NetFees: UniFi downloads and network cost")
            button.setAccessibilityValue(label)
            button.toolTip = "\(model.unifi.configuration?.site.displayName ?? "UniFi") · \(label)\nWAN downloads at €0.055/GB · \(TimeZone.current.identifier)\n\(model.unifi.todayError ?? "Controller-reported usage; the current interval may still be updating.")"
            return
        }
        let download = Display.bytes(model.today.downloadBytes)
        let fee = Display.euros(model.today.fee, precise: true)
        button.image = MenuBarReadout.image(download: download, fee: fee)
        statusItem.length = max(60, (button.image?.size.width ?? 0) + 16)
        button.setAccessibilityLabel("NetFees: this Mac's downloads and network cost")
        button.setAccessibilityValue("\(download), \(fee) today")
        button.toolTip = "Today: ↓ \(Display.bytes(model.today.downloadBytes)) · ↑ \(Display.bytes(model.today.uploadBytes)) · \(Display.euros(model.today.fee, precise: true)) at €0.055/GB"
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, panel != nil { togglePanel() }
        return true
    }

    @objc private func togglePanel() {
        guard !panel.isVisible else { panel.orderOut(nil); return }
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main!
        let visible = screen.visibleFrame
        let x = max(visible.minX + 8, min(anchor.midX - panel.frame.width / 2, visible.maxX - panel.frame.width - 8))
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 8, anchor.minY - panel.frame.height - 8)))
        dashboard.openDefaultSource()
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
