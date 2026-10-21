// Draws the Headroom app icon (three nested rings) into an .iconset folder.
// Usage: swift Scripts/make_icon.swift <output.iconset>
import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Same artwork as the design canvas, on a 200-unit grid.
func draw(_ ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 200
    ctx.scaleBy(x: scale, y: scale)

    // macOS icons sit inside the canvas with a margin (824/1024 of the full size).
    let inset: CGFloat = 200 * (100.0 / 1024.0)
    let side = 200 - inset * 2
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.225

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2 * scale), blur: 6 * scale, color: CGColor(gray: 0, alpha: pixels <= 32 ? 0.15 : 0.28))
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(color(0x16181D))
    ctx.fillPath()
    ctx.restoreGState()

    let center = CGPoint(x: 100, y: 100)
    let k = side / 200
    let line = 13 * k * (pixels <= 32 ? 1.35 : 1)
    let rings: [(radius: CGFloat, percent: CGFloat, color: UInt32)] = pixels <= 32
        ? [(64 * k, 0.70, 0xD97757), (34 * k, 0.52, 0x1F8A70)]
        : [(66 * k, 0.72, 0xD97757), (47 * k, 0.45, 0x1F8A70), (28 * k, 0.60, 0x5B7BEA)]

    ctx.setLineCap(.round)
    for ring in rings {
        ctx.setLineWidth(line)
        ctx.setStrokeColor(color(0x2B2E36))
        ctx.addArc(center: center, radius: ring.radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        ctx.setStrokeColor(color(ring.color))
        let start = CGFloat.pi / 2
        ctx.addArc(center: center, radius: ring.radius, startAngle: start,
                   endAngle: start - .pi * 2 * ring.percent, clockwise: true)
        ctx.strokePath()
    }
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for size in sizes {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size.pixels, pixelsHigh: size.pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(context.cgContext, pixels: size.pixels)
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: output).appendingPathComponent(size.name + ".png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}
print("Icon images written to \(output)")
