import AppKit

let folder = URL(fileURLWithPath: "build/AppIcon.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let rect = NSRect(x: 52, y: 52, width: 920, height: 920)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210)
        NSGradient(starting: NSColor(red: 1, green: 0.37, blue: 0.26, alpha: 1),
                   ending: NSColor(red: 0.7, green: 0.08, blue: 0.15, alpha: 1))!.draw(in: shape, angle: -65)
        NSColor.white.withAlphaComponent(0.22).setStroke()
        shape.lineWidth = 6
        shape.stroke()
        let mark = "nf" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 550, weight: .heavy),
            .foregroundColor: NSColor.white,
            .kern: -30
        ]
        let markSize = mark.size(withAttributes: attributes)
        mark.draw(at: NSPoint(x: (1024 - markSize.width) / 2 - 10, y: (1024 - markSize.height) / 2 + 15), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
