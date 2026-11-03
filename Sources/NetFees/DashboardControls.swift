import AppKit
import NetFeesCore

@MainActor
enum DashboardStyle {
    static let accent = NSColor(srgbRed: 0.95, green: 0.35, blue: 0.24, alpha: 1)

    static func label(_ text: String = "", size: CGFloat = 11, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = monospaced ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }

    static func paragraph(_ text: String, width: CGFloat, size: CGFloat = 11) -> NSTextField {
        let field = label(text, size: size, color: .secondaryLabelColor)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        let height = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: field.font!]).height
        field.frame.size = NSSize(width: width, height: ceil(height) + 4)
        return field
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class DashboardCard: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 17, yRadius: 17)
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.25).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class TrafficCard: DashboardCard {
    private let heading: NSTextField
    private let amount = DashboardStyle.label(size: 20, weight: .semibold, monospaced: true)
    private let speed = DashboardStyle.label(size: 10, color: .secondaryLabelColor, monospaced: true)

    init(title: String, color: NSColor) {
        heading = DashboardStyle.label(title, size: 11, weight: .medium, color: color)
        super.init(frame: .zero)
        [heading, amount, speed].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { nil }

    func update(bytes: UInt64, rate: UInt64) {
        amount.stringValue = Display.bytes(bytes)
        speed.stringValue = "\(Display.bytes(rate))/s"
    }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 12, y: 8, width: bounds.width - 24, height: 16)
        amount.frame = NSRect(x: 12, y: 27, width: bounds.width - 24, height: 27)
        speed.frame = NSRect(x: 12, y: 57, width: bounds.width - 24, height: 14)
    }
}

final class WeekChartView: FlippedView {
    private var days: [String] = []
    private var records: [String: DailyRecord] = [:]
    private var today = ""

    func update(days: [String], records: [String: DailyRecord], today: String) {
        self.days = days
        self.records = records
        self.today = today
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Network costs over the last seven days")
        setAccessibilityValue(days.compactMap { day in records[day].map { "\(day): \(Display.euros($0.fee, precise: true))" } }.joined(separator: ", "))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let maximum = max(0.01, records.values.map { NSDecimalNumber(decimal: $0.fee).doubleValue }.max() ?? 0)
        let step = bounds.width / CGFloat(days.count)
        let graphHeight = bounds.height - 16
        for (index, day) in days.enumerated() {
            let center = (CGFloat(index) + 0.5) * step
            let value = records[day].map { NSDecimalNumber(decimal: $0.fee).doubleValue } ?? 0
            if value > 0 {
                let height = graphHeight * value / maximum
                let width = min(26, step / 2)
                DashboardStyle.accent.withAlphaComponent(day == today ? 1 : 0.28).setFill()
                NSBezierPath(roundedRect: NSRect(x: center - width / 2, y: graphHeight - height, width: width, height: height),
                             xRadius: 3, yRadius: 3).fill()
            }
            let label = String(day.suffix(5)) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
            label.draw(at: NSPoint(x: center - label.size(withAttributes: attributes).width / 2, y: graphHeight + 4), withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class UsageRowView: NSTableCellView {
    override var isFlipped: Bool { true }
    private let icon = NSImageView()
    private let name = DashboardStyle.label(size: 11, weight: .medium)
    private let detail = DashboardStyle.label(size: 9, color: .secondaryLabelColor, monospaced: true)
    private let amount = DashboardStyle.label(size: 12, weight: .medium, color: DashboardStyle.accent, monospaced: true)
    private let secondary = DashboardStyle.label(size: 8, color: .secondaryLabelColor, monospaced: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("usage")
        amount.alignment = .right
        secondary.alignment = .right
        icon.imageScaling = .scaleProportionallyUpOrDown
        [icon, name, detail, amount, secondary].forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { nil }

    func update(name: String, detail: String, amount: String, secondary: String = "", icon: NSImage? = nil, help: String? = nil) {
        self.name.stringValue = name
        self.detail.stringValue = detail
        self.amount.stringValue = amount
        self.secondary.stringValue = secondary
        self.icon.image = icon
        self.icon.isHidden = icon == nil
        toolTip = help
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left: CGFloat = icon.isHidden ? 2 : 35
        icon.frame = NSRect(x: 2, y: 10, width: 26, height: 26)
        name.frame = NSRect(x: left, y: 6, width: max(0, bounds.width - left - 106), height: 16)
        detail.frame = NSRect(x: left, y: 26, width: max(0, bounds.width - left - (secondary.stringValue.isEmpty ? 4 : 145)), height: 14)
        amount.frame = NSRect(x: bounds.width - 104, y: 5, width: 102, height: 18)
        secondary.frame = NSRect(x: bounds.width - 145, y: 27, width: 143, height: 13)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 0.5).fill()
    }
}
