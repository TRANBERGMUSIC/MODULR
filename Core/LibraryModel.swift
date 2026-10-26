// MODULR – kerne: biblioteket – sange, mapper og playlister. Kun Foundation.

import Foundation

struct LibTrack: Codable, Identifiable, Equatable {
    var id: UUID
    var path: String
    var title: String
    var artist: String
    var album: String
    var genre: String
    var year: Int?
    var comment: String
    // Analyse
    var bpm: Double?
    var firstBeatMs: Double?
    var key: MusicalKey?
    var energy: Int?
    var duration: Double?
    // Kvalitet
    var codec: String
    var statedKbps: Int?
    var tierKbps: Int?            // reel kvalitet (9999 = fuld båndbredde)
    var qualityLabel: String
    var sampleRate: Double?
    var bitDepth: Int?
    var fileSize: Int64?
    // Filer i MODULR
    var artFile: String?          // cover (JPEG)
    var hasWave: Bool
    var addedAt: Date
    var analyzed: Bool
    var analysisError: String?
    var history: [String]         // tidligere filer (efter udskiftning)

    var url: URL { URL(fileURLWithPath: path) }
    var fileName: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    var qualityColor: QualityColor? { tierKbps.map(QualityColor.forTier) }

    /// "128 kbps", "320 kbps", "Lossless", "Fake 320 → 128"
    var qualityText: String {
        guard let tier = tierKbps else { return analyzed ? "–" : "…" }
        let lossless: Bool = ["WAV", "AIFF", "FLAC", "ALAC", "PCM"].contains(codec)
        var real = "\(tier) kbps"
        if tier >= 9999 { real = lossless ? "Lossless" : "320 kbps" }
        if let s = statedKbps, s < 600, tier < 9999, s >= tier + 40 { return "Fake \(s) → \(tier)" }
        if ["WAV", "AIFF", "FLAC", "ALAC", "PCM"].contains(codec), tier < 9999 { return "Fake \(codec) → \(tier)" }
        return real
    }

    var needsUpgrade: Bool { (tierKbps ?? 9999) < 320 }

    var durationText: String {
        guard let d = duration, d > 0 else { return "–" }
        let s = Int(d.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var bpmText: String {
        guard let b = bpm, b > 0 else { return "–" }
        return abs(b - b.rounded()) < 0.05 ? String(Int(b.rounded())) : String(format: "%.1f", b)
    }

    init(path: String) {
        id = UUID()
        self.path = path
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        title = base
        artist = ""
        album = ""
        genre = ""
        comment = ""
        codec = URL(fileURLWithPath: path).pathExtension.uppercased()
        qualityLabel = ""
        hasWave = false
        addedAt = Date()
        analyzed = false
        history = []
    }
}

struct LibNode: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var parent: UUID?
    var isFolder: Bool
    var trackIDs: [UUID]
    var sort: Int

    init(name: String, parent: UUID?, isFolder: Bool, sort: Int) {
        id = UUID()
        self.name = name
        self.parent = parent
        self.isFolder = isFolder
        trackIDs = []
        self.sort = sort
    }
}

/// Faste lister øverst i biblioteket.
enum SmartList: String, CaseIterable, Codable, Identifiable {
    case all = "Alle sange"
    case queue = "Til analyse"
    case recent = "Senest tilføjet"
    case upgrade = "Skal opgraderes"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "infinity"
        case .queue: return "clock.arrow.circlepath"
        case .recent: return "sparkles"
        case .upgrade: return "arrow.up.circle"
        }
    }

    func matches(_ t: LibTrack) -> Bool {
        switch self {
        case .all: return true
        case .queue: return !t.analyzed
        case .recent: return Date().timeIntervalSince(t.addedAt) < 14 * 24 * 3600
        case .upgrade: return t.analyzed && t.needsUpgrade
        }
    }
}

struct LibraryIndex: Codable, Equatable {
    var tracks: [LibTrack] = []
    var nodes: [LibNode] = []

    func children(of parent: UUID?) -> [LibNode] {
        nodes.filter { $0.parent == parent }.sorted(by: LibraryIndex.nodeOrder)
    }

    /// Mapper først, derefter sorteringsnummer, derefter navn.
    static func nodeOrder(_ a: LibNode, _ b: LibNode) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        if a.sort != b.sort { return a.sort < b.sort }
        return a.name < b.name
    }

    func track(_ id: UUID) -> LibTrack? { tracks.first { $0.id == id } }

    func tracks(in node: LibNode) -> [LibTrack] {
        let map = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        if node.isFolder {
            // En mappe viser alle sange i sine playlister
            var seen = Set<UUID>()
            var out = [LibTrack]()
            func walk(_ n: LibNode) {
                for c in children(of: n.id) {
                    if c.isFolder { walk(c) } else {
                        for id in c.trackIDs where seen.insert(id).inserted { if let t = map[id] { out.append(t) } }
                    }
                }
            }
            walk(node)
            return out
        }
        return node.trackIDs.compactMap { map[$0] }
    }

    /// Kan `node` flyttes ind under `parent` (ikke ind i sig selv eller sine egne undermapper)?
    func canMove(_ node: UUID, under parent: UUID?) -> Bool {
        var p = parent
        while let cur = p {
            if cur == node { return false }
            p = nodes.first { $0.id == cur }?.parent
        }
        return true
    }

    func nextSort(under parent: UUID?) -> Int {
        (nodes.filter { $0.parent == parent }.map(\.sort).max() ?? -1) + 1
    }
}
