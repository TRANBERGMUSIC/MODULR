// MODULR – søgning i officielle kilder. Netværket ligger her; fortolkningen i Core/Candidates.swift.
//  • SoundCloud: kun api.soundcloud.com (OAuth 2.1, client credentials). Aldrig api-v2, scrapere eller streams.
//  • Bandcamp: den offentlige søgeside og spor-sider, med robots.txt og rate limit.
//  • Websøgning (valgfri, Brave Search API): kun resultater fra gates, Bandcamp og kunstnerens egne domæner.

import Foundation

enum SourceError: LocalizedError {
    case notConfigured(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return m
        case .failed(let m): return m
        }
    }
}

// MARK: - SoundCloud

/// Officielt SoundCloud-API. Bruger din egen konto, hvis du har logget ind under Konti
/// (OAuth 2.1 Authorization Code + PKCE), ellers app-adgang (client credentials).
final class SoundCloudAPI {
    struct Token: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    static let redirectURI = "modulr://soundcloud/callback"

    let clientID: String
    let clientSecret: String
    private static var appTokenFile: URL { AppFolders.support.appendingPathComponent("soundcloud-token.json") }
    static var userTokenFile: URL { AppFolders.support.appendingPathComponent("soundcloud-user-token.json") }

    init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    static var hasUserLogin: Bool { FileManager.default.fileExists(atPath: userTokenFile.path) }

    static func logoutUser() { try? FileManager.default.removeItem(at: userTokenFile) }

    private static func load(_ url: URL) -> Token? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Token.self, from: d)
    }

    static func save(_ t: Token, to url: URL) {
        guard let d = try? JSONEncoder().encode(t) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Token {
        var req = URLRequest(url: URL(string: "https://secure.soundcloud.com/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, http) = try await HTTP.shared.data(req)
        guard http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw SourceError.failed("SoundCloud-login fejlede (\(http.statusCode)) – tjek client-id/secret under Konti")
        }
        let expires = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Token(accessToken: access, refreshToken: obj["refresh_token"] as? String,
                     expiresAt: Date().addingTimeInterval(expires))
    }

    /// Bytter koden fra SoundCloud-login til et token for DIN konto.
    func exchange(code: String, verifier: String) async throws {
        let t = try await tokenRequest([
            "grant_type": "authorization_code", "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": Self.redirectURI, "code_verifier": verifier, "code": code,
        ])
        Self.save(t, to: Self.userTokenFile)
    }

    /// Din konto først (fornyes automatisk); ellers app-adgang. Tokens genbruges, da SoundCloud
    /// kun tillader få nye pr. døgn.
    func accessToken() async throws -> String {
        if let t = Self.load(Self.userTokenFile) {
            if t.expiresAt > Date().addingTimeInterval(60) { return t.accessToken }
            if let refresh = t.refreshToken,
               let fresh = try? await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh,
                                                     "client_id": clientID, "client_secret": clientSecret]) {
                var keep = fresh
                if keep.refreshToken == nil { keep.refreshToken = refresh }
                Self.save(keep, to: Self.userTokenFile)
                return keep.accessToken
            }
            Self.logoutUser()   // udløbet – du skal logge ind igen under Konti
        }
        if let t = Self.load(Self.appTokenFile), t.expiresAt > Date().addingTimeInterval(60) { return t.accessToken }
        var t: Token
        if let old = Self.load(Self.appTokenFile), let refresh = old.refreshToken,
           let fresh = try? await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh,
                                                 "client_id": clientID, "client_secret": clientSecret]) {
            t = fresh
        } else {
            t = try await tokenRequest(["grant_type": "client_credentials"])
        }
        Self.save(t, to: Self.appTokenFile)
        return t.accessToken
    }

    /// Hvem er logget ind (kun når du har forbundet din konto).
    func me() async throws -> String? {
        guard Self.hasUserLogin else { return nil }
        let token = try await accessToken()
        let (data, http) = try await HTTP.shared.get(URL(string: "https://api.soundcloud.com/me")!,
                                                     headers: ["Authorization": "OAuth \(token)", "Accept": "application/json; charset=utf-8"])
        guard http.statusCode == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["username"] as? String
    }

    func search(_ query: String) async throws -> [CandidateBuilder.SCTrack] {
        var c = URLComponents(string: "https://api.soundcloud.com/tracks")!
        c.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "linked_partitioning", value: "true"),
        ]
        let token = try await accessToken()
        let (data, http) = try await HTTP.shared.get(c.url!, headers: [
            "Authorization": "OAuth \(token)", "Accept": "application/json; charset=utf-8",
        ])
        guard http.statusCode == 200 else { throw SourceError.failed("SoundCloud svarede \(http.statusCode)") }
        return try JSONDecoder().decode(CandidateBuilder.SCPage.self, from: data).collection
    }

    /// Henter en fil kunstneren selv har gjort downloadbar.
    func download(_ approved: ApprovedDownload) async throws -> URL {
        let token = try await accessToken()
        do {
            let (file, _) = try await HTTP.shared.download(approved, headers: ["Authorization": "OAuth \(token)"])
            return file
        } catch HTTPError.status(let code, _) where code == 401 || code == 403 {
            throw SourceError.failed(Self.hasUserLogin
                ? "SoundCloud gav ikke adgang til filen. Åbn sporet på SoundCloud og brug download-knappen."
                : "SoundCloud kræver, at du er logget ind. Forbind din SoundCloud-konto under Konti.")
        }
    }
}

