// MODULR – kerne: kandidater fra kilderne (SoundCloud-API, Bandcamp-sider, websøgning)
// og filtrering. Ingen netværk her – kun fortolkning, så det kan testes. Kun Foundation.

import Foundation

enum CandidateKind: String, Codable {
    case directDownload   // SoundCloud downloadable – appen kan hente direkte
    case gate             // Hypeddit/ToneDen/lnk.to … – du gennemfører selv gaten
    case freeDownload     // Bandcamp gratis-download-side – du vælger format selv
    case nameYourPrice    // Bandcamp "name your price" – du skriver selv 0 og henter
    case artistPage       // kunstnerens egen side med gratis download
    case purchaseOnly     // kan kun købes – vises som købsmulighed

    var title: String {
        switch self {
        case .directDownload: return "Direkte download"
        case .gate: return "Download-gate"
        case .freeDownload: return "Gratis download"
        case .nameYourPrice: return "Name your price"
        case .artistPage: return "Kunstnerens side"
        case .purchaseOnly: return "Kan købes"
        }
    }

    var needsBrowser: Bool { self != .directDownload && self != .purchaseOnly }
}

/// Rå kandidat – det vi gemmer i cachen. Godkendes altid igen via SourcePolicy ved brug.
struct RawCandidate: Codable, Equatable {
    var source: SourceKind
    var kind: CandidateKind
    var title: String
    var artist: String
    var duration: Double?
    var isrc: String?
    var pageURL: String
    var downloadURL: String?
    var downloadable: Bool
    var format: String?
    var license: String?
    var price: String?
}

struct Candidate: Identifiable {
    let id = UUID()
    let raw: RawCandidate
    let page: ApprovedPage?
    let download: ApprovedDownload?
    let match: MatchResult

    var verified: Bool { false }   // verificeres først med fingerprint efter download
}

enum CandidateBuilder {
    /// Godkender en rå kandidat (også dem fra cachen) – kan IKKE omgå politikken.
    static func approve(_ raw: RawCandidate, identity: TrackIdentity, artistDomains: [String]) -> Candidate? {
        guard let pageURL = URL(string: raw.pageURL) else { return nil }
        let match = Matcher.evaluate(rawTitle: raw.title, rawArtist: raw.artist, duration: raw.duration,
                                     isrc: raw.isrc, against: identity)
        switch raw.kind {
        case .directDownload:
            guard let dl = SourcePolicy.approveSoundCloudDownload(downloadable: raw.downloadable, downloadURL: raw.downloadURL) else { return nil }
            let page = SourcePolicy.approvePage(pageURL, source: .soundcloud, artistDomains: artistDomains)
            return Candidate(raw: raw, page: page, download: dl, match: match)
        case .purchaseOnly:
            // Købslinks vises bare som links; de åbnes i din egen browser, ikke hentes.
            guard !SourcePolicy.isForbidden(pageURL) else { return nil }
            return Candidate(raw: raw, page: nil, download: nil, match: match)
        default:
            guard let page = SourcePolicy.approvePage(pageURL, source: raw.source, artistDomains: artistDomains) else { return nil }
            return Candidate(raw: raw, page: page, download: nil, match: match)
        }
    }

    /// Filtrér: præcis samme sang først; andre versioner skjules som standard.
    static func filter(_ candidates: [Candidate], showOtherVersions: Bool) -> [Candidate] {
        candidates
            .filter { $0.match.isMatch || (showOtherVersions && $0.match.isOtherVersion) }
            .sorted { a, b in
                func score(_ c: Candidate) -> Double {
                    var s: Double = 0
                    if case .match(let m) = c.match { s += m * 10 }
                    if c.raw.kind == .directDownload { s += 2 }
                    if c.raw.kind == .freeDownload { s += 1.5 }
                    if c.raw.kind == .purchaseOnly { s -= 20 }
                    return s
                }
                return score(a) > score(b)
            }
    }

    // MARK: SoundCloud (officielt API: api.soundcloud.com)

    struct SCUser: Decodable { let username: String? }

    struct SCTrack: Decodable {
        let id: Int
        let title: String?
        let duration: Int?
        let downloadable: Bool?
        let download_url: String?
        let purchase_url: String?
        let purchase_title: String?
        let permalink_url: String?
        let license: String?
        let isrc: String?
        let metadata_artist: String?
        let description: String?
        let user: SCUser?
    }

    struct SCPage: Decodable {
        let collection: [SCTrack]
        let next_href: String?
    }

