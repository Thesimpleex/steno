import AppKit
import SwiftUI

// Gestaltung für alle Fenster: helle Flächen, Tinte (Schwarz bzw. im Dunkelmodus Weiß) für Hauptaktionen,
// Markenrot aus dem App-Symbol als Akzent.

enum Theme {
    static let accent = Color(red: 1.0, green: 0.29, blue: 0.24)
    /// Rot für Schrift: im Hellen dunkler, damit es gut lesbar bleibt (Kontrast ≥ 4,5 : 1).
    static let accentText = dynamic(light: NSColor(srgbRed: 0.78, green: 0.18, blue: 0.14, alpha: 1),
                                    dark: NSColor(srgbRed: 1.0, green: 0.42, blue: 0.36, alpha: 1))
    static let accentGradient = LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.30), Color(red: 1, green: 0.22, blue: 0.24)],
                                               startPoint: .top, endPoint: .bottom)
    static let ink = dynamic(light: NSColor(white: 0.08, alpha: 1), dark: NSColor(white: 0.95, alpha: 1))
    static let onInk = dynamic(light: .white, dark: NSColor(white: 0.08, alpha: 1))
    static let page = dynamic(light: NSColor(white: 0.985, alpha: 1), dark: NSColor(white: 0.085, alpha: 1))
    static let card = dynamic(light: .white, dark: NSColor(white: 0.135, alpha: 1))
    /// Vertiefte Flächen: Eingabefelder, Tab-Schiene, Chips.
    static let well = dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.07))
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
    static let shadow = dynamic(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 0, alpha: 0.25))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

// MARK: - Flächen und Überschriften

/// Weiße Karte mit feiner Kante; der Schatten liegt nur unter der Fläche, nicht unter dem Text.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: Theme.shadow, radius: 8, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    func card(padding: CGFloat = 18) -> some View { modifier(CardStyle(padding: padding)) }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3)
                Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
    }
}

/// Zeile in einer Karte: Titel und Erklärung links, Bedienelement rechts.
struct Row<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct RowDivider: View {
    var inset: CGFloat = 16

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset)
    }
}

/// Hinweistext unter einer Karte.
struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - Bedienelemente

/// Kapsel-Knopf: Tinte für die Hauptaktion, zart hinterlegt für alles andere.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind = Kind.secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, kind: kind, large: large)
    }

    private struct Label: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let large: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: large ? 13.5 : 12.5, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, large ? 18 : 12)
                .frame(height: large ? 34 : 28)
                .foregroundStyle(kind == .primary ? Theme.onInk : kind == .destructive ? Color.red : Color.primary)
                .background(kind == .primary ? Theme.ink : Theme.well, in: Capsule())
                .contentShape(Capsule())
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static func pill(_ kind: PillButtonStyle.Kind, large: Bool = false) -> PillButtonStyle { PillButtonStyle(kind: kind, large: large) }
}

/// Auswahlmenü als ruhige Kapsel statt des Systemknopfs mit farbigem Pfeil; die gewählte Zeile trägt ein Häkchen.
struct PillPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Text(options.first { $0.value == selection }?.label ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Theme.well, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
        .accessibilityValue(options.first { $0.value == selection }?.label ?? "")
    }
}

/// Eingabefeld mit ruhiger Fläche und feinem Rand, solange es aktiv ist.
struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onSubmit(onSubmit)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.primary.opacity(0.28) : Color.clear))
    }
}

struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField(L("Durchsuchen"), text: $text, prompt: Text(L("Durchsuchen"))).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Suche leeren"))
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 11)
        .frame(width: 220, height: 32)
        .background(Theme.well, in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(focused ? Color.primary.opacity(0.28) : Color.clear))
    }
}

/// Wort im Wörterbuch als entfernbare Kapsel.
struct Chip: View {
    let text: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L("Entfernen"))
            .accessibilityLabel(L("%@ entfernen", text))
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Theme.well, in: Capsule())
        .onHover { hovering = $0 }
    }
}

/// Reiht Elemente nebeneinander und bricht um, wenn die Zeile voll ist.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var items: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !items.isEmpty, x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing
                items = []
                x = 0
                height = 0
            }
            items.append(index)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}

// MARK: - Symbole

/// Rundes Symbol auf zart getönter Fläche. Als Schrift gesetzt, nicht skaliert – so sitzt es optisch mittig.
struct IconBadge: View {
    let symbol: String
    var color = Theme.accent
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let ok: Bool

    var body: some View {
        Circle().fill(ok ? Color.green : .orange).frame(width: 7, height: 7)
    }
}

/// Eine Taste wie auf der Tastatur: Kappe mit feiner Kante und kleinem Schatten nach unten.
struct KeyCap: View {
    let key: String
    var large = false
    var onDark = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: large ? 7 : 5, style: .continuous)
        Text(key)
            .font(.system(size: large ? 15 : 12, weight: .medium))
            .foregroundStyle(onDark ? Color.white : .primary)
            .frame(minWidth: large ? 34 : 24, minHeight: large ? 30 : 22)
            .padding(.horizontal, large ? 6 : 4)
            .background {
                shape.fill(onDark ? Color.white.opacity(0.14) : Theme.card)
                    .shadow(color: .black.opacity(onDark ? 0.5 : 0.16), radius: 0, y: 1)
            }
            .overlay(shape.strokeBorder(onDark ? Color.white.opacity(0.18) : Theme.hairline))
    }
}

struct KeyCombo: View {
    let keys: [String]
    var large = false

    var body: some View {
        HStack(spacing: 4) { ForEach(keys.indices, id: \.self) { KeyCap(key: keys[$0], large: large) } }
    }
}

/// Das Logo als Vektor: fünf Pegelbalken, der mittlere in Signalrot.
struct WaveMark: View {
    var bars = Color.white

    var body: some View {
        GeometryReader { geo in
            let unit = min(geo.size.width / 520, geo.size.height / 470)  // Maße wie im App-Symbol
            let heights: [CGFloat] = [190, 330, 470, 330, 190]
            HStack(spacing: 50 * unit) {
                ForEach(heights.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == 2 ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(bars))
                        .frame(width: 64 * unit, height: heights[i] * unit)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Taste

/// Auswahl der Diktier-Taste: Tastenkappe als Vorschau, daneben das Menü.
struct HotKeyPicker: View {
    @Binding var selection: HotKey
    var compact = false

    var body: some View {
        HStack(spacing: 14) {
            KeyCap(key: selection.symbol, large: true).frame(width: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Diktier-Taste")).font(.system(size: 13.5))
                if !compact {
                    Text(L("Halten zum Diktieren, zweimal tippen zum freihändigen Diktieren."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            PillPicker(title: L("Diktier-Taste"), selection: $selection, options: HotKey.allCases.map { ($0, $0.name) })
        }
    }
}

// MARK: - Fenster

/// Leere Flächen der eigenen Titelleiste: Fenster ziehen, Doppelklick wie in den Systemeinstellungen festgelegt.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
