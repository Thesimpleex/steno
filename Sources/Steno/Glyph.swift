import AppKit

/// Die fünf Pegelbalken aus dem Logo als Menüleisten-Symbol; beim Aufnehmen mit Punkt.
enum Glyph {
    static let idle = draw(recording: false)
    static let recording = draw(recording: true)

    private static func draw(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let heights: [CGFloat] = [0.36, 0.64, 0.92, 0.64, 0.36]
            let width: CGFloat = 2, gap: CGFloat = 1.6
            var x = rect.midX - (CGFloat(heights.count) * (width + gap) - gap) / 2 - (recording ? 0.8 : 0)
            for h in heights {
                let height = rect.height * 0.8 * h
                NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - height / 2, width: width, height: height),
                             xRadius: width / 2, yRadius: width / 2).fill()
                x += width + gap
            }
            if recording { NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }
}
