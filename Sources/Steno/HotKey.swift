import CoreGraphics

/// Die Taste, die man zum Diktieren hält. Nur Tasten, die allein gedrückt nichts tippen –
/// so kann Steno sie beobachten, ohne sie anderen Apps wegzunehmen.
enum HotKey: String, CaseIterable, Identifiable {
    case leftOption, rightOption, rightCommand, leftControl, rightControl, rightShift, function

    var id: String { rawValue }

    /// Beim Druck gemeldeter Tastencode.
    var keyCode: Int64 {
        switch self {
        case .leftOption: return 58
        case .rightOption: return 61
        case .rightCommand: return 54
        case .leftControl: return 59
        case .rightControl: return 62
        case .rightShift: return 60
        case .function: return 63
        }
    }

    /// Welches Bit in den Ereignis-Flags anzeigt, dass genau diese Taste unten ist
    /// (die „Device“-Bits unterscheiden links und rechts).
    var flag: UInt64 {
        switch self {
        case .leftOption: return 0x20       // NX_DEVICELALTKEYMASK
        case .rightOption: return 0x40      // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10     // NX_DEVICERCMDKEYMASK
        case .leftControl: return 0x01      // NX_DEVICELCTLKEYMASK
        case .rightControl: return 0x2000   // NX_DEVICERCTLKEYMASK
        case .rightShift: return 0x04       // NX_DEVICERSHIFTKEYMASK
        case .function: return CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// Alle Tasten-Bits links und rechts für ⌃ ⇧ ⌘ ⌥ – um zu erkennen, ob noch etwas anderes gehalten wird.
    static let modifierFlags: UInt64 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20 | 0x40 | 0x2000

    /// Beschriftung für die Tastenkappe.
    var symbol: String {
        switch self {
        case .leftOption, .rightOption: return "⌥"
        case .rightCommand: return "⌘"
        case .leftControl, .rightControl: return "⌃"
        case .rightShift: return "⇧"
        case .function: return "fn"
        }
    }

    var name: String {
        switch self {
        case .leftOption: return L("Linke Option-Taste ⌥")
        case .rightOption: return L("Rechte Option-Taste ⌥")
        case .rightCommand: return L("Rechte Befehlstaste ⌘")
        case .leftControl: return L("Linke Control-Taste ⌃")
        case .rightControl: return L("Rechte Control-Taste ⌃")
        case .rightShift: return L("Rechte Umschalttaste ⇧")
        case .function: return L("Globus- bzw. fn-Taste")
        }
    }

    /// Kurz, für Meldungen: „linke ⌥“.
    var shortName: String {
        switch self {
        case .leftOption: return L("linke ⌥")
        case .rightOption: return L("rechte ⌥")
        case .rightCommand: return L("rechte ⌘")
        case .leftControl: return L("linke ⌃")
        case .rightControl: return L("rechte ⌃")
        case .rightShift: return L("rechte ⇧")
        case .function: return "fn"
        }
    }

    /// Wo die Taste liegt – für die Übung im Assistenten.
    var location: String {
        switch self {
        case .leftOption: return L("unten links, neben „ctrl“")
        case .rightOption: return L("rechts neben der Leertaste und der rechten ⌘-Taste")
        case .rightCommand: return L("direkt rechts neben der Leertaste")
        case .leftControl: return L("unten links, zweite Taste von links")
        case .rightControl: return L("nur auf externen Tastaturen, unten rechts")
        case .rightShift: return L("rechts über den Pfeiltasten")
        case .function: return L("ganz unten links, mit dem Globus")
        }
    }

    /// Was man über die Taste wissen sollte.
    var note: String? {
        switch self {
        case .leftOption: return L("Kurze Kürzel wie ⌥L für @ lösen kein Diktat aus.")
        case .rightOption: return L("Praktisch, wenn du links ⌥ für Sonderzeichen wie @ brauchst.")
        case .rightCommand, .rightShift: return L("Kurze Kürzel mit dieser Taste lösen kein Diktat aus.")
        case .leftControl: return L("Wer oft mit ⌃-Klick arbeitet, startet damit leicht versehentlich eine Aufnahme.")
        case .rightControl: return L("MacBook-Tastaturen haben keine rechte Control-Taste.")
        case .function: return L("Stell in den Systemeinstellungen › Tastatur „🌐-Taste drücken für“ auf „Keine Aktion“, sonst öffnet macOS zusätzlich Emojis oder die Apple-Diktierfunktion.")
        }
    }
}
