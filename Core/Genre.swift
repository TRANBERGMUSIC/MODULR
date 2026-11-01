// MODULR – kerne: forslag til genre (de brede: Techno, Tech House, House, Trance …) og pænere navne.
// Genren gættes ud fra lyden (tempo, bas/mellem/diskant, energi, dynamik) – og når du har sange med genre
// i biblioteket, lærer den af dem (de nærmeste sange i lyd bestemmer). Du kan altid rette selv.

import Foundation

enum GenreGuess {
    /// De brede genrer appen foreslår (og som menuen viser).
    static let general = ["Techno", "Hard Techno", "Melodic Techno", "Tech House", "House", "Deep House",
                          "Afro House", "Progressive House", "Trance", "Drum & Bass", "Dubstep", "Hardstyle",
                          "Disco", "Hip Hop", "Pop", "Minimal"]

    /// En detaljeret genre (fra Beatport-tags osv.) → den brede. nil = kan ikke placeres.
    static func normalize(_ raw: String?) -> String? {
        guard let r = raw?.lowercased().trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
        let rules: [(String, [String])] = [
            ("Hard Techno", ["hard techno", "hardtechno", "industrial techno", "schranz"]),
            ("Melodic Techno", ["melodic house & techno", "melodic techno", "melodic house and techno"]),
            ("Tech House", ["tech house", "techhouse", "tech-house"]),
            ("Minimal", ["minimal", "deep tech"]),
            ("Techno", ["techno", "peak time", "driving", "raw / deep / hypnotic", "hypnotic"]),
            ("Afro House", ["afro house", "afro", "amapiano"]),
            ("Deep House", ["deep house", "lofi house", "lo-fi house"]),
            ("Progressive House", ["progressive"]),
            ("Trance", ["trance", "psy"]),
            ("Drum & Bass", ["drum & bass", "drum and bass", "dnb", "d&b", "jungle", "liquid"]),
            ("Dubstep", ["dubstep", "riddim", "bass music", "140"]),
            ("Hardstyle", ["hardstyle", "hardcore", "hard dance", "gabber"]),
            ("Disco", ["disco", "nu disco", "funk"]),
            ("Hip Hop", ["hip hop", "hip-hop", "rap", "trap", "r&b"]),
            ("Pop", ["pop", "dance pop", "top 40"]),
            ("House", ["house", "garage", "bassline", "uk garage", "jackin", "funky house", "electro house"]),
        ]
        for (g, words) in rules where words.contains(where: { r.contains($0) }) { return g }
        return general.first { $0.lowercased() == r }
    }

    /// Lydens kendetegn – så sange kan sammenlignes. bands: 3 bytes pr. kolonne (bas, mellem, diskant).
    static func features(bands: [UInt8], bpm: Double, energy: Int?) -> [Double]? {
        let cols = bands.count / 3
        guard cols > 300, bpm > 0 else { return nil }
        var lo = 0.0, mi = 0.0, hi = 0.0
        var totals = [Double]()
        totals.reserveCapacity(cols / 15 + 1)
        var acc = 0.0, accN = 0
        for c in 0..<cols {
            let l = Double(bands[c * 3]), m = Double(bands[c * 3 + 1]), h = Double(bands[c * 3 + 2])
            lo += l; mi += m; hi += h
            acc += l + m + h
            accN += 1
            if accN == 150 { totals.append(acc / 150); acc = 0; accN = 0 }   // ét tal pr. sekund
        }
        let sum = max(1, lo + mi + hi)
        let mean = totals.reduce(0, +) / Double(max(1, totals.count))
        var varSum = 0.0
        for v in totals { varSum += (v - mean) * (v - mean) }
        let dyn = mean > 0 ? (varSum / Double(max(1, totals.count))).squareRoot() / mean : 0
        // Andel af tiden uden bas (breakdowns) – lang tid uden bas = trance/melodisk
        let quiet = Double(totals.filter { $0 < mean * 0.55 }.count) / Double(max(1, totals.count))
        return [bpm, lo / sum, mi / sum, hi / sum, Double(energy ?? 5), dyn, quiet]
    }

