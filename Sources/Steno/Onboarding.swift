import AppKit
import SwiftUI

/// Einrichtungs-Assistent beim ersten Start: Sprache wählen, Modell laden, Freigaben erteilen, ausprobieren.
final class Onboarding: NSObject, NSWindowDelegate {
    static var completed: Bool {
        get { UserDefaults.standard.bool(forKey: "einrichtungFertig") }
        set { UserDefaults.standard.set(newValue, forKey: "einrichtungFertig") }
    }

    private var window: NSWindow?
    private let state: AppState
    private let models: ModelStore

    init(state: AppState, models: ModelStore) {
        self.state = state
        self.models = models
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = L("Steno einrichten")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(state: state, models: models) { [weak self] autostart in
                Onboarding.completed = true
                self?.state.setAutostart(autostart)
                self?.window?.close()
            })
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        hideDockIconIfLastWindow(closing: notification.object as? NSWindow)
    }
}

/// Dock-Symbol nur ausblenden, wenn kein anderes Steno-Fenster mehr offen ist.
func hideDockIconIfLastWindow(closing: NSWindow?) {
    DispatchQueue.main.async {
        let otherOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
        if !otherOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

enum Step: Int, CaseIterable {
    case welcome, language, microphone, accessibility, model, practice, done
}

struct OnboardingView: View {
    @ObservedObject var state: AppState
    @ObservedObject var models: ModelStore
    let finish: (_ autostart: Bool) -> Void
    @State var step = Step.welcome
    @State var practice = ""
    @State var autostart = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .language: language
                case .model: model
                case .microphone: microphone
                case .accessibility: accessibility
                case .practice: practiceStep
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 52)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            .id(step)

            footer
        }
        .frame(width: 620, height: 600)
        .background(Theme.page)
        .tint(Theme.accent)
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    // MARK: Schritte

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(L("Sprechen statt tippen")).font(.system(size: 28, weight: .bold)).padding(.top, 14)
            Text(L("Taste halten, sprechen, loslassen – dein Text erscheint dort, wo der Cursor steht. In jeder App."))
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 18) {
                point("lock", L("Privat"), L("Deine Stimme und deine Texte bleiben auf deinem Mac."))
                point("bolt", L("Schnell"), L("Ein Satz ist in unter einer Sekunde fertig."))
                point("checkmark.seal", L("Kostenlos"), L("Open Source, ohne Konto und Abo."))
            }
            .frame(maxWidth: 400, alignment: .leading)
            .padding(.top, 34)
            Spacer()
        }
    }

    private var language: some View {
        stepLayout("globe", L("Welche Sprache sprichst du?"),
                   L("Lässt sich jederzeit in der Menüleiste ändern.")) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(SpeechLanguage.allCases.filter { $0 != .automatic }) { languageButton($0) }
            }
            .frame(width: 440)
            languageButton(.automatic).frame(width: 440)
            if let note = state.language.note {
                Text(note).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    private func languageButton(_ option: SpeechLanguage) -> some View {
        Button { state.language = option } label: {
            HStack(spacing: 10) {
                Text(option.flag).font(.title2)
                Text(option.name).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                if state.language == option {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(state.language == option ? Theme.accent.opacity(0.07) : Theme.card,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(state.language == option ? Theme.accent : Theme.hairline,
                              lineWidth: state.language == option ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(state.language == option ? .isSelected : [])
    }

    private var model: some View {
        stepLayout("arrow.down", L("Sprachmodell laden"),
                   L("Einmaliger Download von Hugging Face (1,6 GB). Danach arbeitet Steno komplett offline. Du kannst schon weitermachen – der Download läuft im Hintergrund.")) {
            if models.active != nil && !models.isDownloading {
                success(L("Geladen und bereit"))
            } else if models.hasAnyModel && !models.isDownloading && models.problem == nil {
                ProgressView(L("Wird geladen …")).controlSize(.small)
            } else {
                switch models.download {
                case .failed(_, let reason):
                    VStack(spacing: 10) {
                        Text(reason).foregroundStyle(.red).multilineTextAlignment(.center)
                        HStack {
                            Button(L("Erneut versuchen")) { models.retryNow() }.buttonStyle(.pill(.primary))
                            Button(L("Kleineres Modell laden (574 MB)")) { models.select(ModelCatalog.compact) }.buttonStyle(.pill)
                        }
                    }
                case .checking:
                    ProgressView(L("Wird geprüft …")).controlSize(.small)
                case .loading(let model, let received):
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(received), total: Double(model.bytes))
                        Text(L("%@ von %@", size(received), size(model.bytes)))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 380)
                case .idle:
                    if let problem = models.problem {
                        Text(problem).foregroundStyle(.red)
                    }
                    Button(L("Herunterladen")) { models.select(ModelCatalog.recommended) }
                        .buttonStyle(.pill(.primary, large: true))
                }
            }
            Text(L("Kleinere Modelle findest du später in den Einstellungen."))
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                .onAppear { models.prepare() }
        }
    }

    private var microphone: some View {
        stepLayout("mic.fill", L("Mikrofon erlauben"),
                   state.microphoneDenied ? L("Steno hört nur zu, solange du diktierst. Der Zugriff wurde abgelehnt – du kannst ihn in den Systemeinstellungen erlauben.")
                                          : L("Steno hört nur zu, solange du diktierst. Klicke unten und bestätige mit „Erlauben“.")) {
            if state.microphone {
                success(L("Mikrofon ist erlaubt"))
            } else if state.microphoneDenied {
                VStack(spacing: 12) {
                    Text(L("Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon: den Schalter neben „Steno“ einschalten."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L("Systemeinstellungen öffnen"), action: state.requestMicrophone).buttonStyle(.pill(.primary, large: true))
                }
            } else {
                Button(L("Mikrofon erlauben"), action: state.requestMicrophone).buttonStyle(.pill(.primary, large: true))
            }
        }
    }

    private var accessibility: some View {
        stepLayout("keyboard.fill", L("Bedienungshilfen erlauben"),
                   L("Damit Steno die Diktier-Taste erkennt und Text am Cursor einfügen kann, braucht es die Freigabe „Bedienungshilfen“. Tastendrücke werden nie gespeichert.")) {
            if state.accessibility {
                success(L("Erlaubt – alles bereit"))
            } else {
                VStack(spacing: 14) {
                    Button(L("Zugriff erlauben …"), action: state.requestAccessibility)
                        .buttonStyle(.pill(.primary, large: true))
                    VStack(alignment: .leading, spacing: 7) {
                        instruction(1, L("Im Hinweis von macOS „Systemeinstellungen öffnen“ wählen."))
                        instruction(2, L("Den Schalter neben „Steno“ einschalten."))
                        instruction(3, L("Falls gefragt, mit dem Mac-Passwort bestätigen – dann hierher zurückkehren."))
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var practiceStep: some View {
        stepLayout("hand.tap.fill", L("Jetzt ausprobieren"),
                   L("Klicke in das Feld, halte %@ (%@), sprich einen Satz und lass los.",
                     state.hotKey.symbol, state.hotKey.location)) {
            VStack(spacing: 12) {
                if !state.modelReady {
                    Label(L("Das Sprachmodell lädt noch. Du kannst warten oder diesen Schritt überspringen."),
                          systemImage: "hourglass")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HotKeyPicker(selection: $state.hotKey, compact: true)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .card(padding: 0)
                    .frame(width: 440)
                if state.hotKey == .function, let note = state.hotKey.note {
                    Text(note).font(.caption).foregroundStyle(.secondary).frame(width: 440, alignment: .leading)
                }
                TextField(L("Hier erscheint dein Text …"), text: $practice, axis: .vertical)
                    .lineLimit(3...5)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(12)
                    .frame(width: 440, alignment: .topLeading)
                    .frame(minHeight: 96, alignment: .topLeading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
                if !practice.trimmingCharacters(in: .whitespaces).isEmpty {
                    success(L("Funktioniert."))
                }
            }
        }
    }

    private var done: some View {
        stepLayout("checkmark", color: .green, L("Alles bereit"), L("Steno läuft jetzt in der Menüleiste und funktioniert in jeder App.")) {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 11) {
                    tip([state.hotKey.symbol], L("halten, sprechen, loslassen"))
                    tip([state.hotKey.symbol, state.hotKey.symbol], L("zweimal tippen zum freihändigen Diktieren, einmal zum Beenden"))
                    tip(["esc"], L("bricht ab – innerhalb von 3 s erneut drücken, um fortzusetzen"))
                    tip(["⌃", "⌥", "V"], L("fügt das letzte Diktat erneut ein"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16)
                Toggle(isOn: $autostart) { Text(L("Steno beim Anmelden öffnen")).frame(maxWidth: .infinity, alignment: .leading) }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .card(padding: 0)
            }
            .frame(width: 460)
        }
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Theme.ink : Color.primary.opacity(0.15))
                        .frame(width: s == step ? 18 : 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome, step != .done {
                Button(L("Zurück")) { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                    .buttonStyle(.pill(.secondary, large: true))
            }
            Button(nextTitle) {
                if step == .done { finish(autostart) } else { step = Step(rawValue: step.rawValue + 1) ?? .done }
            }
            .buttonStyle(.pill(.primary, large: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var nextTitle: String {
        switch step {
        case .done: return L("Los geht’s")
        case .practice where practice.isEmpty: return L("Überspringen")
        default: return L("Weiter")
        }
    }

    private var canContinue: Bool {
        switch step {
        case .microphone: return state.microphone
        case .accessibility: return state.accessibility
        default: return true  // Modell und Übung: der Download läuft auch ohne Warten weiter
        }
    }

    // MARK: Bausteine

    private func stepLayout<Content: View>(_ symbol: String, color: Color = Theme.accent, _ title: String, _ text: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            IconBadge(symbol: symbol, color: color, size: 68)
            Text(title).font(.system(size: 26, weight: .bold)).tracking(-0.3).padding(.top, 18)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.top, 8)
            content().padding(.top, 26)
            Spacer()
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func success(_ text: String) -> some View {
        Label {
            Text(text).font(.headline)
        } icon: {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.green)
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.12), in: Circle())
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 12) {
            KeyCombo(keys: keys).frame(width: 112, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
