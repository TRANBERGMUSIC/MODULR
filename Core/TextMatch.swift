// MODULR – kerne: normalisering af titler/kunstnere, versioner (remix, edit …) og fuzzy match.
// Kun Foundation.

import Foundation

/// Det appen ved om sangen: titel uden version, kunstnere, version, varighed og evt. id'er.
struct TrackIdentity: Codable, Equatable {
    var title: String
    var artists: [String]
    var version: String?
    var duration: Double
    var isrc: String?
    var musicBrainzID: String?

    var displayName: String {
        let v = version.map { " (\($0))" } ?? ""
        return "\(artists.joined(separator: ", ")) – \(title)\(v)"
    }

    /// Nøgle til cache (24 t) – samme sang giver samme nøgle.
    var cacheKey: String {
        let a = artists.map(TextMatch.normalize).sorted().joined(separator: ",")
        return "\(a)|\(TextMatch.normalize(title))|\(TextMatch.normalizeVersion(version) ?? "")|\(Int(duration.rounded()))"
    }
}

enum TextMatch {
    static let versionWords: Set<String> = [
        "remix", "rmx", "edit", "extended", "radio", "vip", "dub", "instrumental", "mix", "rework",
        "bootleg", "flip", "acapella", "acappella", "club", "version", "live", "remaster", "remastered",
        "cut", "reprise", "refix", "mashup", "intro", "outro", "clean", "dirty", "sped", "slowed",
    ]

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                  locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Små bogstaver, uden accenter, "&" → "and", uden tegnsætning, ét mellemrum.
    static func normalize(_ s: String) -> String {
        var t = fold(s)
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return t.split(separator: " ").joined(separator: " ")
    }

