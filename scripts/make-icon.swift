// Draws the app icon (Resources/AppIcon.icns): two Option (⌥) glyphs, the
// right one mirrored, joined along the bottom into one mark, monochrome on a
// dark squircle. Run via scripts/make-icon.sh.
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// ⌥ drawn in `rect` (y up); `mirrored` flips it horizontally.
func optionGlyph(in rect: CGRect, mirrored: Bool) -> NSBezierPath {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + (mirrored ? 1 - x : x) * rect.width, y: rect.minY + y * rect.height)
    }
    let path = NSBezierPath()
    path.move(to: point(0, 1))
    path.line(to: point(0.36, 1))
    path.line(to: point(0.66, 0))
    path.line(to: point(1, 0))
    path.move(to: point(0.60, 1))
    path.line(to: point(1, 1))
    return path
}

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

    // The two gestures' key: ⌥ and its mirror image, bottom strokes meeting.
    let width: CGFloat = 300, height: CGFloat = 200
    let left = CGRect(x: 512 - width, y: 512 - height / 2, width: width, height: height)
    for (rect, mirrored) in [(left, false), (left.offsetBy(dx: width, dy: 0), true)] {
        let glyph = optionGlyph(in: rect, mirrored: mirrored)
        glyph.lineWidth = 46
        glyph.lineCapStyle = .round
        glyph.lineJoinStyle = .round
        NSColor.white.setStroke()
        glyph.stroke()
    }

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
