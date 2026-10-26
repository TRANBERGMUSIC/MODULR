// MODULR – fælles tjenester: HTTP (rate limits + robots.txt), 24-timers cache og indstillinger.

import Foundation
import SwiftUI

// MARK: - HTTP

enum HTTPError: LocalizedError {
    case status(Int, String)
    case blockedByRobots(String)
    case forbidden(String)

    var errorDescription: String? {
        switch self {
        case .status(let code, let host): return "\(host) svarede \(code)"
        case .blockedByRobots(let host): return "\(host) tillader ikke automatisk adgang her (robots.txt)"
        case .forbidden(let url): return "Ikke tilladt kilde: \(url)"
        }
    }
}

final class HTTP {
    static let shared = HTTP()
    static let userAgent = "MODULR/1.3 (+https://github.com/TRANBERGMUSIC/MODULR)"

    private let lock = NSLock()
    private var nextAllowed: [String: Date] = [:]
    private var robots: [String: RobotsRules] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": HTTP.userAgent]
        return URLSession(configuration: c)
    }()

    /// Mindste afstand mellem kald pr. vært.
    func interval(for host: String) -> TimeInterval {
        if host.hasSuffix("musicbrainz.org") { return 1.1 }
        if host.hasSuffix("acoustid.org") { return 0.35 }
        if host.hasSuffix("bandcamp.com") { return 1.0 }
        if host.hasSuffix("search.brave.com") { return 1.0 }
        if host.hasSuffix("soundcloud.com") { return 0.25 }
        return 0.5
    }

    private func reserveSlot(host: String) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let start = max(now, nextAllowed[host] ?? now)
        nextAllowed[host] = start.addingTimeInterval(interval(for: host))
        return start.timeIntervalSince(now)
    }

    private func throttle(_ url: URL) async {
        let wait = reserveSlot(host: url.host ?? "")
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    private func cachedRobots(_ host: String) -> RobotsRules? {
        lock.lock()
        defer { lock.unlock() }
        return robots[host]
    }

    private func storeRobots(_ host: String, _ rules: RobotsRules) {
        lock.lock()
        robots[host] = rules
        lock.unlock()
    }

    /// Tjek robots.txt for sider vi læser (ikke for officielle API'er).
    func checkRobots(_ url: URL) async throws {
        guard let host = url.host, let scheme = url.scheme else { return }
        var rules = cachedRobots(host)
        if rules == nil {
            var r = RobotsRules.allowAll
            if let robotsURL = URL(string: "\(scheme)://\(host)/robots.txt") {
                await throttle(robotsURL)
                if let (data, resp) = try? await session.data(from: robotsURL),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    r = RobotsRules.parse(String(decoding: data, as: UTF8.self), userAgent: "MODULR")
                }
            }
            storeRobots(host, r)
            rules = r
        }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        if rules?.isAllowed(path) == false { throw HTTPError.blockedByRobots(host) }
    }

    /// Alle netværkskald går gennem her: forbudte kilder afvises, rate limit overholdes.
    func data(_ request: URLRequest, respectRobots: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw HTTPError.forbidden("ingen URL") }
        if SourcePolicy.isForbidden(url) { throw HTTPError.forbidden(url.absoluteString) }
        if respectRobots { try await checkRobots(url) }
        await throttle(url)
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.status(0, url.host ?? "") }
        if http.statusCode == 429 {
            // For mange kald – vent og prøv én gang til
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let (d2, r2) = try await session.data(for: request)
            guard let h2 = r2 as? HTTPURLResponse else { throw HTTPError.status(0, url.host ?? "") }
            return (d2, h2)
        }
        return (data, http)
    }

    func get(_ url: URL, headers: [String: String] = [:], respectRobots: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return try await data(r, respectRobots: respectRobots)
    }

    /// Hent en fil – KUN via en ApprovedDownload fra SourcePolicy.
    func download(_ approved: ApprovedDownload, headers: [String: String] = [:]) async throws -> (URL, HTTPURLResponse) {
        guard let url = approved.url, !approved.viaBrowser else { throw HTTPError.forbidden("ikke en direkte download") }
        if SourcePolicy.isForbidden(url) { throw HTTPError.forbidden(url.absoluteString) }
        await throttle(url)
        var r = URLRequest(url: url)
        r.timeoutInterval = 120
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (tmp, resp) = try await session.download(for: r)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.status(0, url.host ?? "") }
        guard (200..<300).contains(http.statusCode) else { throw HTTPError.status(http.statusCode, url.host ?? "") }
        if let final = http.url, SourcePolicy.isForbidden(final) { throw HTTPError.forbidden(final.absoluteString) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MODULR-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = http.suggestedFilename ?? url.lastPathComponent
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return (dest, http)
    }
}

