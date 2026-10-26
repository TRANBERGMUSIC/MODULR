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
    var waveVersion: Int?
    static let currentWaveVersion = 5
    var addedAt: Date
    var analyzed: Bool
    var analysisError: String?
    var history: [String]         // tidligere filer (efter udskiftning)
    // Lydstyrke (som Platinum Notes)
    var lufs: Double?             // integreret lydstyrke (EBU R128)
    var peakDB: Double?
    var loudnessFixedAt: Double?  // det mål filen er rettet til
    var loudnessNote: String?
    var originalBackup: String?   // originalen før lydstyrken blev rettet
    var loudnessSkip: Bool?       // du har gendannet originalen – rør den ikke igen
    var gridEdited: Bool?         // du har rettet griddet – analysen må ikke overskrive det
    var eqApplied: [Double]?      // EQ gemt i filen (bas, mellem, diskant i dB)
    var lufsBefore: Double?       // lydstyrke før behandling
    var clipsRepaired: Int?
    var limitingDB: Double?
    var cues: [Double]?           // dine markeringer (sekunder) til at planlægge sættet
    var deadSpace: Double?        // sekunders stilhed til sidst
    var trimmed: Bool?            // død luft er fjernet

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

    static let gainFixableExts: Set<String> = ["mp3", "wav", "aif", "aiff"]
    var canFixLoudness: Bool { Self.gainFixableExts.contains(ext) }

    /// Skal lydstyrken rettes til målet? (mere end 1 dB ved siden af og ikke allerede rettet)
    func needsLoudnessFix(target: Double) -> Bool {
        guard let l = lufs, canFixLoudness, loudnessSkip != true else { return false }
        if let done = loudnessFixedAt, abs(done - target) < 0.05 { return false }
        return abs(l - target) > 1.0
    }

    /// 5–7 min ekstra stilhed til sidst (mod copyright-scanning) skal klippes væk.
    var needsTrim: Bool { (deadSpace ?? 0) >= 20 && trimmed != true && loudnessSkip != true }

    var needsFix: Bool { needsUpgrade || needsLoudnessFix(target: LoudnessPrefs.target) || needsTrim }

    mutating func resetLoudness() {
        lufs = nil
        peakDB = nil
        loudnessFixedAt = nil
        loudnessNote = nil
        originalBackup = nil
        loudnessSkip = nil
        eqApplied = nil
    }

    var lufsText: String {
        guard let l = lufs else { return "" }
        return String(format: "%.1f LUFS", l)
    }

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
    case upgrade = "Fiks tracks"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "infinity"
        case .queue: return "clock.arrow.circlepath"
        case .recent: return "sparkles"
        case .upgrade: return "wrench.and.screwdriver"
        }
    }

    func matches(_ t: LibTrack) -> Bool {
        switch self {
        case .all: return true
        case .queue: return !t.analyzed
        case .recent: return Date().timeIntervalSince(t.addedAt) < 14 * 24 * 3600
        case .upgrade: return t.analyzed && t.needsFix
        }
    }
}

/// Indstillinger for automatisk lydstyrke (gemt i UserDefaults).
enum LoudnessPrefs {
    static let targetKey = "loud.target"
    static let autoKey = "loud.auto"
    static var target: Double {
        let v = UserDefaults.standard.object(forKey: targetKey) as? Double ?? -9
        return min(-6, max(-14, v))
    }
    static var autoFix: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
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

/// Farven på en waveform-kolonne som i rekordbox (RGB): bas = rød, mellem = grøn, diskant = blå,
/// blandet additivt og lysnet en smule, så et fuldt mix bliver laksefarvet.
enum WaveColor {
    static let floor = 0.35

    /// `floor` 0,35 = pastel (overblik og tabel), ca. 0,08 = mættet som rekordbox' detaljevisning.
    static func rgb(_ lo: Double, _ mi: Double, _ hi: Double, floor f: Double = WaveColor.floor) -> (r: Double, g: Double, b: Double)? {
        let top = max(lo, max(mi, hi))
        guard top > 0 else { return nil }
        return (f + (1 - f) * lo / top, f + (1 - f) * mi / top, f + (1 - f) * hi / top)
    }

    /// Værdien (0–255) af et bånd ved en brøkdel af en kolonne, lineært interpoleret – så en zoomet
    /// waveform bliver blød i stedet for trappet.
    static func sample(_ bands: [UInt8], at col: Double, band k: Int) -> Double {
        let cols = bands.count / 3
        guard cols > 0 else { return 0 }
        let c = max(0, min(Double(cols - 1), col - 0.5))
        let i = Int(c)
        let j = min(cols - 1, i + 1)
        let f = c - Double(i)
        return Double(bands[i * 3 + k]) * (1 - f) + Double(bands[j * 3 + k]) * f
    }

    /// Kolonne `a..<b` af båndene (3 bytes pr. kolonne): blød top (gennemsnit + maksimum) og farve.
    static func column(_ bands: [UInt8], _ a: Int, _ b: Int) -> (height: Double, r: Double, g: Double, b: Double)? {
        let cols = bands.count / 3
        let lo0 = max(0, a), hi0 = min(cols, max(lo0 + 1, b))
        guard lo0 < cols else { return nil }
        var mx: [Double] = [0, 0, 0]
        var sum: [Double] = [0, 0, 0]
        for c in lo0..<hi0 {
            for k in 0..<3 {
                let v = Double(bands[c * 3 + k])
                if v > mx[k] { mx[k] = v }
                sum[k] += v
            }
        }
        let n = Double(hi0 - lo0)
        var v: [Double] = [0, 0, 0]
        for k in 0..<3 { v[k] = 0.6 * (sum[k] / n) + 0.4 * mx[k] }
        guard let c = rgb(v[0], v[1], v[2]) else { return nil }
        return (max(v[0], max(v[1], v[2])) / 255, c.r, c.g, c.b)
    }
}

/// Takt og slag ud fra BPM og første slag: 4 slag pr. takt, 8 takter pr. frase.
enum BeatGrid {
    static let beatsPerBar = 4
    static let barsPerPhrase = 8

    static func beatIndex(at t: Double, bpm: Double, firstBeat: Double) -> Int {
        guard bpm > 0 else { return 0 }
        return Int(floor((t - firstBeat) / (60 / bpm) + 1e-6))
    }

    static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

    /// "17.3": takt 17, slag 3 (1-baseret, som på en CDJ).
    static func position(at t: Double, bpm: Double, firstBeat: Double) -> (bar: Int, beat: Int, barsToPhrase: Int, beatsToPhrase: Int) {
        let i = beatIndex(at: t, bpm: bpm, firstBeat: firstBeat)
        let bar = Int(floor(Double(i) / Double(beatsPerBar))) + 1
        let beat = mod(i, beatsPerBar) + 1
        let phraseBeats = beatsPerBar * barsPerPhrase
        let beatsLeft = phraseBeats - mod(i, phraseBeats)
        let barsLeft = Int(ceil(Double(beatsLeft) / Double(beatsPerBar)))
        return (bar, beat, barsLeft, beatsLeft)
    }

    /// Første slag flyttet, så takt 1 starter ved `t` (bevarer BPM).
    static func downbeat(at t: Double, bpm: Double) -> Double {
        guard bpm > 0 else { return t }
        let bar = 60 / bpm * Double(beatsPerBar)
        return t - floor(t / bar) * bar
    }
}
