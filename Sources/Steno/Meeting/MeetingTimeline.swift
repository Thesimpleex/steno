import AppKit
import SwiftUI

extension View {
    /// Kapsel für den Sprecher: „Du“ in Tinte, die anderen zart hinterlegt.
    func speakerChip(_ speaker: Speaker) -> some View {
        font(.system(size: 11.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 2.5)
            .foregroundStyle(speaker == .you ? Theme.onInk : Color.primary)
            .background(speaker == .you ? Theme.ink : Theme.well, in: Capsule())
    }
}

/// So breit ist ein Name in der Sprecherkapsel, ohne deren Innenabstand.
func speakerNameWidth(_ name: String) -> CGFloat {
    ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width)
}

/// Die Einträge eines Meetings untereinander. Mit `remove` lassen sie sich löschen (laufendes Meeting),
/// ohne ist die Zeitleiste nur zum Lesen.
struct MeetingTimeline: View, Equatable {
    let entries: [MeetingEntry]
    let othersLabel: String
    /// Ordner des Meetings; dort liegen die Bilder.
    let folder: URL?
    var remove: ((MeetingEntry) -> Void)?

    /// Die Pegel ändern sich oft; die Zeitleiste soll dann nicht neu gebaut werden. `remove` zählt nicht mit:
    /// Es ist immer dasselbe Meeting.
    static func == (a: Self, b: Self) -> Bool {
        a.entries == b.entries && a.othersLabel == b.othersLabel && a.folder == b.folder
    }

    /// So breit ist die Spalte für die Sprecher: wie der Name der Anderen, damit er nicht abgeschnitten wird.
    private var labelWidth: CGFloat { min(max(speakerNameWidth(othersLabel) + 20, 56), 132) }

    /// „1:02:15“ braucht mehr Platz als „12:40“.
    private var timeWidth: CGFloat { (entries.map(\.offset).max() ?? 0) >= 3600 ? 58 : 46 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                EntryRow(entry: entry, othersLabel: othersLabel, timeWidth: timeWidth, labelWidth: labelWidth, folder: folder, remove: remove)
            }
        }
    }
}

private struct EntryRow: View {
    let entry: MeetingEntry
    let othersLabel: String
    let timeWidth: CGFloat
    let labelWidth: CGFloat
    let folder: URL?
    let remove: ((MeetingEntry) -> Void)?

    private var readOnly: Bool { remove == nil }

    @ViewBuilder var body: some View {
        let row = content.padding(.vertical, isMark ? 12 : 7).contentShape(Rectangle())
        // Nur mit Löschen ein Menü: Beim Lesen soll das Menü der Textauswahl (Kopieren) nicht von einem leeren verdeckt werden.
        if let remove {
            row.contextMenu { Button(L("Eintrag löschen"), role: .destructive) { remove(entry) } }
        } else {
            row
        }
    }

    private var isMark: Bool {
        if case .mark = entry.kind { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .speech(let speaker, let text):
            line {
                Text(speaker == .you ? L("Du") : othersLabel).speakerChip(speaker)
            } content: {
                paragraph(text)
            }
        case .note(let text):
            line {
                glyph("pencil", L("Notiz"))
            } content: {
                paragraph(text, weight: .medium)
            }
        case .task(let text):
            line {
                glyph("square", L("Aufgabe"))
            } content: {
                paragraph(text, weight: .medium)
            }
        case .mark:
            HStack(spacing: 12) {
                time
                HStack(spacing: 8) {
                    Image(systemName: "flag.fill").font(.system(size: 10.5)).foregroundStyle(Theme.accent)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("Markierung") + ", " + MeetingMarkdown.timestamp(entry.offset))
        case .image(let name):
            line(alignment: .top) {
                glyph("photo", L("Bild")).padding(.top, 2)
            } content: {
                Thumbnail(url: folder?.appendingPathComponent(MeetingFile.imageFolder).appendingPathComponent(name))
            }
        }
    }

    private var time: some View {
        Text(MeetingMarkdown.timestamp(entry.offset))
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: timeWidth, alignment: .leading)
    }

