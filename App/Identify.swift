// MODULR – identifikation: fingerprint er sandheden, tags/filnavn er sekundære hints.
// Backends: AcoustID (+ MusicBrainz for ISRC og kunstnerens officielle links), valgfrit AudD og ACRCloud.

import Foundation
import CryptoKit

struct IdentityOption: Identifiable, Equatable {
    let id = UUID()
    var identity: TrackIdentity
    var source: String             // "AcoustID", "AudD", "ACRCloud", "Tags/filnavn"
    var confidence: Double         // 0…1
    var fromFingerprint: Bool
}

struct ArtistLinks: Equatable {
    var domains: [String] = []     // kunstnerens egne domæner (officiel hjemmeside)
    var freeDownloadPages: [URL] = []   // MusicBrainz "download for free"
}

enum IdentifyError: LocalizedError {
    case service(String)
    var errorDescription: String? {
        switch self { case .service(let m): return m }
    }
}

final class Identifier {
    let keys: APIKeys
    init(keys: APIKeys) { self.keys = keys }

    // MARK: Tags/filnavn

    static func fromTags(url: URL, duration: Double) -> IdentityOption? {
        let tags = Analyzer.readAllTags(url: url)
        let fallback = Analyzer.readTags(url: url)
        let artist = tags["artist"] ?? fallback.artist
        let rawTitle = tags["title"] ?? fallback.title
        guard let rawTitle, !rawTitle.isEmpty else { return nil }
        let split = TextMatch.splitVersion(rawTitle)
        let identity = TrackIdentity(title: split.base,
                                     artists: artist.map { TextMatch.splitArtists($0) } ?? [],
                                     version: split.version, duration: duration, isrc: tags["ISRC"] ?? tags["isrc"])
        return IdentityOption(identity: identity, source: "Tags/filnavn", confidence: 0.5, fromFingerprint: false)
    }

    // MARK: AcoustID + MusicBrainz

    struct AcoustIDResponse: Decodable {
        struct Artist: Decodable { let name: String }
        struct Recording: Decodable { let id: String; let title: String?; let duration: Double?; let artists: [Artist]? }
        struct Result: Decodable { let id: String; let score: Double; let recordings: [Recording]? }
        let status: String
        let results: [Result]?
        let error: ErrorInfo?
        struct ErrorInfo: Decodable { let message: String? }
    }

    func acoustID(_ fp: Fingerprint, hint: TrackIdentity?) async throws -> IdentityOption? {
        guard !keys.acoustID.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client=\(keys.acoustID)&duration=\(Int(fp.duration.rounded()))&fingerprint=\(fp.compressed)&meta=recordings"
        req.httpBody = Data(body.utf8)
        let (data, _) = try await HTTP.shared.data(req)
        let r = try JSONDecoder().decode(AcoustIDResponse.self, from: data)
        if r.status != "ok" { throw IdentifyError.service("AcoustID: \(r.error?.message ?? "fejl")") }

        var best: (score: Double, rec: AcoustIDResponse.Recording)?
        for res in r.results ?? [] where res.score >= 0.75 {
            for rec in res.recordings ?? [] where rec.title != nil {
                var s = res.score
                if let d = rec.duration { s -= min(0.2, abs(d - fp.duration) / 100) }
                if let h = hint { s += 0.05 * TextMatch.similarity(rec.title ?? "", h.title) }
                if best == nil || s > best!.score { best = (s, rec) }
            }
        }
        guard let b = best else { return nil }
        let split = TextMatch.splitVersion(b.rec.title ?? "")
        var identity = TrackIdentity(title: split.base, artists: (b.rec.artists ?? []).map(\.name),
                                     version: split.version, duration: b.rec.duration ?? fp.duration,
                                     isrc: nil, musicBrainzID: b.rec.id)
        if let isrc = try? await musicBrainzISRC(b.rec.id) { identity.isrc = isrc }
        return IdentityOption(identity: identity, source: "AcoustID", confidence: min(1, b.score), fromFingerprint: true)
    }

