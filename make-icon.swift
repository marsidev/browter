import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: swift make-icon.swift <output.iconset>\n", stderr)
    exit(2)
}

let iconsetDir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

func renderIcon(size: Int, to path: String) {
    let s = CGFloat(size)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext creation failed") }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let pad = s * 0.098
    let rect = CGRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Subtle macOS drop shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.015),
        blur: s * 0.032,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.11, blue: 0.22, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Deep cobalt to midnight indigo gradient
    let bgColors = [
        CGColor(red: 0.13, green: 0.22, blue: 0.48, alpha: 1.0),
        CGColor(red: 0.05, green: 0.09, blue: 0.22, alpha: 1.0),
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: s * 0.5, y: rect.maxY),
        end: CGPoint(x: s * 0.5, y: rect.minY),
        options: []
    )

    // Soft top-center ambient glow
    let glowColors = [
        CGColor(red: 0.25, green: 0.72, blue: 1.0, alpha: 0.28),
        CGColor(red: 0.25, green: 0.72, blue: 1.0, alpha: 0.0),
    ] as CFArray
    let glowGrad = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: s * 0.50, y: s * 0.72), startRadius: 0,
        endCenter: CGPoint(x: s * 0.50, y: s * 0.72), endRadius: s * 0.48,
        options: []
    )

    // Subtle inner rim highlight
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(max(1, s * 0.014))
    ctx.strokePath()

    // Split-route arrows
    let strokeW = s * 0.062
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Left branch (bright sky cyan)
    let leftPath = CGMutablePath()
    leftPath.move(to: CGPoint(x: s * 0.50, y: s * 0.24))
    leftPath.addLine(to: CGPoint(x: s * 0.50, y: s * 0.42))
    leftPath.addCurve(
        to: CGPoint(x: s * 0.30, y: s * 0.65),
        control1: CGPoint(x: s * 0.50, y: s * 0.55),
        control2: CGPoint(x: s * 0.30, y: s * 0.52)
    )
    leftPath.addLine(to: CGPoint(x: s * 0.30, y: s * 0.73))

    let leftHead = CGMutablePath()
    leftHead.move(to: CGPoint(x: s * 0.20, y: s * 0.635))
    leftHead.addLine(to: CGPoint(x: s * 0.30, y: s * 0.735))
    leftHead.addLine(to: CGPoint(x: s * 0.40, y: s * 0.635))

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.01),
        blur: s * 0.024,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    ctx.setLineWidth(strokeW)
    ctx.setStrokeColor(CGColor(red: 0.33, green: 0.83, blue: 1.0, alpha: 1.0))
    ctx.addPath(leftPath)
    ctx.addPath(leftHead)
    ctx.strokePath()
    ctx.restoreGState()

    // Right branch (crisp white, drawn over shared stem)
    let rightPath = CGMutablePath()
    rightPath.move(to: CGPoint(x: s * 0.50, y: s * 0.24))
    rightPath.addLine(to: CGPoint(x: s * 0.50, y: s * 0.42))
    rightPath.addCurve(
        to: CGPoint(x: s * 0.70, y: s * 0.65),
        control1: CGPoint(x: s * 0.50, y: s * 0.55),
        control2: CGPoint(x: s * 0.70, y: s * 0.52)
    )
    rightPath.addLine(to: CGPoint(x: s * 0.70, y: s * 0.73))

    let rightHead = CGMutablePath()
    rightHead.move(to: CGPoint(x: s * 0.60, y: s * 0.635))
    rightHead.addLine(to: CGPoint(x: s * 0.70, y: s * 0.735))
    rightHead.addLine(to: CGPoint(x: s * 0.80, y: s * 0.635))

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.01),
        blur: s * 0.024,
        color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
    )
    ctx.setLineWidth(strokeW)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
    ctx.addPath(rightPath)
    ctx.addPath(rightHead)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    renderIcon(size: px, to: "\(iconsetDir)/\(name)")
}
