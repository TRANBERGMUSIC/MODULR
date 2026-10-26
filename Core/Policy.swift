// MODULR – kerne: kildepolitik. Håndhæver i koden (ikke kun i UI) at MODULR kun
// henter fra officielle kilder og kun det, kunstneren selv har gjort gratis tilgængeligt.
//
// Regler:
//  • Ingen api-v2.soundcloud.com, ingen stream-URL'er, ingen stream-rippere/piratsider/filehosts.
//  • En download kan KUN ske via en ApprovedDownload, og den kan kun laves her i filen:
//      – SoundCloud: track.downloadable == true og URL = https://api.soundcloud.com/tracks/<id>/download
//      – En browser-session (gate/Bandcamp/kunstnerside), som brugeren selv gennemfører,
//        og som er startet fra en godkendt side (GateSessionTicket).
//  • En side kan kun åbnes via ApprovedPage: gate-tjenester, Bandcamp, kunstnerens egne domæner
//    (fra MusicBrainz) og SoundCloud-sider fra det officielle API.
// Kun Foundation.

import Foundation

enum SourceKind: String, Codable, CaseIterable {
    case soundcloud, bandcamp, gate, artistSite, webSearch

    var title: String {
        switch self {
        case .soundcloud: return "SoundCloud"
        case .bandcamp: return "Bandcamp"
        case .gate: return "Download-gate"
        case .artistSite: return "Kunstnerens side"
        case .webSearch: return "Websøgning"
        }
    }
}

enum Domains {
    /// Download-gates kunstnere/labels selv bruger.
    static let gates = ["hypeddit.com", "toneden.io", "lnk.to", "fanlink.to", "fanlink.tv", "fanlink.com"]
    static let bandcamp = ["bandcamp.com"]
    static let soundcloudWeb = ["soundcloud.com"]

    /// Aldrig: uofficielle API'er, stream-rippere, filehosts, "mp3 download"-sider, YouTube.
    static let forbidden = [
        "api-v2.soundcloud.com", "youtube.com", "youtu.be", "y2mate.com", "savefrom.net",
        "soundcloudmp3.org", "sclouddownloader.net", "klickaud.co", "klickaud.net", "scdownloader.io",
        "mp3juices.cc", "mp3juice.co", "freemp3cloud.com", "mp3paw.com", "slider.kz", "dbree.org",
        "zippyshare.com", "mediafire.com", "mega.nz", "rapidgator.net", "uploaded.net", "4shared.com",
        "nitroflare.com", "turbobit.net", "katfile.com", "zippyshare.day", "mp3skull.com", "tubidy.com",
    ]

    /// Store platforme der aldrig tæller som "kunstnerens eget domæne".
    static let notArtistOwned = [
        "facebook.com", "instagram.com", "twitter.com", "x.com", "tiktok.com", "spotify.com",
        "apple.com", "music.apple.com", "beatport.com", "traxsource.com", "discogs.com", "wikipedia.org",
        "musicbrainz.org", "linktr.ee", "google.com", "dropbox.com", "drive.google.com", "wetransfer.com",
    ] + forbidden + gates + bandcamp + soundcloudWeb

    static func host(_ url: URL) -> String? {
        guard var h = url.host?.lowercased() else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func matches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }

    static func matchesAny(_ host: String, _ domains: [String]) -> Bool {
        domains.contains { matches(host, $0) }
    }
}

/// En side MODULR må åbne/læse. Kan kun oprettes af SourcePolicy.
struct ApprovedPage: Equatable, Identifiable {
    let url: URL
    let source: SourceKind
    var id: String { url.absoluteString }

    fileprivate init(url: URL, source: SourceKind) {
        self.url = url
        self.source = source
    }
}

/// En fil MODULR må hente. Kan kun oprettes af SourcePolicy.
struct ApprovedDownload: Equatable {
    let url: URL?            // nil når filen kom fra en browser-session
    let source: SourceKind
    let pageURL: URL?
    let viaBrowser: Bool

