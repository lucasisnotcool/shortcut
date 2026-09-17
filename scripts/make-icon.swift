// Draws the app icon (Resources/AppIcon.icns): the Shortcut ring mark with a
// check, monochrome on a dark squircle. Run via scripts/make-icon.sh.
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    // macOS icon grid: 824pt body centred on a 1024pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    context.restoreGState()

    NSGradient(colors: [
        NSColor(white: 0.24, alpha: 1),
        NSColor(white: 0.07, alpha: 1)
    ])!.draw(in: squircle, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
    rim.lineWidth = 4
    rim.stroke()

    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 250

    // Faint full ring, then the bright sweep the menu-bar mark shows while busy.
    let ring = NSBezierPath()
    ring.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    ring.lineWidth = 34
    NSColor(white: 1, alpha: 0.22).setStroke()
    ring.stroke()

    let sweep = NSBezierPath()
    sweep.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -30, clockwise: true)
    sweep.lineWidth = 40
    sweep.lineCapStyle = .round
    NSColor.white.setStroke()
    sweep.stroke()

    let check = NSBezierPath()
    check.move(to: CGPoint(x: 405, y: 515))
    check.line(to: CGPoint(x: 483, y: 432))
    check.line(to: CGPoint(x: 628, y: 598))
    check.lineWidth = 50
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    NSColor.white.setStroke()
    check.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024)
]
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for size in sizes {
    try drawIcon(pixels: size.pixels).write(to: outputDirectory.appendingPathComponent("icon_\(size.name).png"))
}
