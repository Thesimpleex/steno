// Zeichnet das App-Logo: schwarzes Squircle, fünf weiße Pegelbalken, der mittlere in Signalrot.
// Aufruf (im Projektordner):
//   swift tools/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit

guard CommandLine.arguments.count > 1 else {
    print("Aufruf: swift tools/make-icon.swift <ausgabe.iconset>")
    exit(1)
}
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func squircle(_ r: CGRect) -> CGPath {
    // Superellipse (n = 5) – die „kontinuierliche“ Ecke von Apple-Icons
    let path = CGMutablePath()
    let n: CGFloat = 5, steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1)
        let y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func draw(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    // Schatten
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Fläche: fast schwarz, oben minimal heller
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(white: 0.17, alpha: 1).cgColor, NSColor(white: 0.03, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // feine Lichtkante oben
    ctx.addPath(shape); ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor); ctx.setLineWidth(6); ctx.strokePath()
    ctx.restoreGState()

    // Pegelbalken
    let heights: [CGFloat] = [190, 330, 470, 330, 190]
    let w: CGFloat = 64, gap: CGFloat = 50
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    var x = 512 - total / 2
    for (i, h) in heights.enumerated() {
        let r = CGRect(x: x, y: 512 - h / 2, width: w, height: h)
        let bar = CGPath(roundedRect: r, cornerWidth: w / 2, cornerHeight: w / 2, transform: nil)
        ctx.addPath(bar)
        if i == 2 {
            ctx.saveGState(); ctx.clip()
            let red = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [NSColor(red: 1, green: 0.45, blue: 0.30, alpha: 1).cgColor,
                                          NSColor(red: 1, green: 0.22, blue: 0.24, alpha: 1).cgColor] as CFArray,
                                 locations: [0, 1])!
            ctx.drawLinearGradient(red, start: CGPoint(x: 512, y: r.maxY), end: CGPoint(x: 512, y: r.minY), options: [])
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        }
        x += w + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(size: base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(size: base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
