import Foundation

/// Künstlicher Ton in 16 kHz. Sprache: Silben aus einem 220-Hz-Ton mit kurzen Lücken, wie gesprochene Sprache sie hat.
/// Stille: ein leises Summen, denn ganz still ist kein Mikrofon.
enum TestAudio {
    static func speech(_ seconds: Double, loudness: Float = 0.2, hum: Float = 0.001) -> [Float] {
        samples(seconds) { t in
            let syllable = t.truncatingRemainder(dividingBy: 0.26) < 0.2
            return (syllable ? loudness * Float(sin(2 * .pi * 220 * t)) : 0) + hum * Float(sin(2 * .pi * 3_000 * t))
        }
    }

    static func silence(_ seconds: Double, hum: Float = 0.001) -> [Float] {
        samples(seconds) { t in hum * Float(sin(2 * .pi * 3_000 * t)) }
    }

    private static func samples(_ seconds: Double, _ value: (Double) -> Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { value(Double($0) / 16_000) }
    }
}
