// MODULR – kerne: tonearter i Camelot-notation (1A–12B), klassisk notation og farver.
// Kun Foundation.

import Foundation

struct MusicalKey: Codable, Equatable, Hashable {
    var pitchClass: Int      // tonika, C = 0 … B = 11
    var minor: Bool

    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let minorNames = ["Cm", "C#m", "Dm", "D#m", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    /// Camelot-nummer 1–12.
    var camelotNumber: Int {
        let major = minor ? (pitchClass + 3) % 12 : pitchClass
        return (7 * major + 7) % 12 + 1
    }

    /// "8A" (mol) / "8B" (dur).
    var camelot: String { "\(camelotNumber)\(minor ? "A" : "B")" }

    /// Klassisk: "Am", "C", "F#m" …
    var classic: String { minor ? Self.minorNames[pitchClass] : Self.names[pitchClass] }

    init(pitchClass: Int, minor: Bool) {
        self.pitchClass = ((pitchClass % 12) + 12) % 12
        self.minor = minor
    }

    init?(camelotNumber n: Int, minor: Bool) {
        guard (1...12).contains(n) else { return nil }
        // Omvendt af n = (7p + 7) % 12 + 1  →  p = 7(n − 1) − 1 (mod 12), da 7 · 7 ≡ 1 (mod 12)
        let major = ((7 * (n - 1) - 1) % 12 + 12) % 12
        self.init(pitchClass: minor ? (major + 9) % 12 : major, minor: minor)
    }

    /// Læser tonearter fra tags: "8A", "08A", "Am", "A minor", "Abm", "G#", "Bb major", Open Key "1m"/"1d".
    static func parse(_ raw: String?) -> MusicalKey? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        // Mixed In Key skriver fx "8A - Energy 6" i kommentaren
        if let r = s.range(of: #"^\s*(\d{1,2})\s*([ABab])\b"#, options: .regularExpression) {
            let m = String(s[r]).trimmingCharacters(in: .whitespaces)
            let n = Int(m.dropLast()) ?? 0
            return MusicalKey(camelotNumber: n, minor: m.last!.uppercased() == "A")
        }
        // Open Key: 1m … 12m / 1d … 12d
        if let r = s.range(of: #"^\s*(\d{1,2})\s*([mdMD])\s*$"#, options: .regularExpression) {
            let m = String(s[r]).trimmingCharacters(in: .whitespaces)
            guard let n = Int(m.dropLast()), (1...12).contains(n) else { return nil }
            return MusicalKey(camelotNumber: (n + 6) % 12 + 1, minor: m.last!.lowercased() == "m")
        }
        s = s.replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        guard let first = s.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][first] else {
            return nil
        }
        var rest = String(s.dropFirst())
        var pc = base
        if rest.hasPrefix("#") { pc += 1; rest.removeFirst() }
        else if rest.hasPrefix("b") { pc -= 1; rest.removeFirst() }
        let low = rest.trimmingCharacters(in: .whitespaces).lowercased()
        // Kun rene tonearts-navne: "Am", "A minor", "Amaj" – ikke fx "Amazing"
        let allowed = ["", "m", "min", "minor", "maj", "major", "dur", "moll"]
        guard allowed.contains(low) else { return nil }
        let minor = low.hasPrefix("m") && !low.hasPrefix("maj") || low.hasPrefix("min")
        guard low.isEmpty || low.hasPrefix("m") || low.hasPrefix("maj") || low.hasPrefix("min") || low.hasPrefix("dur") || low.hasPrefix("moll") else {
            return nil
        }
        return MusicalKey(pitchClass: pc, minor: minor || low.hasPrefix("moll"))
    }

    /// Nabotonearter der mixer harmonisk: samme nummer (A/B), ±1.
    var compatible: [MusicalKey] {
        let n = camelotNumber
        let up = n % 12 + 1, down = (n + 10) % 12 + 1
        return [MusicalKey(camelotNumber: n, minor: !minor), MusicalKey(camelotNumber: up, minor: minor),
                MusicalKey(camelotNumber: down, minor: minor)].compactMap { $0 }
    }

    /// Farvetone (0–360) rundt om Camelot-hjulet, som i Mixed In Key.
    var hue: Double {
        let h = 180 - 25 * Double(camelotNumber % 12)
        return h < 0 ? h + 360 : h
    }
}

/// Kvalitetsfarve: rød ≤ 160 kbps, gul ≤ 256 kbps, grøn ved 320 og lossless.
enum QualityColor: String, Codable {
    case red, yellow, green

    static func forTier(_ kbps: Int) -> QualityColor {
        if kbps >= 320 { return .green }
        if kbps >= 192 { return .yellow }
        return .red
    }
}
