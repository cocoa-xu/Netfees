import AppKit
import NetFeesCore

final class UniFiView: FlippedView {
    private let model: UniFiModel
    private let site = DashboardStyle.label(size: 16, weight: .semibold)
    private let period = NSPopUpButton()
    private let refreshButton = NSButton()
    private let bill = DashboardCard()
    private let heading = DashboardStyle.label("SITE DOWNLOAD COST", size: 10, weight: .bold, color: .secondaryLabelColor)
    private let cost = DashboardStyle.label(size: 42, weight: .light, monospaced: true)
    private let tariff = DashboardStyle.label(size: 11, color: .secondaryLabelColor, monospaced: true)
    private let downloads = TrafficCard(title: "↓  Site downloads", color: DashboardStyle.accent)
    private let uploads = TrafficCard(title: "↑  Site uploads", color: .systemTeal)
    private let state = DashboardStyle.label(size: 11, weight: .medium)
    private let coverage = DashboardStyle.label(size: 11, color: .secondaryLabelColor)
    private let detail = DashboardStyle.label(size: 11, color: .secondaryLabelColor)
    private let explanation = DashboardStyle.paragraph("Whole-site Internet traffic reported by your UniFi gateway. Downloads cost €0.055 per GB; uploads are measured separately. This is separate from this Mac's bill.", width: 394, size: 11)

    init(model: UniFiModel) {
        self.model = model
        super.init(frame: .zero)
        [site, period, refreshButton, bill, downloads, uploads, state, coverage, detail, explanation].forEach { addSubview($0) }
        [heading, cost, tariff].forEach { bill.addSubview($0) }
        period.addItems(withTitles: UniFiPeriod.allCases.map(\.title))
        period.target = self
        period.action = #selector(changePeriod)
        period.setAccessibilityLabel("UniFi statistics period")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh UniFi statistics")
        refreshButton.imagePosition = .imageOnly
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshStatistics)
        refreshButton.toolTip = "Refresh UniFi statistics"
        for field in [coverage, detail] { field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping }
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        site.stringValue = model.configuration?.site.displayName ?? "UniFi"
        period.selectItem(at: UniFiPeriod.allCases.firstIndex(of: model.period) ?? 0)
        refreshButton.isEnabled = !model.isRefreshing
        if let report = model.report {
            cost.stringValue = Display.euros(report.fee, precise: true)
            tariff.stringValue = "↓ \(Display.bytes(report.traffic.received)) × €0.055 / GB"
            downloads.update(bytes: report.traffic.received, rate: nil)
            uploads.update(bytes: report.traffic.sent, rate: nil)
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            let start = formatter.string(from: report.buckets.first!.start)
            let end = formatter.string(from: report.buckets.last!.end)
            let complete = report.coveredSeconds >= report.window.duration
            coverage.stringValue = "\(start) to \(end)\n\(complete ? "Complete reported period" : "Partial coverage: some intervals are missing") · \(TimeZone.current.identifier)"
            let stale = model.error != nil || Date().timeIntervalSince(report.fetchedAt) > 180
            state.stringValue = model.isRefreshing ? "Refreshing…" : stale ? "Cached statistics" : "Updated \(report.fetchedAt.formatted(date: .omitted, time: .shortened))"
            state.textColor = stale ? .systemOrange : .secondaryLabelColor
        } else {
            cost.stringValue = model.isRefreshing ? "Loading…" : "Unavailable"
            tariff.stringValue = "€0.055 / GB of site downloads"
            coverage.stringValue = ""
            state.stringValue = model.isRefreshing ? "Reading site statistics…" : "Statistics unavailable"
            state.textColor = .secondaryLabelColor
        }
        downloads.isHidden = model.report == nil
        uploads.isHidden = model.report == nil
        detail.stringValue = model.error ?? "Completed intervals only. The most recent hour is excluded while the controller finishes reporting it."
        detail.textColor = model.error == nil ? .secondaryLabelColor : .systemOrange
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        site.frame = NSRect(x: 3, y: 0, width: width - 6, height: 24)
        period.frame = NSRect(x: 0, y: 34, width: 170, height: 28)
        refreshButton.frame = NSRect(x: width - 29, y: 36, width: 24, height: 24)
        bill.frame = NSRect(x: 0, y: 76, width: width, height: 114)
        heading.frame = NSRect(x: 14, y: 13, width: width - 28, height: 14)
        cost.frame = NSRect(x: 14, y: 31, width: width - 28, height: 52)
        tariff.frame = NSRect(x: 14, y: 91, width: width - 28, height: 16)
        downloads.frame = NSRect(x: 0, y: 202, width: (width - 12) / 2, height: 70)
        uploads.frame = NSRect(x: (width + 12) / 2, y: 202, width: (width - 12) / 2, height: 70)
        state.frame = NSRect(x: 3, y: 291, width: width - 6, height: 18)
        coverage.frame = NSRect(x: 3, y: 316, width: width - 6, height: 50)
        detail.frame = NSRect(x: 3, y: 376, width: width - 6, height: 58)
        explanation.frame.origin = NSPoint(x: 3, y: 448)
    }

    @objc private func changePeriod() { model.select(UniFiPeriod.allCases[period.indexOfSelectedItem]) }
    @objc private func refreshStatistics() { model.refresh() }
}
