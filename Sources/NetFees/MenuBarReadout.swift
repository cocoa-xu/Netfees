import AppKit

enum MenuBarReadout {
    static func image(download: String, fee: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let lines = [download as NSString, fee as NSString]
        let width = ceil(lines.map { $0.size(withAttributes: attributes).width }.max() ?? 0)
        let size = NSSize(width: width + 4, height: 22)
        let image = NSImage(size: size, flipped: false) { bounds in
            for (index, line) in lines.enumerated() {
                let lineSize = line.size(withAttributes: attributes)
                let rowCenter = bounds.midY + (index == 0 ? 5.5 : -5.5)
                line.draw(at: NSPoint(x: (bounds.width - lineSize.width) / 2,
                                     y: rowCenter - lineSize.height / 2), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Downloaded \(download), simulated fee \(fee) today"
        return image
    }
}
