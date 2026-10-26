// MODULR – kerne: artwork-bibliotekets data og matchning (hvilket cover hører til hvilken sang).
// Kun Foundation, så det kan testes.

import Foundation

struct ArtworkEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var artists: [String]
    var title: String
    var version: String?
    var imageFile: String          // filnavn i bibliotekets mappe
    var width: Int
    var height: Int
    var source: String             // "Fra fil: x.mp3", "iTunes", "Manuelt"
    var addedAt: Date
    var files: [String]            // filer coveret er lagt på (så de kan opdateres ved udskiftning)

    var displayName: String {
        let v = version.map { " (\($0))" } ?? ""
        let a = artists.isEmpty ? "Ukendt kunstner" : artists.joined(separator: ", ")
        return "\(a) – \(title)\(v)"
    }

    var pixels: Int { width * height }
}

/// Sangen en fil indeholder, ud fra tags eller filnavn.
struct SongInfo: Equatable {
    var artists: [String]
    var title: String
    var version: String?

    init(artists: [String], title: String, version: String?) {
        self.artists = artists
        self.title = title
        self.version = version
    }

    /// Fra rå tags/filnavn: "Losing It (Extended Mix)" → titel + version.
    init?(artist: String?, rawTitle: String?) {
        guard let raw = rawTitle?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let split = TextMatch.splitVersion(raw)
        guard !split.base.isEmpty else { return nil }
        self.artists = artist.map { TextMatch.splitArtists($0) } ?? []
        self.title = split.base
        self.version = split.version
    }
}

enum ArtworkMatcher {
    /// Versioner der typisk har deres EGET cover (remix af en anden kunstner osv.).
    static let ownCoverWords: Set<String> = ["remix", "rmx", "rework", "bootleg", "flip", "vip", "mashup", "refix"]

    static func hasOwnCover(_ version: String?) -> Bool {
        guard let v = version else { return false }
        return TextMatch.words(v).contains { ownCoverWords.contains($0) }
    }

    /// Hvor godt et cover passer til en sang (0 = slet ikke, 1 = perfekt).
    static func score(_ e: ArtworkEntry, for song: SongInfo) -> Double {
        let titleSim = TextMatch.similarity(e.title, song.title)
        guard titleSim >= 0.9 else { return 0 }
        var artistSim = 1.0
        if !e.artists.isEmpty && !song.artists.isEmpty {
            artistSim = TextMatch.artistSimilarity(e.artists, song.artists)
            guard artistSim >= 0.9 else { return 0 }
        } else if e.artists.isEmpty != song.artists.isEmpty {
            artistSim = 0.92   // den ene mangler kunstner – kun titlen kan sammenlignes
        }
        let ev = TextMatch.normalizeVersion(e.version)
        let sv = TextMatch.normalizeVersion(song.version)
        var s = (titleSim + artistSim) / 2
        if ev != sv {
            // Original/extended/radio edit deler cover – et remix har sit eget
            if hasOwnCover(e.version) || hasOwnCover(song.version) { return 0 }
            s -= 0.05
        }
        return s
    }

    /// Bedste cover til sangen; ved lige god match vinder det største billede.
    static func best(for song: SongInfo, in entries: [ArtworkEntry]) -> ArtworkEntry? {
        var best: (Double, ArtworkEntry)?
        for e in entries {
            let s = score(e, for: song)
            guard s > 0 else { continue }
            if let b = best {
                if s > b.0 + 0.001 || (abs(s - b.0) <= 0.001 && e.pixels > b.1.pixels) { best = (s, e) }
            } else {
                best = (s, e)
            }
        }
        return best?.1
    }

    /// Er det præcis samme sang og version (så et nyt cover erstatter det gamle i stedet for at blive et nyt opslag)?
    static func sameSong(_ e: ArtworkEntry, _ song: SongInfo) -> Bool {
        TextMatch.similarity(e.title, song.title) >= 0.9 &&
            (e.artists.isEmpty || song.artists.isEmpty || TextMatch.artistSimilarity(e.artists, song.artists) >= 0.9) &&
            TextMatch.normalizeVersion(e.version) == TextMatch.normalizeVersion(song.version)
    }
}