    private func line<Label: View, Content: View>(alignment: VerticalAlignment = .firstTextBaseline,
                                                  @ViewBuilder label: () -> Label,
                                                  @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            time
            label().frame(width: labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func glyph(_ symbol: String, _ name: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel(name)
    }

    @ViewBuilder private func paragraph(_ text: String, weight: Font.Weight = .regular) -> some View {
        let label = Text(text).font(.system(size: 13.5, weight: weight)).lineSpacing(3)
        if readOnly { label.textSelection(.enabled) } else { label }
    }
}

/// Vorschaubild aus dem Bilderordner; ein Klick öffnet die Datei.
private struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 240, maxHeight: 150)
                } else {
                    Rectangle().fill(Theme.well)
                        .frame(width: 160, height: 100)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(L("Bild öffnen"))
        .accessibilityLabel(L("Bild öffnen"))
        .task(id: url) { image = await Self.load(url) }
    }

    /// Verkleinert beim Laden, damit große Bildschirmfotos die Liste nicht bremsen; in Punkten halb so groß wie in Pixeln (Retina).
    private static func load(_ url: URL?) async -> NSImage? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return NSImage(cgImage: picture, size: NSSize(width: picture.width / 2, height: picture.height / 2))
        }.value
    }
}

// MARK: - Am Ende bleiben

/// Entscheidet, ob eine wachsende Liste dem Ende folgt: Wer nach oben scrollt, wird nicht zurückgeholt;
/// wer unten ankommt, folgt wieder.
struct TailFollow {
    private(set) var following = true
    private var offset: CGFloat = 0
    private var content: CGFloat = 0
    private var viewport: CGFloat = 0

    /// Ein Stück Text, das noch als „unten“ gilt.
    private static let slack: CGFloat = 24

    /// Meldet die neue Lage. Liefert true, wenn ans Ende gescrollt werden soll, weil dort etwas dazukam
    /// oder der sichtbare Ausschnitt kleiner wurde (Meldung eingeblendet, Fenster verkleinert).
    mutating func update(offset: CGFloat, content: CGFloat, viewport: CGFloat) -> Bool {
        defer { (self.offset, self.content, self.viewport) = (offset, content, viewport) }
        if offset + viewport >= content - Self.slack {
            following = true
        } else if offset < self.offset - 0.5 {
            following = false
        }
        return following && (content != self.content || viewport != self.viewport)
    }

    /// Wie `update`, wenn sich nur der sichtbare Ausschnitt geändert hat.
    mutating func resize(to viewport: CGFloat) -> Bool {
        update(offset: offset, content: content, viewport: viewport)
    }
}

/// Lage des Inhalts im Scrollbereich: wie weit gescrollt ist und wie hoch der Inhalt ist.
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
}

private struct ScrollMetricsKey: PreferenceKey {
    static var defaultValue = ScrollMetrics()
    static func reduce(value: inout ScrollMetrics, nextValue: () -> ScrollMetrics) { value = nextValue() }
}

/// Merkt sich den Stand von `TailFollow`, ohne beim Scrollen die Ansicht neu zu bauen.
private final class TailBox {
    var value = TailFollow()
}

private let scrollSpace = NamedCoordinateSpace.named("following-scroll")
private let scrollEnd = "following-scroll-end"

/// Scrollbereich für die laufende Zeitleiste: neue Einträge erscheinen unten, ohne dass man nachscrollen muss –
/// außer man liest gerade weiter oben.
struct FollowingScroll<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var tail = TailBox()

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        content
                        Color.clear.frame(height: 1).id(scrollEnd)
                    }
                    // Als Overlay: Aus einem Hintergrund kommt der Wert bei ScrollView-Inhalt nicht an.
                    .overlay(GeometryReader { inner in
                        Color.clear.preference(key: ScrollMetricsKey.self,
                                               value: ScrollMetrics(offset: -inner.frame(in: scrollSpace).minY, content: inner.size.height))
                    }.allowsHitTesting(false))
                }
                .coordinateSpace(scrollSpace)
                .onPreferenceChange(ScrollMetricsKey.self) { metrics in
                    if tail.value.update(offset: metrics.offset, content: metrics.content, viewport: outer.size.height) { scrollToEnd(proxy) }
                }
                .onChange(of: outer.size.height) { _, height in
                    if tail.value.resize(to: height) { scrollToEnd(proxy) }
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            guard tail.value.following else { return }  // inzwischen hat jemand nach oben gescrollt
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(scrollEnd, anchor: .bottom) }
        }
    }
}
