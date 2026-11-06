import AppKit
import NetFeesCore

final class UniFiView: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    private let model: UniFiModel
    private var history = false
    private var historyPeriod = UniFiPeriod.day
    private let historyPeriods: [UniFiPeriod] = [.day, .week, .month]
    private let site = DashboardStyle.label(size: 12, weight: .semibold)
    private let period = NSPopUpButton()
    private let refreshButton = NSButton()
    private let bill = DashboardCard()
    private let heading = DashboardStyle.label(size: 10, weight: .bold, color: .secondaryLabelColor)
    private let cost = DashboardStyle.label(size: 42, weight: .light, monospaced: true)
    private let tariff = DashboardStyle.label(size: 11, color: .secondaryLabelColor, monospaced: true)
    private let downloads = TrafficCard(title: "↓  Site downloads", color: DashboardStyle.accent)
    private let uploads = TrafficCard(title: "↑  Site uploads", color: .systemTeal)
    private let coverage = DashboardStyle.label(size: 10, color: .secondaryLabelColor)
    private let clientsTitle = DashboardStyle.label("CLIENT DEVICES", size: 9, weight: .bold, color: .secondaryLabelColor)
    private let costTitle = DashboardStyle.label("DOWNLOAD COST", size: 8, weight: .medium, color: .secondaryLabelColor)
    private let scope = DashboardStyle.label(size: 10, color: .secondaryLabelColor)
    private let empty = DashboardStyle.label(size: 11, color: .secondaryLabelColor)
    private let state = DashboardStyle.label(size: 9, color: .secondaryLabelColor)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var clients: [UniFiClientUsage] = []

    init(model: UniFiModel) {
        self.model = model
        super.init(frame: .zero)
        [site, period, refreshButton, bill, downloads, uploads, coverage, clientsTitle, costTitle, scope, scroll, empty, state].forEach { addSubview($0) }
        [heading, cost, tariff].forEach { bill.addSubview($0) }
        period.addItems(withTitles: historyPeriods.map(\.title))
        period.target = self
        period.action = #selector(changePeriod)
        period.setAccessibilityLabel("UniFi history period")
        period.isHidden = true
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh UniFi statistics")
        refreshButton.imagePosition = .imageOnly
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatistics)
        refreshButton.toolTip = "Refresh UniFi statistics"
        for field in [coverage, scope, empty] { field.maximumNumberOfLines = 2; field.lineBreakMode = .byWordWrapping }
        costTitle.alignment = .right
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("usage"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 49
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("UniFi clients, highest download cost first")
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
    }

    required init?(coder: NSCoder) { nil }

    func setHistory(_ history: Bool) {
        self.history = history
        period.isHidden = !history
        model.select(history ? historyPeriod : .today)
    }

    func refresh() {
        site.stringValue = model.configuration?.site.displayName ?? "UniFi"
        site.toolTip = site.stringValue
        period.selectItem(at: historyPeriods.firstIndex(of: historyPeriod) ?? 0)
        refreshButton.isEnabled = !model.isRefreshing
        heading.stringValue = history ? "SITE DOWNLOAD COST" : "TODAY'S SITE DOWNLOAD COST"
        if let report = model.report {
            cost.stringValue = Display.euros(report.fee, precise: true)
            tariff.stringValue = "↓ \(Display.bytes(report.traffic.received)) × €0.055 / GB"
            downloads.update(bytes: report.traffic.received, rate: history ? nil : model.rate?.received)
            uploads.update(bytes: report.traffic.sent, rate: history ? nil : model.rate?.sent)
            let start = report.buckets.first!.start.formatted(date: history ? .abbreviated : .omitted, time: .shortened)
            let end = report.buckets.last!.end.formatted(date: history ? .abbreviated : .omitted, time: .shortened)
            let partial = report.coveredSeconds + 1 < report.window.duration ? " · partial coverage" : ""
            coverage.stringValue = model.error ?? "WAN usage: \(start) to \(end)\(partial)\n\(TimeZone.current.identifier)\(history ? " · completed intervals" : " · current interval still updating")"
            coverage.textColor = model.error == nil ? .secondaryLabelColor : .systemOrange
        } else {
            cost.stringValue = model.isRefreshing ? "Loading…" : "Unavailable"
            tariff.stringValue = "€0.055 / GB of site downloads"
            coverage.stringValue = model.error ?? "Waiting for controller-reported WAN usage."
            coverage.textColor = model.error == nil ? .secondaryLabelColor : .systemOrange
        }
        downloads.isHidden = model.report == nil
        uploads.isHidden = model.report == nil
        let updated = model.clientsReport?.clients ?? []
        let changed = clients.map(\.id) != updated.map(\.id)
        clients = updated
        if changed {
            let origin = scroll.contentView.bounds.origin
            table.reloadData()
            scroll.contentView.scroll(to: origin)
        }
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
            for row in visible.location..<NSMaxRange(visible) where clients.indices.contains(row) {
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? UsageRowView { configure(cell, row: row) }
            }
        }
        scope.stringValue = model.clientsReport?.includesLAN == false
            ? "Internet traffic attributed to each client by UniFi."
            : "Client traffic includes LAN. These costs do not add up to the WAN bill."
        scope.toolTip = "Legacy client history uses the device's last known wired or wireless connection to interpret download direction. Devices that change connection type may have mixed counters."
        empty.stringValue = model.clientsError ?? (model.isRefreshing ? "Reading client history…" : "No client history is available for this period.")
        empty.isHidden = !clients.isEmpty
        let old = model.report.map { Date().timeIntervalSince($0.fetchedAt) > max(180, Double(model.refreshInterval) * 3) } ?? true
        let cached = model.error != nil || old || (!history && model.isTodayStale)
        state.stringValue = model.clientsError != nil && !clients.isEmpty ? "Cached client history · \(model.clientsError!)"
            : "\(cached ? "Cached usage" : "Refresh every \(model.refreshInterval) s") · usage follows controller reporting"
        state.textColor = cached || model.clientsError != nil ? .systemOrange : .secondaryLabelColor
        state.toolTip = state.stringValue
        needsLayout = true
    }

    private func configure(_ cell: UsageRowView, row: Int) {
        let usage = clients[row]
        let station = model.stations[usage.id]
        let rate = !history && model.hasCurrentStations ? station?.rate : nil
        let connection = !model.hasCurrentStations ? "Cached" : station?.online == true ? (station?.wired == true ? "Wired" : "Wi-Fi") : "Offline"
        cell.update(name: station?.name ?? usage.id,
            detail: "↓ \(Display.bytes(usage.report.traffic.received)) · ↑ \(Display.bytes(usage.report.traffic.sent))",
            amount: Display.applicationEuros(usage.fee),
            secondary: rate.map { "↓ \(Display.bytes($0.received))/s · ↑ \(Display.bytes($0.sent))/s" } ?? connection,
            icon: NSImage(systemSymbolName: station?.wired == true ? "desktopcomputer" : "wifi", accessibilityDescription: connection),
            help: "\(station?.name ?? usage.id) · \(connection)\n\(usage.id)\n\(model.period.title): download cost at €0.055/GB")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { clients.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("usage"), owner: self) as? UsageRowView ?? UsageRowView(frame: .zero)
        configure(cell, row: row)
        return cell
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        site.frame = NSRect(x: 3, y: 3, width: history ? width - 210 : width - 36, height: 20)
        period.frame = NSRect(x: width - 198, y: 0, width: 164, height: 26)
        refreshButton.frame = NSRect(x: width - 27, y: 1, width: 24, height: 24)
        bill.frame = NSRect(x: 0, y: 36, width: width, height: 114)
        heading.frame = NSRect(x: 14, y: 13, width: width - 28, height: 14)
        cost.frame = NSRect(x: 14, y: 31, width: width - 28, height: 52)
        tariff.frame = NSRect(x: 14, y: 91, width: width - 28, height: 16)
        downloads.frame = NSRect(x: 0, y: 162, width: (width - 12) / 2, height: 80)
        uploads.frame = NSRect(x: (width + 12) / 2, y: 162, width: (width - 12) / 2, height: 80)
        coverage.frame = NSRect(x: 3, y: 253, width: width - 6, height: 32)
        clientsTitle.frame = NSRect(x: 3, y: 300, width: 210, height: 14)
        costTitle.frame = NSRect(x: width - 120, y: 300, width: 117, height: 14)
        scope.frame = NSRect(x: 3, y: 318, width: width - 6, height: 30)
        scroll.frame = NSRect(x: 0, y: 354, width: width, height: max(0, bounds.height - 376))
        empty.frame = NSRect(x: 3, y: 366, width: width - 6, height: 50)
        state.frame = NSRect(x: 3, y: bounds.height - 14, width: width - 6, height: 14)
        table.frame.size.width = scroll.contentSize.width
        table.tableColumns[0].width = scroll.contentSize.width
    }

    @objc private func changePeriod() {
        historyPeriod = historyPeriods[period.indexOfSelectedItem]
        model.select(historyPeriod)
    }
    @objc private func refreshStatistics() { model.refresh(force: true) }
}