    /// Afstand mellem to sange (tempo vejer tungest, men dobbelt/halvt tempo regnes som tæt på).
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count >= 7 else { return .infinity }
        let r = a[0] / max(1, b[0])
        let tempoRatio = min(abs(log2(r)), abs(log2(r) - 1) + 0.15, abs(log2(r) + 1) + 0.15)
        let weights: [Double] = [0, 12, 12, 12, 0.35, 4, 4]
        var d: Double = (tempoRatio * 40) * (tempoRatio * 40)      // 1 % tempo ≈ 0,6
        for i in 1..<7 {
            let x: Double = (a[i] - b[i]) * weights[i]
            d += x * x
        }
        return d.squareRoot()
    }

    /// Ud fra dine egne sange med genre: de 7 nærmeste stemmer (de tætteste tæller mest).
    static func fromLibrary(_ f: [Double], labeled: [(features: [Double], genre: String)]) -> (genre: String, confidence: Double)? {
        guard labeled.count >= 12 else { return nil }
        let near = labeled.map { (distance(f, $0.features), $0.genre) }.sorted { $0.0 < $1.0 }.prefix(7)
        var votes = [String: Double]()
        for (d, g) in near { votes[g, default: 0] += 1 / (0.3 + d) }
        let total = votes.values.reduce(0, +)
        guard let best = votes.max(by: { $0.value < $1.value }), total > 0 else { return nil }
        return (best.key, best.value / total)
    }

    /// Uden noget at lære af: regler ud fra tempo og lyd (vejledende).
    static func fromSound(_ f: [Double]) -> (genre: String, confidence: Double)? {
        guard f.count >= 7 else { return nil }
        var bpm = f[0]
        let lo = f[1], mi = f[2], hi = f[3], energy = f[4], quiet = f[6]
        if bpm < 95 && bpm > 60 && !(bpm >= 80 && bpm <= 100 && energy < 6) { bpm *= 2 }   // halvt tempo
        var s = [String: Double]()
        func add(_ g: String, _ v: Double) { s[g, default: 0] += v }
        func near(_ x: Double, _ a: Double, _ b: Double) -> Double {
            if x >= a && x <= b { return 1 }
            let d = x < a ? a - x : x - b
            return max(0, 1 - d / 4)
        }
        add("Drum & Bass", 2.2 * near(bpm, 165, 178))
        // 140–160 BPM med fire-på-gulvet er langt oftest hård techno – dubstep og hardstyle er sjældne i en
        // techno-samling og kræver mere end tempoet (dubstep: halvt tempo og lange pauser uden kick)
        add("Hard Techno", 2.2 * near(bpm, 138, 165) * (energy >= 6 ? 1 : 0.75))
        add("Hardstyle", 0.7 * near(bpm, 150, 160) * (hi > 0.32 && energy >= 8 ? 1 : 0.3))
        add("Dubstep", 0.6 * near(bpm, 138, 150) * (lo > 0.45 && quiet > 0.3 ? 1 : 0.2))
        add("Trance", 1.5 * near(bpm, 132, 142) * (mi + hi > 0.55 ? 1 : 0.6) * (quiet > 0.12 ? 1.1 : 0.7))
        add("Techno", 1.6 * near(bpm, 128, 138) * (energy >= 6 ? 1 : 0.7) * (mi < 0.36 ? 1 : 0.7))
        add("Melodic Techno", 1.2 * near(bpm, 120, 126) * (mi > 0.34 ? 1 : 0.5) * (quiet > 0.15 ? 1 : 0.6))
        add("Tech House", 1.5 * near(bpm, 124, 128) * (lo > 0.40 ? 1 : 0.7) * (mi < 0.36 ? 1 : 0.75))
        add("House", 1.3 * near(bpm, 118, 126) * (mi > 0.33 ? 1 : 0.75))
        add("Deep House", 1.1 * near(bpm, 114, 122) * (energy <= 5 ? 1 : 0.5))
        add("Afro House", 0.9 * near(bpm, 118, 123) * (hi > 0.30 ? 1 : 0.6))
        add("Progressive House", 1.0 * near(bpm, 122, 128) * (quiet > 0.18 ? 1 : 0.5) * (mi > 0.34 ? 1 : 0.7))
        add("Disco", 0.9 * near(bpm, 110, 122) * (mi > 0.36 ? 1 : 0.5) * (lo < 0.40 ? 1 : 0.6))
        add("Hip Hop", 1.4 * near(f[0], 80, 100) * (energy < 7 ? 1 : 0.6))
        add("Pop", 0.8 * near(f[0], 96, 124) * (mi > 0.38 ? 1 : 0.4))
        let total = s.values.reduce(0, +)
        guard let best = s.max(by: { $0.value < $1.value }), best.value > 0.4, total > 0 else { return nil }
        return (best.key, best.value / total)
    }
}