// MARK: - Bandcamp

enum BandcampSearch {
    static func search(_ query: String, identity: TrackIdentity) async throws -> [RawCandidate] {
        var c = URLComponents(string: "https://bandcamp.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "item_type", value: "t")]
        let (data, http) = try await HTTP.shared.get(c.url!, respectRobots: true)
        guard http.statusCode == 200 else { throw SourceError.failed("Bandcamp svarede \(http.statusCode)") }
        let hits = CandidateBuilder.parseBandcampSearch(String(decoding: data, as: UTF8.self))
        // Kun spor der allerede ligner sangen hentes videre (skåner Bandcamp for unødige kald)
        let likely = hits.filter {
            TextMatch.similarity(TextMatch.splitVersion($0.title).base, identity.title) >= 0.8 &&
                TextMatch.artistSimilarity([$0.artist], identity.artists) >= 0.8
        }.prefix(5)
        var out = [RawCandidate]()
        for hit in likely {
            guard let url = URL(string: hit.url) else { continue }
            guard let (page, resp) = try? await HTTP.shared.get(url, respectRobots: true), resp.statusCode == 200 else { continue }
            if let cand = CandidateBuilder.parseBandcampTrack(String(decoding: page, as: UTF8.self), pageURL: hit.url) {
                out.append(cand)
            }
        }
        return out
    }
}

// MARK: - Websøgning (valgfri)

enum WebSearch {
    static func search(_ identity: TrackIdentity, key: String, artistDomains: [String]) async throws -> [RawCandidate] {
        guard !key.isEmpty else { throw SourceError.notConfigured("Websøgning ikke konfigureret (mangler Brave Search-nøgle)") }
        var c = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        let q = "\(identity.artists.joined(separator: " ")) \(identity.title) \(identity.version ?? "") free download"
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "count", value: "20")]
        let (data, http) = try await HTTP.shared.get(c.url!, headers: ["X-Subscription-Token": key, "Accept": "application/json"])
        guard http.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.failed("Websøgning svarede \(http.statusCode)")
        }
        let results = ((obj["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        var out = [RawCandidate]()
        for r in results {
            guard let s = r["url"] as? String, let u = URL(string: s),
                  let page = SourcePolicy.approvePage(u, source: .webSearch, artistDomains: artistDomains) else { continue }
            let title = (r["title"] as? String) ?? ""
            let kind: CandidateKind = page.source == .gate ? .gate : (page.source == .bandcamp ? .nameYourPrice : .artistPage)
            // Websider siger sjældent kunstner/titel rent – vi bruger sangens egne, men markerer som ikke verificeret
            out.append(RawCandidate(source: page.source, kind: kind,
                                    title: title.isEmpty ? identity.title : identity.title + (identity.version.map { " (\($0))" } ?? ""),
                                    artist: identity.artists.first ?? "", duration: nil, isrc: nil,
                                    pageURL: u.absoluteString, downloadURL: nil, downloadable: false,
                                    format: nil, license: nil, price: nil))
        }
        return out
    }
}