    private func mbGet(_ path: String) async throws -> [String: Any] {
        let url = URL(string: "https://musicbrainz.org/ws/2/\(path)")!
        let (data, http) = try await HTTP.shared.get(url, headers: ["Accept": "application/json"])
        guard http.statusCode == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IdentifyError.service("MusicBrainz svarede \(http.statusCode)")
        }
        return obj
    }

    func musicBrainzISRC(_ recordingID: String) async throws -> String? {
        let obj = try await mbGet("recording/\(recordingID)?inc=isrcs&fmt=json")
        return (obj["isrcs"] as? [String])?.first
    }

    /// Kunstnerens officielle hjemmeside(r) og "download for free"-links fra MusicBrainz.
    func artistLinks(recordingID: String?) async -> ArtistLinks {
        guard let rid = recordingID else { return ArtistLinks() }
        var links = ArtistLinks()
        guard let rec = try? await mbGet("recording/\(rid)?inc=artists+url-rels&fmt=json") else { return links }
        for rel in rec["relations"] as? [[String: Any]] ?? [] {
            if let type = rel["type"] as? String, type.contains("free"),
               let res = (rel["url"] as? [String: Any])?["resource"] as? String, let u = URL(string: res) {
                links.freeDownloadPages.append(u)
            }
        }
        let credits = rec["artist-credit"] as? [[String: Any]] ?? []
        for credit in credits.prefix(2) {
            guard let artistID = (credit["artist"] as? [String: Any])?["id"] as? String,
                  let artist = try? await mbGet("artist/\(artistID)?inc=url-rels&fmt=json") else { continue }
            for rel in artist["relations"] as? [[String: Any]] ?? [] {
                guard let type = rel["type"] as? String,
                      let res = (rel["url"] as? [String: Any])?["resource"] as? String,
                      let u = URL(string: res), let host = Domains.host(u) else { continue }
                if type == "official homepage", !Domains.matchesAny(host, Domains.notArtistOwned) {
                    links.domains.append(host)
                }
            }
        }
        return links
    }

    // MARK: AudD (valgfri)

    private func multipart(fields: [String: String], fileField: String, file: URL) throws -> (Data, String) {
        let boundary = "MODULR-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"snippet.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    func audd(snippet: URL, duration: Double) async throws -> IdentityOption? {
        guard !keys.audd.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://api.audd.io/")!)
        req.httpMethod = "POST"
        let (body, type) = try multipart(fields: ["api_token": keys.audd, "return": "spotify"], fileField: "file", file: snippet)
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await HTTP.shared.data(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (obj["status"] as? String) != "success" {
            let msg = ((obj["error"] as? [String: Any])?["error_message"] as? String) ?? "fejl"
            throw IdentifyError.service("AudD: \(msg)")
        }
        guard let res = obj["result"] as? [String: Any], let title = res["title"] as? String,
              let artist = res["artist"] as? String else { return nil }
        let spotify = res["spotify"] as? [String: Any]
        let isrc = (spotify?["external_ids"] as? [String: Any])?["isrc"] as? String
        let dur = (spotify?["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? duration
        let split = TextMatch.splitVersion(title)
        let identity = TrackIdentity(title: split.base, artists: TextMatch.splitArtists(artist),
                                     version: split.version, duration: dur, isrc: isrc)
        return IdentityOption(identity: identity, source: "AudD", confidence: 0.85, fromFingerprint: true)
    }

    // MARK: ACRCloud (valgfri)

    func acrCloud(snippet: URL, duration: Double) async throws -> IdentityOption? {
        guard !keys.acrHost.isEmpty, !keys.acrKey.isEmpty, !keys.acrSecret.isEmpty else { return nil }
        let host = keys.acrHost.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "https://\(host)/v1/identify") else { return nil }
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let toSign = "POST\n/v1/identify\n\(keys.acrKey)\naudio\n1\n\(timestamp)"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: Data(keys.acrSecret.utf8)))
        let signature = Data(mac).base64EncodedString()
        let attrs = try? FileManager.default.attributesOfItem(atPath: snippet.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (body, type) = try multipart(fields: [
            "access_key": keys.acrKey, "sample_bytes": String(size), "timestamp": timestamp,
            "signature": signature, "data_type": "audio", "signature_version": "1",
        ], fileField: "sample", file: snippet)
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, _) = try await HTTP.shared.data(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let status = obj["status"] as? [String: Any]
        if (status?["code"] as? NSNumber)?.intValue != 0 {
            if (status?["code"] as? NSNumber)?.intValue == 1001 { return nil }   // ingen match
            throw IdentifyError.service("ACRCloud: \(status?["msg"] as? String ?? "fejl")")
        }
        guard let music = ((obj["metadata"] as? [String: Any])?["music"] as? [[String: Any]])?.first,
              let title = music["title"] as? String else { return nil }
        let artists = (music["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let isrc = (music["external_ids"] as? [String: Any])?["isrc"] as? String
        let dur = (music["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 } ?? duration
        let score = ((music["score"] as? NSNumber)?.doubleValue ?? 80) / 100
        let split = TextMatch.splitVersion(title)
        let identity = TrackIdentity(title: split.base, artists: artists, version: split.version, duration: dur, isrc: isrc)
        return IdentityOption(identity: identity, source: "ACRCloud", confidence: score, fromFingerprint: true)
    }
}