/// Pænere navne: "01_artist_-_titel_(original_mix)_[www.xyz.com]" → "Artist", "Titel (Original Mix)".
enum NameCleaner {
    static let junkWords = ["www.", ".com", ".net", ".org", "free download", "free dl", "out now", "premiere",
                            "official video", "official audio", "official music", "kbps", "320", "lyrics", "lyric video",
                            "visualizer", "[hq]", "(hq)", "[hd]", "(hd)", "full version"]

    static func suggest(artist rawArtist: String, title rawTitle: String, fileName: String) -> (artist: String, title: String)? {
        var artist = clean(rawArtist)
        var title = clean(rawTitle.isEmpty ? (fileName as NSString).deletingPathExtension : rawTitle)
        // "Kunstner - Titel" i titlen
        if let r = title.range(of: " - ") {
            let left = String(title[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if artist.isEmpty || left.lowercased() == artist.lowercased() {
                if !left.isEmpty, !right.isEmpty { artist = left; title = right }
            }
        }
        artist = fixCase(artist)
        title = fixCase(title)
        guard !title.isEmpty else { return nil }
        if artist == rawArtist && title == rawTitle { return nil }
        return (artist, title)
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "_", with: " ")
        // Spornummer i starten: "01 ", "01. ", "01 - ", "A1 "
        // (kun med foranstillet 0 eller skilletegn, så "99 Problems" får lov at være)
        if let r = t.range(of: #"^\s*(?:0\d{1,2}|[A-D]\d)\s*[.)\-–]?\s+|^\s*\d{1,2}\s*[.)\-–]\s+"#, options: .regularExpression) { t.removeSubrange(r) }
        // Parenteser/klammer med skrald fjernes, men versionen beholdes ("Extended Mix", "Remix" …)
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#, #"\{[^}]*\}"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = t as NSString
            let matches = re.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                let part = ns.substring(with: m.range).lowercased()
                if junkWords.contains(where: { part.contains($0) }) {
                    t = (t as NSString).replacingCharacters(in: m.range, with: "")
                }
            }
        }
        // Løse skrald-ord uden parentes
        for w in ["www.", "free download"] where t.lowercased().contains(w) {
            if let r = t.range(of: w, options: .caseInsensitive) { t = String(t[..<r.lowerBound]) }
        }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " -–_.")).trimmingCharacters(in: .whitespaces)
    }

    /// KUN STORE eller kun små bogstaver → Hvert Ord Med Stort (blandet skrift røres ikke).
    static func fixCase(_ s: String) -> String {
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 3 else { return s }
        let allUpper = letters == letters.uppercased(), allLower = letters == letters.lowercased()
        guard allUpper || allLower else { return s }
        let small: Set<String> = ["feat.", "ft.", "x", "vs.", "&", "and", "of", "the", "a", "in"]
        let words = s.lowercased().split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var out = [String]()
        for (i, word) in words.enumerated() {
            if i > 0 && small.contains(word) { out.append(word); continue }
            // Første bogstav med stort – også efter en parentes: "(extended" → "(Extended"
            if let i = word.firstIndex(where: { $0.isLetter }) {
                out.append(String(word[..<i]) + String(word[i]).uppercased() + String(word[word.index(after: i)...]))
            } else {
                out.append(word)
            }
        }
        return out.joined(separator: " ")
    }
}
