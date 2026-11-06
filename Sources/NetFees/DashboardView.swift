import AppKit
import NetFeesCore

final class DashboardView: FlippedView, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class HistoryItem: NSObject {
        let key: String
        var day: DailyRecord?
        var application: ApplicationUsageRow?
        var imported: InitialTrafficImport?
        var children: [HistoryItem] = []
        init(key: String) { self.key = key }
    }

    private let model: UsageModel
    private let logo = NSImageView()
    private let title = DashboardStyle.label("netfees", size: 24, weight: .heavy)
    private let subtitle = DashboardStyle.label("Every byte accounted for.", size: 10.5, color: .secondaryLabelColor)
    private let info = NSButton()
    private let tabs = NSSegmentedControl(labels: ["Today", "History"], trackingMode: .selectOne, target: nil, action: nil)
    private let todayPage = FlippedView()
    private let historyPage = FlippedView()
    private let importPage = DashboardCard()
    private let unifiPage: UniFiView
    private var unifiPreferences: UniFiPreferences?
    private let bill = DashboardCard()
    private let billTitle = DashboardStyle.label("TODAY'S NETWORK COST", size: 10, weight: .bold, color: .secondaryLabelColor)
    private let fee = DashboardStyle.label(size: 42, weight: .light, monospaced: true)
    private let tariff = DashboardStyle.label(size: 11, color: .secondaryLabelColor, monospaced: true)
    private let download = TrafficCard(title: "↓  Downloaded", color: DashboardStyle.accent)
    private let upload = TrafficCard(title: "↑  Uploaded", color: .systemTeal)
    private let weekTitle = DashboardStyle.label("THE LAST 7 DAYS", size: 9, weight: .bold, color: .secondaryLabelColor)
    private let weekTotal = DashboardStyle.label(size: 11, weight: .semibold, color: .secondaryLabelColor, monospaced: true)
    private let chart = WeekChartView()
    private let appsTitle = DashboardStyle.label("APPLICATIONS TODAY", size: 9, weight: .bold, color: .secondaryLabelColor)
    private let appsCostTitle = DashboardStyle.label("DOWNLOAD COST", size: 8, weight: .medium, color: .secondaryLabelColor)
    private let appsStatus = DashboardStyle.label(size: 9, color: .secondaryLabelColor)
    private let appsEmpty = DashboardStyle.label("Application traffic will appear as it is measured.", size: 11, color: .secondaryLabelColor)
    private let appsTable = NSTableView()
    private let appsScroll = NSScrollView()
    private var applications: [ApplicationUsageRow] = []
    private let historyTitle = DashboardStyle.label("THE RUNNING TAB", size: 9, weight: .bold, color: .secondaryLabelColor)
    private let historyTotal = DashboardStyle.label(size: 40, weight: .light, monospaced: true)
    private let export = NSButton(title: "Export…", target: nil, action: nil)
    private let historyHeading = DashboardStyle.label("DAY / APPLICATION", size: 8, weight: .bold, color: .secondaryLabelColor)
    private let historyCostTitle = DashboardStyle.label("EUR", size: 8, weight: .bold, color: .secondaryLabelColor)
    private let historyTable = NSOutlineView()
    private let historyScroll = NSScrollView()
    private let historyZone = DashboardStyle.label(size: 10, color: .secondaryLabelColor)
    private var history: [HistoryItem] = []
    private var historyItems: [String: HistoryItem] = [:]
    private var historyStructure: [String] = []
    private let importAmount = DashboardStyle.label(size: 42, weight: .light, monospaced: true)
    private let importDownload = DashboardStyle.label(size: 12, monospaced: true)
    private let importUpload = DashboardStyle.label(size: 12, monospaced: true)
    private let error = DashboardStyle.label(size: 10, color: .systemOrange)
    private let separator = NSBox()
    private let statusDot = DashboardStyle.label("●", size: 8, color: .systemGreen)
    private let status = DashboardStyle.label(size: 10, color: .secondaryLabelColor)
    private let settings = NSButton()
    private let about = NSPopover()

    init(model: UsageModel) {
        self.model = model
        unifiPage = UniFiView(model: model.unifi)
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 680))
        [logo, title, subtitle, info, tabs, todayPage, historyPage, importPage, unifiPage, error, separator, statusDot, status, settings].forEach { addSubview($0) }
        logo.image = NSImage(named: NSImage.applicationIconName)
        logo.imageScaling = .scaleProportionallyUpOrDown
        configureSymbol(info, symbol: "info.circle", label: "About NetFees", action: #selector(showAbout))
        configureSymbol(settings, symbol: "slider.horizontal.3", label: "Settings and export", action: #selector(showSettings))
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(changePage)
        tabs.setAccessibilityLabel("View")
        separator.boxType = .separator
        error.maximumNumberOfLines = 2
        error.lineBreakMode = .byWordWrapping
        weekTotal.alignment = .right
        appsCostTitle.alignment = .right
        historyCostTitle.alignment = .right
        [bill, download, upload, weekTitle, weekTotal, chart, appsTitle, appsCostTitle, appsStatus, appsScroll, appsEmpty].forEach { todayPage.addSubview($0) }
        [billTitle, fee, tariff].forEach { bill.addSubview($0) }
        [historyTitle, historyTotal, export, historyHeading, historyCostTitle, historyScroll, historyZone].forEach { historyPage.addSubview($0) }
        configureButton(export, action: #selector(exportHistory))
        setupTable(appsTable, scroll: appsScroll)
        appsTable.dataSource = self
        appsTable.delegate = self
        appsTable.setAccessibilityLabel("Applications today, highest download cost first")
        setupTable(historyTable, scroll: historyScroll)
        historyTable.outlineTableColumn = historyTable.tableColumns[0]
        historyTable.indentationPerLevel = 14
        historyTable.dataSource = self
        historyTable.delegate = self
        historyTable.setAccessibilityLabel("Daily usage history, expand a day to see applications")
        setupImport()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let count = model.unifi.isEnabled ? 3 : 2
        if tabs.segmentCount != count {
            let selection = min(tabs.selectedSegment, count - 1)
            tabs.segmentCount = count
            for (index, label) in ["Today", "History", "UniFi"].prefix(count).enumerated() { tabs.setLabel(label, forSegment: index) }
            tabs.selectedSegment = max(0, selection)
        }
        let imported = model.pendingInitialImport
        tabs.isHidden = imported != nil
        importPage.isHidden = imported == nil
        todayPage.isHidden = imported != nil || tabs.selectedSegment != 0
        historyPage.isHidden = imported != nil || tabs.selectedSegment != 1
        unifiPage.isHidden = imported != nil || tabs.selectedSegment != 2
        error.stringValue = model.error ?? ""
        error.isHidden = model.error == nil || tabs.selectedSegment == 2
        statusDot.textColor = model.error == nil ? .systemGreen : .systemOrange
        status.stringValue = model.interfaces.isEmpty ? "Waiting for a network interface" : "Metering this Mac"
        if tabs.selectedSegment == 2 {
            status.stringValue = "UniFi site statistics"
            statusDot.textColor = model.unifi.error == nil ? .systemGreen : .systemOrange
        }
        if let imported {
            importAmount.stringValue = Display.euros(imported.fee, precise: true)
            importDownload.stringValue = "↓ \(Display.bytes(imported.traffic.received)) downloaded"
            importUpload.stringValue = "↑ \(Display.bytes(imported.traffic.sent)) uploaded"
        } else if tabs.selectedSegment == 0 {
            fee.stringValue = Display.euros(model.today.fee, precise: true)
            fee.setAccessibilityLabel("Today's network cost")
            tariff.stringValue = "↓ \(Display.bytes(model.today.downloadBytes)) × €0.055 / GB"
            download.update(bytes: model.today.downloadBytes, rate: model.rate.received)
            upload.update(bytes: model.today.uploadBytes, rate: model.rate.sent)
            weekTotal.stringValue = Display.euros(model.lastWeek.reduce(0) { $0 + $1.fee }, precise: true)
            chart.update(days: model.lastWeekDays, records: Dictionary(uniqueKeysWithValues: model.lastWeek.map { ($0.id, $0) }), today: model.today.id)
            appsStatus.stringValue = model.applicationStatus
            let updated = model.applications(on: model.today.id)
            let changed = updated.map(\.id) != applications.map(\.id)
            applications = updated
            if changed {
                let origin = appsScroll.contentView.bounds.origin
                appsTable.reloadData()
                appsScroll.contentView.scroll(to: origin)
            }
            updateVisibleRows(appsTable)
            appsEmpty.isHidden = !applications.isEmpty
        } else if tabs.selectedSegment == 1 {
            historyTotal.stringValue = Display.euros(model.totalFee, precise: true)
            historyZone.stringValue = "Stored on this Mac · \(model.ledger.timeZoneIdentifier)"
            refreshHistory()
        } else {
            unifiPage.refresh()
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 40
        logo.frame = NSRect(x: 20, y: 20, width: 38, height: 38)
        title.frame = NSRect(x: 70, y: 17, width: width - 85, height: 32)
        subtitle.frame = NSRect(x: 70, y: 48, width: width - 60, height: 14)
        info.frame = NSRect(x: bounds.width - 44, y: 24, width: 24, height: 24)
        let tabsWidth: CGFloat = model.unifi.isEnabled ? 200 : 134
        tabs.frame = NSRect(x: (bounds.width - tabsWidth) / 2, y: 78, width: tabsWidth, height: 24)
        let footerY = bounds.height - 46
        let page = NSRect(x: 20, y: 112, width: width, height: footerY - 112 - (error.isHidden ? 12 : 48))
        [todayPage, historyPage, importPage, unifiPage].forEach { $0.frame = page }
        bill.frame = NSRect(x: 0, y: 0, width: width, height: 114)
        billTitle.frame = NSRect(x: 14, y: 13, width: width - 28, height: 14)
        fee.frame = NSRect(x: 14, y: 31, width: width - 28, height: 52)
        tariff.frame = NSRect(x: 14, y: 91, width: width - 28, height: 16)
        download.frame = NSRect(x: 0, y: 126, width: (width - 12) / 2, height: 80)
        upload.frame = NSRect(x: (width + 12) / 2, y: 126, width: (width - 12) / 2, height: 80)
        weekTitle.frame = NSRect(x: 3, y: 221, width: 180, height: 14)
        weekTotal.frame = NSRect(x: width - 140, y: 221, width: 137, height: 14)
        chart.frame = NSRect(x: 3, y: 239, width: width - 6, height: 46)
        appsTitle.frame = NSRect(x: 3, y: 301, width: 200, height: 14)
        appsCostTitle.frame = NSRect(x: width - 120, y: 301, width: 117, height: 14)
        appsStatus.frame = NSRect(x: 3, y: 318, width: width - 6, height: 14)
        appsScroll.frame = NSRect(x: 0, y: 339, width: width, height: max(0, page.height - 339))
        appsEmpty.frame = NSRect(x: 3, y: 355, width: width - 6, height: 32)
        historyTitle.frame = NSRect(x: 3, y: 3, width: 220, height: 14)
        historyTotal.frame = NSRect(x: 0, y: 20, width: width, height: 54)
        export.frame = NSRect(x: width - 86, y: 0, width: 86, height: 28)
        historyHeading.frame = NSRect(x: 3, y: 86, width: 250, height: 14)
        historyCostTitle.frame = NSRect(x: width - 80, y: 86, width: 77, height: 14)
        historyScroll.frame = NSRect(x: 0, y: 108, width: width, height: max(0, page.height - 132))
        historyZone.frame = NSRect(x: 3, y: page.height - 16, width: width - 6, height: 14)
        separator.frame = NSRect(x: 20, y: footerY, width: width, height: 1)
        error.frame = NSRect(x: 20, y: footerY - 38, width: width, height: 32)
        statusDot.frame = NSRect(x: 20, y: footerY + 15, width: 8, height: 10)
        status.frame = NSRect(x: 32, y: footerY + 12, width: width - 50, height: 16)
        settings.frame = NSRect(x: bounds.width - 44, y: footerY + 8, width: 24, height: 24)
        for (table, scroll) in [(appsTable, appsScroll), (historyTable, historyScroll)] {
            table.frame.size.width = scroll.contentSize.width
            table.tableColumns[0].width = scroll.contentSize.width
        }
    }

    private func configureSymbol(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
    }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = action
    }

    private func setupTable(_ table: NSTableView, scroll: NSScrollView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("usage"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 49
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.autoresizingMask = [.width]
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .plain
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = table
    }

    private func configure(_ cell: UsageRowView, application: ApplicationUsageRow, live: Bool) {
        cell.update(name: application.identity.name,
            detail: "↓ \(Display.bytes(application.record.downloadBytes)) · ↑ \(Display.bytes(application.record.uploadBytes))",
            amount: Display.applicationEuros(application.record.fee),
            secondary: live ? "↓ \(Display.bytes(application.rate.received))/s · ↑ \(Display.bytes(application.rate.sent))/s" : "",
            icon: model.icon(for: application.identity), help: application.identity.bundlePath ?? application.identity.id)
    }

    private func updateVisibleRows(_ table: NSTableView) {
        let visible = table.rows(in: table.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? UsageRowView else { continue }
            if table === appsTable, applications.indices.contains(row) { configure(cell, application: applications[row], live: true) }
            else if let item = historyTable.item(atRow: row) as? HistoryItem { configure(cell, item: item) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { applications.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("usage"), owner: self) as? UsageRowView ?? UsageRowView(frame: .zero)
        configure(cell, application: applications[row], live: true)
        return cell
    }

    private func historyItem(_ key: String) -> HistoryItem {
        if let existing = historyItems[key] { return existing }
        let item = HistoryItem(key: key)
        historyItems[key] = item
        return item
    }

    private func refreshHistory() {
        let expanded = Set(history.filter { historyTable.isItemExpanded($0) }.map(\.key))
        var updated: [HistoryItem] = []
        if let imported = model.ledger.includedInitialImport {
            let item = historyItem("import")
            item.imported = imported
            updated.append(item)
        }
        for day in model.ledger.sortedRecords {
            let item = historyItem(day.id)
            item.day = day
            item.children = model.applications(on: day.id).map { application in
                let child = historyItem("\(day.id)/\(application.id)")
                child.application = application
                return child
            }
            updated.append(item)
        }
        history = updated
        let structure = history.flatMap { [$0.key] + $0.children.map(\.key) }
        if structure != historyStructure {
            historyStructure = structure
            let origin = historyScroll.contentView.bounds.origin
            historyTable.reloadData()
            for item in history where expanded.contains(item.key) { historyTable.expandItem(item) }
            historyScroll.contentView.scroll(to: origin)
        }
        updateVisibleRows(historyTable)
    }

    private func configure(_ cell: UsageRowView, item: HistoryItem) {
        if let application = item.application { configure(cell, application: application, live: false) }
        else if let day = item.day {
            cell.update(name: day.id == model.today.id ? "Today · \(day.id)" : day.id,
                detail: "↓ \(Display.bytes(day.downloadBytes)) · ↑ \(Display.bytes(day.uploadBytes))",
                amount: Display.euros(day.fee, precise: true),
                help: item.children.isEmpty ? nil : "Expand to see \(item.children.count) applications")
        } else if let imported = item.imported {
            cell.update(name: "Before NetFees", detail: "↓ \(Display.bytes(imported.traffic.received)) · ↑ \(Display.bytes(imported.traffic.sent))",
                amount: Display.euros(imported.fee, precise: true),
                secondary: "Dates unknown",
                help: "Imported \(imported.capturedAt.formatted(date: .abbreviated, time: .omitted)) · dates unknown")
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? HistoryItem)?.children.count ?? history.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? HistoryItem)?.children[index] ?? history[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !(item as! HistoryItem).children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("usage"), owner: self) as? UsageRowView ?? UsageRowView(frame: .zero)
        configure(cell, item: item as! HistoryItem)
        return cell
    }

    private func setupImport() {
        let heading = DashboardStyle.label("Your Mac already has a tab.", size: 23, weight: .semibold)
        let question = DashboardStyle.label("Include the traffic already counted by macOS?", size: 12)
        let explanation = DashboardStyle.paragraph("These counters accumulate until a network interface resets. They may cover several days. Imported usage gets its own history entry, separate from today's measured traffic.", width: 364, size: 12)
        let footnote = DashboardStyle.paragraph("Application history starts when NetFees begins observing each app.", width: 364, size: 10)
        let accept = NSButton(title: "Import existing usage", target: nil, action: nil)
        let decline = NSButton(title: "Start from now", target: nil, action: nil)
        configureButton(accept, action: #selector(acceptImport))
        configureButton(decline, action: #selector(declineImport))
        accept.bezelColor = DashboardStyle.accent
        [heading, question, importAmount, importDownload, importUpload, explanation, accept, decline, footnote].forEach { importPage.addSubview($0) }
        heading.frame = NSRect(x: 18, y: 22, width: 364, height: 30)
        question.frame = NSRect(x: 18, y: 64, width: 364, height: 20)
        importAmount.frame = NSRect(x: 18, y: 100, width: 364, height: 54)
        importDownload.frame = NSRect(x: 18, y: 163, width: 364, height: 18)
        importUpload.frame = NSRect(x: 18, y: 190, width: 364, height: 18)
        explanation.frame.origin = NSPoint(x: 18, y: 229)
        accept.frame = NSRect(x: 14, y: 314, width: 192, height: 30)
        decline.frame = NSRect(x: 14, y: 354, width: 140, height: 30)
        footnote.frame.origin = NSPoint(x: 18, y: 407)
    }

    @objc private func changePage() { refresh() }
    @objc private func acceptImport() { model.resolveInitialImport(include: true) }
    @objc private func declineImport() { model.resolveInitialImport(include: false) }
    @objc private func exportHistory() { model.exportCSV() }
    @objc private func revealHistory() { model.revealHistory() }
    @objc private func toggleLogin() { model.setLaunchAtLogin(!model.launchAtLogin) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        let menu = NSMenu()
        menu.addItem(withTitle: "UniFi Settings…", action: #selector(showUniFiSettings), keyEquivalent: "")
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = model.launchAtLogin ? .on : .off
        menu.addItem(withTitle: "Export history as CSV…", action: #selector(exportHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Show history file", action: #selector(revealHistory), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NetFees", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: settings.bounds.maxY), in: settings)
    }

    @objc private func showUniFiSettings() {
        if unifiPreferences == nil { unifiPreferences = UniFiPreferences(model: model.unifi) }
        window?.orderOut(nil)
        unifiPreferences?.present()
    }

    @objc private func showAbout() {
        guard !about.isShown else { about.performClose(nil); return }
        let content = FlippedView()
        let heading = DashboardStyle.label("About NetFees", size: 20, weight: .bold)
        heading.frame = NSRect(x: 24, y: 20, width: 312, height: 28)
        content.addSubview(heading)
        let paragraphs = [
            "NetFees reads this Mac's network counters and records daily upload and download totals.",
            "Download costs are calculated at €0.055 per decimal GB (1,000,000,000 bytes). Uploads are measured separately and do not contribute to the cost.",
            "Metering covers en* network interfaces while NetFees runs, including local-network traffic and protocol overhead. VPN tunnels and loopback are excluded to avoid counting traffic twice. No packet contents are read.",
            "On first launch, existing interface totals can be imported as a separate history entry. Daily history records traffic observed while NetFees runs. Days use \(model.ledger.timeZoneIdentifier).",
            "Application totals and speeds use macOS TCP/UDP process counters, without administrator access. Helpers are grouped with their apps. VPNs, proxies, shared services, and short-lived processes can affect attribution, so app totals may differ from the physical-interface total."
        ]
        var y: CGFloat = 62
        for text in paragraphs {
            let field = DashboardStyle.paragraph(text, width: 312)
            field.frame.origin = NSPoint(x: 24, y: y)
            content.addSubview(field)
            y += field.frame.height + 12
        }
        let link = NSButton(title: "Read amendment I-1358 ↗", target: self, action: #selector(openAmendment))
        link.isBordered = false
        link.contentTintColor = DashboardStyle.accent
        link.alignment = .left
        link.font = .systemFont(ofSize: 11)
        link.frame = NSRect(x: 24, y: y, width: 260, height: 24)
        content.addSubview(link)
        content.frame.size = NSSize(width: 360, height: y + 44)
        let controller = NSViewController()
        controller.view = content
        about.contentViewController = controller
        about.contentSize = content.frame.size
        about.behavior = .transient
        NSApp.activate(ignoringOtherApps: true)
        about.show(relativeTo: info.bounds, of: info, preferredEdge: .minY)
    }

    @objc private func openAmendment() {
        let url = URL(string: "https://www.assemblee-nationale.fr/dyn/17/amendements/3210A/AN/1358")!
        if NSWorkspace.shared.open(url) { about.performClose(nil) }
    }
}