// MARK: - Mapper og cache

enum AppFolders {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MODULR", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Søgeresultater pr. sang i 24 timer. Gemmer kun rå data – godkendes igen ved brug.
enum SearchCache {
    struct Entry: Codable {
        var savedAt: Date
        var candidates: [RawCandidate]
        var artistDomains: [String]
    }

    static let lifetime: TimeInterval = 24 * 3600

    static func file(for key: String) -> URL {
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let dir = AppFolders.support.appendingPathComponent("cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(String(safe.prefix(150)) + ".json")
    }

    static func load(_ key: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(for: key)),
              let e = try? JSONDecoder().decode(Entry.self, from: data),
              Date().timeIntervalSince(e.savedAt) < lifetime else { return nil }
        return e
    }

    static func save(_ key: String, candidates: [RawCandidate], artistDomains: [String]) {
        let e = Entry(savedAt: Date(), candidates: candidates, artistDomains: artistDomains)
        if let data = try? JSONEncoder().encode(e) { try? data.write(to: file(for: key)) }
    }
}

// MARK: - Indstillinger

struct APIKeys: Codable, Equatable {
    var acoustID = ""
    var audd = ""
    var acrHost = ""
    var acrKey = ""
    var acrSecret = ""
    var soundCloudClientID = ""
    var soundCloudClientSecret = ""
    var brave = ""
}

/// Nøgler gemmes i en fil kun du kan læse (Programsupport/MODULR/keys.json, rettigheder 600).
/// (Nøgleringen ville spørge om adgang efter hver auto-opdatering, fordi appen bygges lokalt.)
final class FBSettings: ObservableObject {
    @Published var useSoundCloud: Bool { didSet { saveFlags() } }
    @Published var useBandcamp: Bool { didSet { saveFlags() } }
    @Published var useGates: Bool { didSet { saveFlags() } }
    @Published var useWebSearch: Bool { didSet { saveFlags() } }
    @Published var askBeforeGate: Bool { didSet { saveFlags() } }
    @Published var showOtherVersions: Bool { didSet { saveFlags() } }
    @Published var rule: ImprovementRule { didSet { saveFlags() } }
    @Published var useSystemBrowser: Bool { didSet { saveFlags() } }
    @Published var keys: APIKeys { didSet { saveKeys() } }

    private let d = UserDefaults.standard
    private static var keysFile: URL { AppFolders.support.appendingPathComponent("keys.json") }

    init() {
        let d = UserDefaults.standard
        useSoundCloud = d.object(forKey: "fb.soundcloud") as? Bool ?? true
        useBandcamp = d.object(forKey: "fb.bandcamp") as? Bool ?? true
        useGates = d.object(forKey: "fb.gates") as? Bool ?? true
        useWebSearch = d.object(forKey: "fb.websearch") as? Bool ?? false
        askBeforeGate = d.object(forKey: "fb.askgate") as? Bool ?? true
        showOtherVersions = d.object(forKey: "fb.otherversions") as? Bool ?? false
        rule = ImprovementRule(rawValue: d.string(forKey: "fb.rule") ?? "") ?? .realTier
        useSystemBrowser = d.object(forKey: "fb.systembrowser") as? Bool ?? true
        if let data = try? Data(contentsOf: FBSettings.keysFile),
           let k = try? JSONDecoder().decode(APIKeys.self, from: data) {
            keys = k
        } else {
            keys = APIKeys()
        }
    }

    private func saveFlags() {
        d.set(useSoundCloud, forKey: "fb.soundcloud")
        d.set(useBandcamp, forKey: "fb.bandcamp")
        d.set(useGates, forKey: "fb.gates")
        d.set(useWebSearch, forKey: "fb.websearch")
        d.set(askBeforeGate, forKey: "fb.askgate")
        d.set(showOtherVersions, forKey: "fb.otherversions")
        d.set(rule.rawValue, forKey: "fb.rule")
        d.set(useSystemBrowser, forKey: "fb.systembrowser")
    }

    private func saveKeys() {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        let url = FBSettings.keysFile
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    var soundCloudConfigured: Bool { !keys.soundCloudClientID.isEmpty && !keys.soundCloudClientSecret.isEmpty }
    var acrConfigured: Bool { !keys.acrHost.isEmpty && !keys.acrKey.isEmpty && !keys.acrSecret.isEmpty }
}