    fileprivate init(url: URL?, source: SourceKind, pageURL: URL?, viaBrowser: Bool) {
        self.url = url
        self.source = source
        self.pageURL = pageURL
        self.viaBrowser = viaBrowser
    }
}

/// Bevis på at en browser-session blev startet fra en godkendt side.
struct GateSessionTicket: Identifiable, Equatable {
    let id = UUID()
    let page: ApprovedPage

    fileprivate init(page: ApprovedPage) { self.page = page }
}

enum SourcePolicy {
    static func isForbidden(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return true }
        guard let host = Domains.host(url) else { return true }
        if Domains.matchesAny(host, Domains.forbidden) { return true }
        let path = url.path.lowercased()
        // Ingen stream-URL'er (HLS-playlister, /stream og /streams på SoundCloud-API'et)
        if path.hasSuffix(".m3u8") || path.hasSuffix(".m3u") { return true }
        if Domains.matches(host, "api.soundcloud.com"),
           path.hasSuffix("/stream") || path.hasSuffix("/streams") { return true }
        if host.contains("sndcdn.com") && path.contains("/playlist") { return true }
        return false
    }

    /// Sider du selv må klikke dig rundt på i MODULRs browser (gates, login). YouTube er tilladt
    /// at besøge (fx "abonnér"-trin på en gate), men ALDRIG at hente fra – det afviser isForbidden.
    static let browsableExceptions = ["youtube.com", "youtu.be"]

    static func isBlockedForBrowsing(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = Domains.host(url) else { return true }
        if Domains.matchesAny(host, browsableExceptions) { return false }
        return isForbidden(url)
    }

    /// Godkend en side. Kun gates, Bandcamp, kunstnerens egne domæner og (for SoundCloud-kilden) soundcloud.com.
    static func approvePage(_ url: URL, source: SourceKind, artistDomains: [String]) -> ApprovedPage? {
        guard !isForbidden(url), let host = Domains.host(url) else { return nil }
        if Domains.matchesAny(host, Domains.gates) { return ApprovedPage(url: url, source: .gate) }
        if Domains.matchesAny(host, Domains.bandcamp) { return ApprovedPage(url: url, source: .bandcamp) }
        if source == .soundcloud, Domains.matchesAny(host, Domains.soundcloudWeb), !host.hasPrefix("api") {
            return ApprovedPage(url: url, source: .soundcloud)
        }
        let own = artistDomains.map { $0.lowercased() }.filter { !Domains.matchesAny($0, Domains.notArtistOwned) }
        if Domains.matchesAny(host, own) { return ApprovedPage(url: url, source: .artistSite) }
        return nil
    }

    /// Direkte download fra SoundCloud – kun når kunstneren har slået download til.
    static func approveSoundCloudDownload(downloadable: Bool, downloadURL: String?) -> ApprovedDownload? {
        guard downloadable, let s = downloadURL, let url = URL(string: s), !isForbidden(url),
              url.scheme == "https", Domains.host(url) == "api.soundcloud.com" else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "tracks", Int(parts[1]) != nil, parts[2] == "download" else { return nil }
        return ApprovedDownload(url: url, source: .soundcloud, pageURL: nil, viaBrowser: false)
    }

    /// Start en browser-session (gate) fra en godkendt side.
    static func startSession(for page: ApprovedPage) -> GateSessionTicket {
        GateSessionTicket(page: page)
    }

    /// En fil brugeren selv har hentet i en godkendt browser-session.
    static func approveBrowserDownload(fileSourceURL: URL?, ticket: GateSessionTicket) -> ApprovedDownload? {
        if let u = fileSourceURL, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", isForbidden(u) {
            return nil
        }
        return ApprovedDownload(url: fileSourceURL, source: ticket.page.source, pageURL: ticket.page.url, viaBrowser: true)
    }
}