    static func words(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    static func isVersionText(_ s: String) -> Bool {
        words(s).contains { versionWords.contains($0) }
    }

    static func isFeatText(_ s: String) -> Bool {
        let w = words(s)
        return w.first.map { ["feat", "ft", "featuring", "with"].contains($0) } ?? false
    }

    /// Ensartet version: "Original Mix" → nil, "Extended Mix" → "extended", "Radio Edit" → "radio edit".
    static func normalizeVersion(_ v: String?) -> String? {
        guard let v else { return nil }
        var w = words(v)
        if w.isEmpty { return nil }
        if w == ["original"] || w == ["original", "mix"] || w == ["original", "version"] { return nil }
        if w.count > 1 { w.removeAll { $0 == "mix" || $0 == "version" } }
        let out = w.joined(separator: " ")
        return out.isEmpty ? nil : out
    }

    /// Deler en rå titel i titel + version og fjerner "(feat. X)".
    /// "Losing It (Extended Mix)" → ("Losing It", "Extended Mix").
    static func splitVersion(_ raw: String) -> (base: String, version: String?) {
        var base = raw
        var versions = [String]()

        if let re = try? NSRegularExpression(pattern: #"\s*[\(\[]([^\)\]]*)[\)\]]"#) {
            let matches = re.matches(in: base, range: NSRange(location: 0, length: (base as NSString).length))
            for m in matches.reversed() {
                let ns = base as NSString
                let inner = ns.substring(with: m.range(at: 1))
                if isVersionText(inner) {
                    versions.insert(inner, at: 0)
                    base = ns.replacingCharacters(in: m.range, with: "")
                } else if isFeatText(inner) {
                    base = ns.replacingCharacters(in: m.range, with: "")
                }
            }
        }
        // "Titel - Extended Mix"
        let dashParts = base.components(separatedBy: " - ")
        if dashParts.count >= 2, let last = dashParts.last, isVersionText(last) {
            versions.append(last)
            base = dashParts.dropLast().joined(separator: " - ")
        }
        // "Titel feat. X" uden parentes
        if let r = base.range(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, options: [.regularExpression, .caseInsensitive]) {
            base.removeSubrange(r)
        }
        let v = versions.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (base.trimmingCharacters(in: .whitespacesAndNewlines), v.isEmpty ? nil : v)
    }

    /// Deler en kunstner-streng i de enkelte kunstnere.
    static func splitArtists(_ raw: String) -> [String] {
        var s = " " + raw + " "
        for sep in [" feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", " x ", " X ", " and ", " vs. ", " vs ", ", ", " with "] {
            s = s.replacingOccurrences(of: sep, with: "|", options: .caseInsensitive)
        }
        return s.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Levenshtein-baseret lighed 0…1 på normaliseret tekst.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(normalize(a)), y = Array(normalize(b))
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Bedste lighed mellem to sæt kunstnere (hovedkunstneren skal matche).
    static func artistSimilarity(_ a: [String], _ b: [String]) -> Double {
        var best = 0.0
        for x in a.flatMap(splitArtists) {
            for y in b.flatMap(splitArtists) {
                best = max(best, similarity(x, y))
            }
        }
        // Hele strengen kan også matche ("Above & Beyond")
        best = max(best, similarity(a.joined(separator: " "), b.joined(separator: " ")))
        return best
    }
}

// MARK: - Kandidat-matchning

enum MatchResult: Equatable {
    case match(score: Double)
    case otherVersion(String)
    case noMatch(String)

    var isMatch: Bool { if case .match = self { return true }; return false }
    var isOtherVersion: Bool { if case .otherVersion = self { return true }; return false }
}

enum Matcher {
    static let threshold = 0.9
    static let durationTolerance = 3.0

    /// Deler fx SoundCloud-titlen "Fisher - Losing It (Extended Mix)" op, når uploaderen er et label.
    static func parse(rawTitle: String, rawArtist: String, identity: TrackIdentity) -> (artists: [String], title: String, version: String?) {
        var artists = [rawArtist]
        var title = rawTitle
        let parts = rawTitle.components(separatedBy: " - ")
        if parts.count >= 2 {
            let prefix = parts[0]
            let rest = parts.dropFirst().joined(separator: " - ")
            let prefixMatchesArtist = TextMatch.artistSimilarity([prefix], identity.artists) >= threshold
            let uploaderMatches = TextMatch.artistSimilarity([rawArtist], identity.artists) >= threshold
            if prefixMatchesArtist || !uploaderMatches {
                artists = [prefix]
                title = rest
            }
        }
        let split = TextMatch.splitVersion(title)
        return (artists, split.base, split.version)
    }

    static func evaluate(rawTitle: String, rawArtist: String, duration: Double?, isrc: String?,
                         against identity: TrackIdentity) -> MatchResult {
        let p = parse(rawTitle: rawTitle, rawArtist: rawArtist, identity: identity)
        let titleSim = TextMatch.similarity(p.title, identity.title)
        let artistSim = TextMatch.artistSimilarity(p.artists, identity.artists)
        let sameISRC = isrc != nil && identity.isrc != nil &&
            TextMatch.normalize(isrc!) == TextMatch.normalize(identity.isrc!)

        if !sameISRC {
            if titleSim < threshold { return .noMatch("Titlen passer ikke (\(Int(titleSim * 100)) %)") }
            if artistSim < threshold { return .noMatch("Kunstneren passer ikke (\(Int(artistSim * 100)) %)") }
        }
        let candVersion = TextMatch.normalizeVersion(p.version)
        let ownVersion = TextMatch.normalizeVersion(identity.version)
        if candVersion != ownVersion {
            return .otherVersion("Anden version: \(p.version ?? "original") i stedet for \(identity.version ?? "original")")
        }
        if let d = duration, identity.duration > 0, abs(d - identity.duration) > durationTolerance {
            let diff = Int((d - identity.duration).rounded())
            return .otherVersion("Anden længde (\(diff > 0 ? "+" : "")\(diff) s) – sandsynligvis en anden version")
        }
        let score = sameISRC ? 1.0 : (titleSim + artistSim) / 2
        return .match(score: score)
    }
}