    static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { $0.url }
    }

    /// Laver kandidater ud fra ét SoundCloud-spor.
    static func fromSoundCloud(_ t: SCTrack) -> [RawCandidate] {
        let artist = (t.metadata_artist?.isEmpty == false ? t.metadata_artist : t.user?.username) ?? ""
        let title = t.title ?? ""
        let duration = t.duration.map { Double($0) / 1000 }
        let page = t.permalink_url ?? "https://soundcloud.com"
        var out = [RawCandidate]()

        if t.downloadable == true, let dl = t.download_url {
            out.append(RawCandidate(source: .soundcloud, kind: .directDownload, title: title, artist: artist,
                                    duration: duration, isrc: t.isrc, pageURL: page, downloadURL: dl,
                                    downloadable: true, format: "Kunstnerens originale fil", license: t.license, price: nil))
        }
        var links = [URL]()
        if let p = t.purchase_url, let u = URL(string: p) { links.append(u) }
        if let d = t.description { links += urls(in: d) }
        var seen = Set<String>()
        for u in links where seen.insert(u.absoluteString).inserted {
            guard let host = Domains.host(u), !SourcePolicy.isForbidden(u) else { continue }
            let kind: CandidateKind
            if Domains.matchesAny(host, Domains.gates) { kind = .gate }
            else if Domains.matchesAny(host, Domains.bandcamp) { kind = .nameYourPrice }
            else if u.absoluteString == t.purchase_url { kind = .purchaseOnly }
            else { continue }   // andre links i beskrivelsen ignoreres
            out.append(RawCandidate(source: kind == .gate ? .gate : (kind == .purchaseOnly ? .soundcloud : .bandcamp),
                                    kind: kind, title: title, artist: artist, duration: duration, isrc: t.isrc,
                                    pageURL: u.absoluteString, downloadURL: nil, downloadable: false,
                                    format: kind == .gate ? "Ofte WAV/320 – står på gaten" : nil,
                                    license: t.license, price: kind == .purchaseOnly ? (t.purchase_title ?? "Køb") : nil))
        }
        return out
    }

    // MARK: Bandcamp (offentlige sider)

    static func htmlUnescape(_ s: String) -> String {
        var t = s
        for (k, v) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func stripTags(_ s: String) -> String {
        htmlUnescape(s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct BandcampHit: Equatable {
        var url: String
        var title: String
        var artist: String
    }

    /// Spor fra Bandcamps søgeside.
    static func parseBandcampSearch(_ html: String) -> [BandcampHit] {
        var hits = [BandcampHit]()
        for block in html.components(separatedBy: "<li class=\"searchresult").dropFirst() {
            let type = firstMatch(#"<div class="itemtype">\s*([A-Za-z]+)"#, in: block)?.uppercased() ?? ""
            guard type == "TRACK",
                  let href = firstMatch(#"<div class="heading">\s*<a[^>]*href="([^"]+)""#, in: block),
                  let titleHTML = firstMatch(#"<div class="heading">\s*<a[^>]*>([\s\S]*?)</a>"#, in: block) else { continue }
            let sub = stripTags(firstMatch(#"<div class="subhead">([\s\S]*?)</div>"#, in: block) ?? "")
            var artist = sub
            if let r = sub.range(of: "by ", options: .backwards) { artist = String(sub[r.upperBound...]) }
            var url = htmlUnescape(href)
            if let q = url.firstIndex(of: "?") { url = String(url[..<q]) }
            hits.append(BandcampHit(url: url, title: stripTags(titleHTML), artist: artist.trimmingCharacters(in: .whitespaces)))
        }
        return hits
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }

    /// Et Bandcamp-spors side: gratis download, name your price eller kun køb.
    static func parseBandcampTrack(_ html: String, pageURL: String) -> RawCandidate? {
        guard let attr = firstMatch(#"data-tralbum="([^"]+)""#, in: html),
              let json = try? JSONSerialization.jsonObject(with: Data(htmlUnescape(attr).utf8)) as? [String: Any] else { return nil }
        let current = json["current"] as? [String: Any] ?? [:]
        let artist = json["artist"] as? String ?? ""
        let trackinfo = (json["trackinfo"] as? [[String: Any]])?.first ?? [:]
        let title = (trackinfo["title"] as? String) ?? (current["title"] as? String) ?? ""
        let duration = (trackinfo["duration"] as? NSNumber)?.doubleValue
        let minPrice = (current["minimum_price"] as? NSNumber)?.doubleValue
        let price = (current["price"] as? NSNumber)?.doubleValue
        let freePage = json["freeDownloadPage"] as? String
        let isrc = current["isrc"] as? String

        var kind = CandidateKind.purchaseOnly
        var page = pageURL
        if let fp = freePage, !fp.isEmpty {
            kind = .freeDownload
            page = fp
        } else if (minPrice ?? 1) == 0 {
            kind = .nameYourPrice
        }
        let priceText: String? = kind == .purchaseOnly ? price.map { String(format: "%.2f", $0) } : nil
        return RawCandidate(source: .bandcamp, kind: kind, title: title, artist: artist, duration: duration,
                            isrc: isrc, pageURL: page, downloadURL: nil, downloadable: false,
                            format: kind == .purchaseOnly ? nil : "FLAC/WAV/AIFF/320 – du vælger på siden",
                            license: nil, price: priceText)
    }
}
