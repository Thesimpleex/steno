import AppKit

/// Hält Spotify und Apple Music während einer Aufnahme an und spielt danach weiter –
/// aber nur, was vorher wirklich lief. Beim ersten Mal fragt macOS nach der Erlaubnis.
final class MediaPause {
    private static let players = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]
    private let queue = DispatchQueue(label: "steno.media")  // osascript braucht ein paar Millisekunden
    private var paused: [String] = []

    func pause() {
        guard Settings.pauseMusic else { return }
        let running = Self.players.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.key).isEmpty }
        queue.async {
            for player in running.values {
                let result = Self.osascript("""
                    tell application "\(player)"
                        if player state is playing then
                            pause
                            return "paused"
                        end if
                    end tell
                    """)
                if result == "paused" { self.paused.append(player) }
            }
        }
    }

    func resume() {
        queue.async { self.playPaused() }
    }

    /// Beim Beenden: warten, bis wirklich weitergespielt wird.
    func resumeNow() {
        queue.sync { playPaused() }
    }

    private func playPaused() {
        // Nur weiterspielen, wenn der Player noch läuft – sonst würde er neu gestartet.
        paused.forEach { _ = Self.osascript("if application \"\($0)\" is running then tell application \"\($0)\" to play") }
        paused.removeAll()
    }

    private static func osascript(_ script: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
