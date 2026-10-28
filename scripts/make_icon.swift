// Renders the DiskBro app icon (a sunburst on a gradient squircle) into an .iconset.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.05, green: 0.06, blue: 0.12, alpha: 1)])!
        .draw(in: shape, angle: -90)

    let c = NSPoint(x: s / 2, y: s / 2)
    let hexes: [Int] = [0x3987e5, 0xeb6834, 0x1baf7a, 0xeda100, 0x9085e9]
    let colors: [NSColor] = hexes.map { (h: Int) -> NSColor in
        let r = CGFloat((h >> 16) & 0xff) / 255
        let g = CGFloat((h >> 8) & 0xff) / 255
        let b = CGFloat(h & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    let fractions: [CGFloat] = [0.38, 0.22, 0.16, 0.12, 0.08]
    let rings: [(CGFloat, CGFloat, CGFloat)] = [(0.13, 0.24, 1.0), (0.25, 0.32, 0.72)]
    for (ri, (r0, r1, alpha)) in rings.enumerated() {
        var a: CGFloat = 90
        for (i, f) in fractions.enumerated() {
            let span = 360 * f * (ri == 0 ? 1 : 0.8)
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: s * r1, startAngle: a, endAngle: a - span + 1.5, clockwise: true)
            p.appendArc(withCenter: c, radius: s * r0, startAngle: a - span + 1.5, endAngle: a, clockwise: false)
            p.close()
            colors[i].withAlphaComponent(alpha).setFill()
            p.fill()
            a -= 360 * f
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
