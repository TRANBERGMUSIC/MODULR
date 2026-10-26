// MODULR – biblioteket: alle filer du sætter ind i MODULR havner her og analyseres
// (BPM, toneart, energi, RGB-waveform, reel kvalitet, cover). Mapper og playlister,
// udskiftning med bedre version (samme data, cover flyttes med) og eksport til USB.

import Foundation
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var index = LibraryIndex()
    @Published var analyzing: Set<UUID> = []
    @Published var working: Set<UUID> = []
    @Published var lastMessage: String?

    private let lock = NSLock()
    private var data = LibraryIndex()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))
        q.qualityOfService = .utility
        return q
    }()
    private var saveScheduled = false

    static let audioExts: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "alac"]

    static var folder: URL {
        let d = AppFolders.support.appendingPathComponent("Bibliotek", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static var artFolder: URL { sub("Covers") }
    static var waveFolder: URL { sub("Waveforms") }
    private static func sub(_ n: String) -> URL {
        let d = folder.appendingPathComponent(n, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static var indexFile: URL { folder.appendingPathComponent("library.json") }

    init() {
        if let d = try? Data(contentsOf: Self.indexFile),
           let idx = try? JSONDecoder().decode(LibraryIndex.self, from: d) {
            data = idx
        }
        index = data
        // Genoptag analyse af sange der ikke blev færdige
        for t in data.tracks where !t.analyzed { enqueueAnalysis(t.id) }
    }

    // MARK: Gem

    private func mutate(_ change: (inout LibraryIndex) -> Void) {
        lock.lock()
        change(&data)
        let snapshot = data
        lock.unlock()
        DispatchQueue.main.async { self.index = snapshot }
        scheduleSave()
    }

    private func scheduleSave() {
        lock.lock()
        if saveScheduled { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
            self.lock.lock()
            self.saveScheduled = false
            let snapshot = self.data
            self.lock.unlock()
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: Self.indexFile, options: .atomic) }
        }
    }

    func snapshot() -> LibraryIndex {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func artURL(_ t: LibTrack) -> URL? { t.artFile.map { Self.artFolder.appendingPathComponent($0) } }
    func waveURL(_ t: LibTrack) -> URL { Self.waveFolder.appendingPathComponent("\(t.id.uuidString).bin") }
    func bands(_ t: LibTrack) -> [UInt8] { (try? Data(contentsOf: waveURL(t))).map { [UInt8]($0) } ?? [] }

    // MARK: Import

    /// Sætter filer/mapper ind i biblioteket. Returnerer de sange der hører til (nye og eksisterende).
    @discardableResult
    func importFiles(_ urls: [URL], into playlist: UUID? = nil) -> [UUID] {
        var files = [URL]()
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = en?.nextObject() as? URL {
                    if Self.audioExts.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else if Self.audioExts.contains(u.pathExtension.lowercased()) {
                files.append(u)
            }
        }
        var ids = [UUID]()
        var fresh = [UUID]()
        mutate { idx in
            for f in files {
                let p = f.standardizedFileURL.path
                if let existing = idx.tracks.first(where: { $0.path == p }) {
                    ids.append(existing.id)
                    continue
                }
                var t = LibTrack(path: p)
                Self.applyTags(&t)
                idx.tracks.append(t)
                ids.append(t.id)
                fresh.append(t.id)
            }
            if let pl = playlist, let i = idx.nodes.firstIndex(where: { $0.id == pl && !$0.isFolder }) {
                for id in ids where !idx.nodes[i].trackIDs.contains(id) { idx.nodes[i].trackIDs.append(id) }
            }
        }
        for id in fresh { enqueueAnalysis(id) }
        let n = fresh.count
        if n > 0 {
            DispatchQueue.main.async { self.lastMessage = "\(n) sange tilføjet til biblioteket – analyserer …" }
        }
        return ids
    }

    /// Titel, kunstner osv. fra tags (eller filnavn) – BPM og toneart hvis filen allerede har dem.
    static func applyTags(_ t: inout LibTrack) {
        let url = URL(fileURLWithPath: t.path)
        let tags = Analyzer.readAllTags(url: url)
        let fallback = Analyzer.readTags(url: url)
        if let title = tags["title"] ?? fallback.title { t.title = title }
        t.artist = tags["artist"] ?? fallback.artist ?? ""
        t.album = tags["album"] ?? ""
        t.genre = tags["genre"] ?? ""
        t.comment = tags["comments"] ?? tags["comment"] ?? ""
        if let y = tags["year"].flatMap({ Int($0.prefix(4)) }) { t.year = y }
        if let b = tags["tempo"].flatMap({ Double($0.replacingOccurrences(of: ",", with: ".")) }), b > 40, b < 300 { t.bpm = b }
        // Kommentaren bruges kun, hvis den starter med en Camelot-toneart (Mixed In Key: "8A - Energy 6")
        let commentKey = t.comment.range(of: #"^\s*\d{1,2}[AB]\b"#, options: .regularExpression) != nil ? MusicalKey.parse(t.comment) : nil
        if let k = MusicalKey.parse(tags["key signature"]) ?? MusicalKey.parse(tags["initial key"]) ?? commentKey {
            t.key = k
        }
    }

    func reanalyze(_ ids: [UUID]) {
        mutate { idx in
            for i in idx.tracks.indices where ids.contains(idx.tracks[i].id) {
                idx.tracks[i].analyzed = false
                idx.tracks[i].analysisError = nil
            }
        }
        for id in ids { enqueueAnalysis(id) }
    }

    private func enqueueAnalysis(_ id: UUID) {
        DispatchQueue.main.async { self.analyzing.insert(id) }
        queue.addOperation { [weak self] in
            self?.analyzeNow(id)
            DispatchQueue.main.async { self?.analyzing.remove(id) }
        }
    }

    private func analyzeNow(_ id: UUID) {
        guard var t = snapshot().track(id) else { return }
        let url = t.url
        guard FileManager.default.fileExists(atPath: t.path) else {
            update(id) { $0.analysisError = "Filen findes ikke længere"; $0.analyzed = true }
            return
        }
        do {
            let (report, _) = try Analyzer.quality(url: url)
            t.codec = report.format.codec
            t.statedKbps = report.format.nominalKbps
            t.tierKbps = report.tierKbps
            t.qualityLabel = report.label
            t.sampleRate = report.format.sampleRate
            t.bitDepth = report.format.bitDepth
            let attrs = try? FileManager.default.attributesOfItem(atPath: t.path)
            t.fileSize = (attrs?[.size] as? NSNumber)?.int64Value

            let music = try MusicAnalyzer.analyze(url: url)
            try Data(music.bands).write(to: waveURL(t), options: .atomic)
            t.hasWave = true
            t.duration = music.duration
            if t.bpm == nil || t.bpm == 0 { t.bpm = music.bpm }
            t.firstBeatMs = music.firstBeatMs
            if t.key == nil { t.key = music.key }
            t.energy = music.energy
            t.analyzed = true
            t.analysisError = nil
        } catch {
            t.analyzed = true
            t.analysisError = error.localizedDescription
        }
        // Cover
        let sem = DispatchSemaphore(value: 0)
        let box = DataBox()
        Task.detached {
            box.value = await ArtworkLibrary.extract(from: url)
            sem.signal()
        }
        sem.wait()
        var art = box.value
        if art == nil, let song = ArtworkLibrary.song(for: url), let e = ArtworkLibrary.shared.find(for: song) {
            art = ArtworkLibrary.shared.imageData(e)
        }
        if let a = art, let jpeg = ArtworkImage.libraryJPEG(data: a) {
            let name = "\(t.id.uuidString).jpg"
            try? jpeg.write(to: Self.artFolder.appendingPathComponent(name), options: .atomic)
            t.artFile = name
            DispatchQueue.main.async { CoverCache.cache.removeObject(forKey: name as NSString) }
            if let song = ArtworkLibrary.song(for: url) {
                ArtworkLibrary.shared.add(a, song: song, source: "Fra fil: \(url.lastPathComponent)", file: url)
            }
        }
        let final = t
        update(id) { $0 = final }
        WaveformCache.shared.invalidate(id)
    }

    func update(_ id: UUID, _ change: (inout LibTrack) -> Void) {
        mutate { idx in
            if let i = idx.tracks.firstIndex(where: { $0.id == id }) { change(&idx.tracks[i]) }
        }
    }

    func remove(_ ids: [UUID]) {
        mutate { idx in
            idx.tracks.removeAll { ids.contains($0.id) }
            for i in idx.nodes.indices { idx.nodes[i].trackIDs.removeAll { ids.contains($0) } }
        }
    }

    // MARK: Mapper og playlister

    @discardableResult
    func createNode(name: String, parent: UUID?, folder: Bool) -> UUID {
        var id = UUID()
        mutate { idx in
            let n = LibNode(name: name, parent: parent, isFolder: folder, sort: idx.nextSort(under: parent))
            id = n.id
            idx.nodes.append(n)
        }
        return id
    }

    func rename(_ node: UUID, to name: String) {
        mutate { idx in if let i = idx.nodes.firstIndex(where: { $0.id == node }) { idx.nodes[i].name = name } }
    }

    func deleteNode(_ node: UUID) {
        mutate { idx in
            var doomed: Set<UUID> = [node]
            var changed = true
            while changed {
                changed = false
                for n in idx.nodes where n.parent.map(doomed.contains) == true && !doomed.contains(n.id) {
                    doomed.insert(n.id)
                    changed = true
                }
            }
            idx.nodes.removeAll { doomed.contains($0.id) }
        }
    }

    func move(_ node: UUID, under parent: UUID?) {
        mutate { idx in
            guard idx.canMove(node, under: parent), let i = idx.nodes.firstIndex(where: { $0.id == node }) else { return }
            if let p = parent, idx.nodes.first(where: { $0.id == p })?.isFolder != true { return }
            idx.nodes[i].parent = parent
            idx.nodes[i].sort = idx.nextSort(under: parent)
        }
    }

    func add(_ tracks: [UUID], to playlist: UUID) {
        mutate { idx in
            guard let i = idx.nodes.firstIndex(where: { $0.id == playlist && !$0.isFolder }) else { return }
            for t in tracks where !idx.nodes[i].trackIDs.contains(t) { idx.nodes[i].trackIDs.append(t) }
        }
    }

    func removeFromPlaylist(_ tracks: [UUID], playlist: UUID) {
        mutate { idx in
            if let i = idx.nodes.firstIndex(where: { $0.id == playlist }) { idx.nodes[i].trackIDs.removeAll { tracks.contains($0) } }
        }
    }

    // MARK: Udskift med bedre version

    enum ReplaceError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    /// Udskifter filen – sangen beholder sine data og playlister, kun lydfilen bliver bedre.
    /// Tjekker fingerprint (samme sang) og at kvaliteten reelt er bedre; cover og tags følger med.
    func replaceFile(_ id: UUID, with newURL: URL, rule: ImprovementRule, force: Bool = false) async throws -> String {
        guard let t = snapshot().track(id) else { throw ReplaceError.message("Sangen findes ikke") }
        await MainActor.run { _ = self.working.insert(id) }
        let me = self
        defer { Task { @MainActor in me.working.remove(id) } }
        let fm = FileManager.default
        let old = t.url
        let oldExists = fm.fileExists(atPath: old.path)

        var notes = [String]()
        if oldExists, Fingerprinter.fpcalcPath() != nil {
            let a = try await Task.detached { try Fingerprinter.fingerprint(of: old) }.value
            let b = try await Task.detached { try Fingerprinter.fingerprint(of: newURL) }.value
            let (verdict, cmp) = Fingerprinter.verdict(a, b)
            switch verdict {
            case .same: notes.append("Samme sang (\(cmp.percent) % match)")
            case .otherVersion(let m), .different(let m):
                if !force { throw ReplaceError.message(m) }
                notes.append("Udskiftet efter dit OK (\(m))")
            }
        }
        let (newQ, _) = try await Task.detached { try Analyzer.quality(url: newURL) }.value
        let oldTier = t.tierKbps ?? 128
        let oldQ = Quality.make(format: FormatInfo(codec: t.codec, container: t.codec, nominalKbps: t.statedKbps,
                                                   sampleRate: t.sampleRate ?? 44100, bitDepth: t.bitDepth, channels: 2),
                                cutoffHz: nil, tierKbps: oldTier, tierLabel: oldTier >= 9999 ? "Fuld båndbredde" : "\(oldTier) kbps")
        let (better, why) = Quality.isBetter(newQ, than: oldQ, rule: rule)
        if !better { throw ReplaceError.message(why) }

        let oldTags = oldExists ? Analyzer.readAllTags(url: old) : [:]
        var art: Data? = artURL(t).flatMap { try? Data(contentsOf: $0) }
        if art == nil, oldExists { art = await ArtworkLibrary.extract(from: old) }

        let dir = old.deletingLastPathComponent()
        let base = old.deletingPathExtension().lastPathComponent
        let ext = newURL.pathExtension.lowercased()
        let staging = dir.appendingPathComponent(".modulr-\(UUID().uuidString).\(ext)")
        try fm.copyItem(at: newURL, to: staging)
        if oldExists {
            do {
                try fm.trashItem(at: old, resultingItemURL: nil)
                notes.append("Den gamle fil er i papirkurven")
            } catch {
                try? fm.removeItem(at: staging)
                throw ReplaceError.message("Kunne ikke flytte den gamle fil: \(error.localizedDescription)")
            }
        }
        var dest = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        try fm.moveItem(at: staging, to: dest)

        // Samme data: titel, kunstner, album, genre, år, BPM, toneart og kommentar fra den gamle sang
        if ArtworkLibrary.writableExts.contains(ext) {
            var frames = [ID3.Frame]()
            var values = [(String, String?)]()
            values.append(("TIT2", t.title))
            values.append(("TPE1", t.artist.isEmpty ? oldTags["artist"] : t.artist))
            values.append(("TALB", t.album.isEmpty ? oldTags["album"] : t.album))
            values.append(("TCON", t.genre.isEmpty ? oldTags["genre"] : t.genre))
            let yearText: String? = t.year.map { String($0) } ?? oldTags["year"]
            values.append(("TYER", yearText))
            let bpmText: String? = t.bpm.map { String(Int($0.rounded())) }
            values.append(("TBPM", bpmText))
            values.append(("TKEY", t.key?.classic))
            for (fid, v) in values { if let v, !v.isEmpty { frames.append(ID3.textFrame(fid, v)) } }
            if let art, let cdj = ArtworkImage.cdjJPEG(data: art) {
                frames.append(ID3.pictureFrame(jpeg: cdj))
                notes.append("Cover flyttet over")
            }
            do { try AudioTagger.setFrames(frames, on: dest) } catch { notes.append("Tags kunne ikke skrives: \(error.localizedDescription)") }
        } else {
            notes.append("\(ext.uppercased()) kan ikke få cover – brug WAV, AIFF eller MP3")
        }

        update(id) {
            $0.history.append($0.path)
            $0.path = dest.path
            $0.codec = newQ.format.codec
            $0.statedKbps = newQ.format.nominalKbps
            $0.tierKbps = newQ.tierKbps
            $0.qualityLabel = newQ.label
            $0.sampleRate = newQ.format.sampleRate
            $0.bitDepth = newQ.format.bitDepth
        }
        reanalyze([id])     // ny waveform af den nye fil (BPM og toneart bevares)
        return "\(t.title): \(newQ.label). " + notes.joined(separator: " · ")
    }

    /// "Find bedre version" har gemt en bedre fil ved siden af – sangen peger nu på den.
    func adoptBetterFile(originalPath: String, newPath: String) {
        guard let t = snapshot().tracks.first(where: { $0.path == originalPath }) else {
            importFiles([URL(fileURLWithPath: newPath)])
            return
        }
        update(t.id) {
            $0.history.append($0.path)
            $0.path = newPath
        }
        reanalyze([t.id])
    }

    // MARK: USB-eksport

    /// Bygger en sang til USB-skriveren: lydfil, data, covers (80 og 240 px) og waveform-bånd.
    func usbTrack(_ t: LibTrack, tempDir: URL) -> [String: Any] {
        var d = [String: Any]()
        d["source"] = t.path
        d["title"] = t.title
        d["artist"] = t.artist
        d["album"] = t.album
        d["genre"] = t.genre
        d["key"] = t.key?.classic ?? ""
        d["bpm"] = t.bpm ?? 0
        d["duration"] = t.duration ?? 0
        d["year"] = t.year ?? 0
        d["sample_rate"] = Int(t.sampleRate ?? 44100)
        d["bitrate"] = t.statedKbps ?? 0
        d["depth"] = t.bitDepth ?? 16
        var commentParts = [String]()
        if let k = t.key { commentParts.append(k.camelot) }
        if let e = t.energy { commentParts.append("Energy \(e)") }
        d["comment"] = commentParts.joined(separator: " - ")
        if let a = artURL(t), let raw = try? Data(contentsOf: a) {
            let small = tempDir.appendingPathComponent("\(t.id.uuidString)-s.jpg")
            let big = tempDir.appendingPathComponent("\(t.id.uuidString)-m.jpg")
            if let s = ArtworkImage.squareJPEG(data: raw, side: 80) { try? s.write(to: small); d["artwork"] = small.path }
            if let b = ArtworkImage.squareJPEG(data: raw, side: 240) { try? b.write(to: big); d["artwork_m"] = big.path }
        }
        var analysis = [String: Any]()
        analysis["bpm"] = t.bpm ?? 0
        analysis["duration"] = t.duration ?? 0
        analysis["first_beat_ms"] = t.firstBeatMs ?? 0
        analysis["bands"] = Data(bands(t)).base64EncodedString()
        d["analysis"] = analysis
        return d
    }
}

final class DataBox: @unchecked Sendable {
    var value: Data?
}

// MARK: - Waveform-billeder (cache)

final class WaveformCache {
    static let shared = WaveformCache()
    private let cache = NSCache<NSString, CGImage>()

    func invalidate(_ id: UUID) {
        for w in [120, 600, 1200, 2400] { cache.removeObject(forKey: "\(id.uuidString)-\(w)" as NSString) }
    }

    /// RGB-waveform som rekordbox: bas = rød, mellem = grøn, diskant = blå; højde = det kraftigste bånd.
    func image(for t: LibTrack, width: Int, height: Int, store: LibraryStore) -> CGImage? {
        let key = "\(t.id.uuidString)-\(width)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let bands = store.bands(t)
        guard bands.count >= 3 else { return nil }
        let cols = bands.count / 3
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let mid = Double(height) / 2
        for x in 0..<width {
            let a = x * cols / width, b = max(a + 1, (x + 1) * cols / width)
            var lo = 0, mi = 0, hi = 0
            for c in a..<min(b, cols) {
                lo = max(lo, Int(bands[c * 3])); mi = max(mi, Int(bands[c * 3 + 1])); hi = max(hi, Int(bands[c * 3 + 2]))
            }
            let top = max(lo, mi, hi)
            guard top > 0 else { continue }
            let h = Double(top) / 255 * mid
            // farve: normaliseret blanding, lysere jo mere diskant
            let s = 255.0 / Double(top)
            let loD: Double = Double(lo), miD: Double = Double(mi), hiD: Double = Double(hi)
            let rV: Double = loD * s * 0.95 + hiD * 0.25
            let gV: Double = miD * s * 0.75 + hiD * 0.25
            let bV: Double = hiD * s * 0.95
            let r = UInt8(min(255.0, rV))
            let g = UInt8(min(255.0, gV))
            let bl = UInt8(min(255.0, bV))
            for y in 0..<height {
                let dy = abs(Double(y) + 0.5 - mid)
                guard dy <= h else { continue }
                let i = (y * width + x) * 4
                px[i] = r; px[i + 1] = g; px[i + 2] = bl; px[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
