// Zeichnet docs/banner.png für das README: App-Symbol, Name, Kernaussage und die Notch-Anzeige im echten Look.
// Aufruf: swift tools/make-banner.swift
import AppKit
import SwiftUI

struct Notch: Shape {
    var width: CGFloat, height: CGFloat, radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let ear: CGFloat = 9, x0 = rect.midX - width / 2, x1 = x0 + width
        var p = Path()
        p.move(to: CGPoint(x: x0, y: 0))
        p.addQuadCurve(to: CGPoint(x: x0 + ear, y: ear), control: CGPoint(x: x0 + ear, y: 0))
        p.addLine(to: CGPoint(x: x0 + ear, y: height - radius))
        p.addQuadCurve(to: CGPoint(x: x0 + ear + radius, y: height), control: CGPoint(x: x0 + ear, y: height))
        p.addLine(to: CGPoint(x: x1 - ear - radius, y: height))
        p.addQuadCurve(to: CGPoint(x: x1 - ear, y: height - radius), control: CGPoint(x: x1 - ear, y: height))
        p.addLine(to: CGPoint(x: x1 - ear, y: ear))
        p.addQuadCurve(to: CGPoint(x: x1, y: 0), control: CGPoint(x: x1 - ear, y: 0))
        p.closeSubpath()
        return p
    }
}

struct Bars: View {
    let levels: [CGFloat] = [0.15, 0.3, 0.55, 0.8, 0.5, 0.95, 0.7, 0.4, 0.85, 0.6, 0.35, 0.75, 0.5, 0.9, 0.65, 0.45]
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(.white.opacity(0.55 + 0.45 * Double(i) / Double(levels.count)))
                    .frame(width: 3, height: 4 + 18 * levels[i])
            }
        }
    }
}

struct Banner: View {
    let icon: NSImage
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.97), Color(white: 0.91)], startPoint: .top, endPoint: .bottom)
            // Bildschirmrand mit Notch und laufender Aufnahme
            ZStack(alignment: .top) {
                Notch(width: 470, height: 40, radius: 13).fill(.black)
                HStack {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 9, height: 9)
                        Text("0:07").font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer()
                    Bars()
                }
                .padding(.horizontal, 26)
                .frame(width: 470, height: 40)
            }
            VStack(spacing: 18) {
                Image(nsImage: icon).resizable().frame(width: 128, height: 128)
                Text("Steno").font(.system(size: 64, weight: .bold)).foregroundStyle(Color(white: 0.08))
                Text("Hold ⌥, speak, release. Private dictation for every Mac app —\nWhisper runs locally, your voice never leaves your Mac.")
                    .font(.system(size: 22)).multilineTextAlignment(.center).foregroundStyle(Color(white: 0.35))
            }
            .padding(.top, 96)
        }
        .frame(width: 1280, height: 470)
    }
}

MainActor.assumeIsolated {
    let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") ?? NSImage()
    let renderer = ImageRenderer(content: Banner(icon: icon))
    renderer.scale = 2
    guard let image = renderer.cgImage else { fatalError("Rendern fehlgeschlagen") }
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/banner.png"))
    print("docs/banner.png")
}
