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
    private let fixQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1     // én ad gangen – hele filen ligger i hukommelsen
        q.qualityOfService = .utility
        return q
    }()
    private var saveScheduled = false
    @Published var fixing: Set<UUID> = []

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
        // Genoptag analyse af sange der ikke blev færdige – og lav ny waveform til sange
        // analyseret med en ældre version
        for i in data.tracks.indices where (data.tracks[i].waveVersion ?? 0) < LibTrack.currentWaveVersion {
            data.tracks[i].analyzed = false
        }
        index = data
        for t in data.tracks where !t.analyzed { enqueueAnalysis(t.id) }
        // Sange analyseret før lydstyrke-målingen kom med: mål dem nu
        for t in data.tracks where t.analyzed && t.lufs == nil && t.analysisError == nil { enqueueMeasure(t.id) }
    }

    private func enqueueMeasure(_ id: UUID) {
        DispatchQueue.main.async { self.analyzing.insert(id) }
        queue.addOperation { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.analyzing.remove(id) } }
            guard let t = self.snapshot().track(id) else { return }
            if let m = try? Loudness.measure(url: t.url) {
                self.update(id) { $0.lufs = m.lufs; $0.peakDB = m.peakDB }
                if LoudnessPrefs.autoFix, let nt = self.snapshot().track(id), nt.needsLoudnessFix(target: LoudnessPrefs.target) {
                    self.enqueueLoudnessFix(id)
                }
            }
        }
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
            t.waveVersion = LibTrack.currentWaveVersion
            t.duration = music.duration
            if t.gridEdited != true {
                if t.bpm == nil || t.bpm == 0 { t.bpm = music.bpm }
                t.firstBeatMs = music.firstBeatMs
            }
            if t.key == nil { t.key = music.key }
            t.energy = music.energy
            if let m = try? Loudness.measure(url: url) {
                t.lufs = m.lufs
                t.peakDB = m.peakDB
            }
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
        DispatchQueue.main.async {
            if PlayerModel.shared.track?.id == id { PlayerModel.shared.refreshBands() }
        }
        if LoudnessPrefs.autoFix, final.analysisError == nil, final.needsLoudnessFix(target: LoudnessPrefs.target) {
            enqueueLoudnessFix(id)
        }
    }

    // MARK: Lydstyrke og EQ (som Platinum Notes)

    struct ProcessJob: Identifiable, Equatable {
        enum Status: Equatable { case waiting, working, done, skipped, failed }
        var id: UUID
        var name: String
        var kind: String
        var status: Status
        var clips: Int?
        var limitingDB: Double?
        var before: Double?
        var after: Double?
        var note: String
    }

    @Published var jobs: [ProcessJob] = []

    static var originalsFolder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let d = music.appendingPathComponent("MODULR/Originaler", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var processFolder: URL { sub("Behandling") }

    func envelopes(_ id: UUID) -> (before: LoudnessEnvelope?, after: LoudnessEnvelope?) {
        let b = (try? Data(contentsOf: Self.processFolder.appendingPathComponent("\(id.uuidString)-before.bin"))).flatMap(LoudnessEnvelope.init(data:))
        let a = (try? Data(contentsOf: Self.processFolder.appendingPathComponent("\(id.uuidString)-after.bin"))).flatMap(LoudnessEnvelope.init(data:))
        return (b, a)
    }

    private func setJob(_ job: ProcessJob) {
        DispatchQueue.main.async {
            if let i = self.jobs.firstIndex(where: { $0.id == job.id }) {
                self.jobs[i] = job
            } else {
                self.jobs.insert(job, at: 0)
                if self.jobs.count > 100 { self.jobs.removeLast(self.jobs.count - 100) }
            }
        }
    }

    /// Retter lydstyrken (i kø, én ad gangen). `force` = du bad selv om det: behandles uanset hvad.
    func fixLoudness(_ ids: [UUID], force: Bool = false) {
        if force {
            mutate { idx in
                for i in idx.tracks.indices where ids.contains(idx.tracks[i].id) { idx.tracks[i].loudnessSkip = nil }
            }
        }
        let target = LoudnessPrefs.target
        let todo = snapshot().tracks.filter { ids.contains($0.id) && (force || $0.needsLoudnessFix(target: target)) }
        for t in todo { enqueueProcess(t.id, eq: nil, force: force) }
        DispatchQueue.main.async {
            self.lastMessage = todo.isEmpty ? "Alle sange er allerede på \(Int(target)) LUFS"
                : "Retter lydstyrken på \(todo.count) sange til \(Int(target)) LUFS – se Fiks tracks"
        }
    }

    func fixAllLoudness() {
        let target = LoudnessPrefs.target
        fixLoudness(snapshot().tracks.filter { $0.needsLoudnessFix(target: target) }.map(\.id))
    }

    /// Lægger EQ'en ind i filen (og retter lydstyrken bagefter, så sangen stadig ligger på målet).
    func applyEQ(_ id: UUID, eq: EQSettings) {
        enqueueProcess(id, eq: eq, force: true)
    }

    private func enqueueLoudnessFix(_ id: UUID) { enqueueProcess(id, eq: nil, force: false) }

    private func enqueueProcess(_ id: UUID, eq: EQSettings?, force: Bool) {
        lock.lock()
        let already = pendingFixes.contains(id)
        if !already { pendingFixes.insert(id) }
        lock.unlock()
        if already { return }
        if let t = snapshot().track(id) {
            setJob(ProcessJob(id: id, name: t.title, kind: eq == nil ? "Lydstyrke" : "EQ + lydstyrke", status: .waiting,
                              before: t.lufs, note: "Venter"))
        }
        DispatchQueue.main.async { self.fixing.insert(id) }
        fixQueue.addOperation { [weak self] in
            guard let self else { return }
            self.processNow(id, eq: eq, force: force)
            self.lock.lock()
            self.pendingFixes.remove(id)
            self.lock.unlock()
            DispatchQueue.main.async { self.fixing.remove(id) }
        }
    }
    private var pendingFixes = Set<UUID>()

    private func processNow(_ id: UUID, eq: EQSettings?, force: Bool) {
        let target = LoudnessPrefs.target
        guard let t = snapshot().track(id) else { return }
        var job = ProcessJob(id: id, name: t.title, kind: eq == nil ? "Lydstyrke" : "EQ + lydstyrke", status: .working,
                             before: t.lufs, note: "Behandler …")
        if eq == nil && !force && !t.needsLoudnessFix(target: target) {
            job.status = .skipped
            job.after = t.lufs
            job.note = "Allerede klar"
            setJob(job)
            return
        }
        setJob(job)
        let fm = FileManager.default
        let url = t.url
        guard fm.fileExists(atPath: url.path) else {
            job.status = .failed; job.note = "Filen findes ikke"; setJob(job)
            return
        }

        // 1) Originalen gemmes første gang. Er sangen behandlet før, arbejdes der ud fra originalen
        //    (aldrig limiter oven på limiter).
        var backup = t.originalBackup
        var source = url
        if let b = backup, fm.fileExists(atPath: b) {
            source = URL(fileURLWithPath: b)
        } else {
            let base = url.deletingPathExtension().lastPathComponent
            let dest = Self.originalsFolder.appendingPathComponent("\(base) [\(t.id.uuidString.prefix(8))].\(url.pathExtension)")
            try? fm.removeItem(at: dest)
            do { try fm.copyItem(at: url, to: dest) } catch {
                job.status = .failed; job.note = "Kunne ikke gemme originalen – intet er ændret"; setJob(job)
                return
            }
            backup = dest.path
        }

        do {
            let (srcCh, sr) = try Loudness.read(url: source)
            let beforeEnv = Loudness.envelope(srcCh)
            let clips = Loudness.countClips(srcCh)
            let lufsSrc = Loudness.integratedLUFS(srcCh, sr: sr)
            let peakSrc = Loudness.peakDB(srcCh)
            job.before = lufsSrc
            job.clips = clips
            try? beforeEnv.data.write(to: Self.processFolder.appendingPathComponent("\(id.uuidString)-before.bin"))

            if eq == nil && !force && abs(lufsSrc - target) <= 0.5 && clips == 0 && source == url {
                job.status = .skipped; job.after = lufsSrc; job.note = "Allerede klar"
                setJob(job)
                update(id) { $0.loudnessFixedAt = target; $0.loudnessNote = "Allerede på målet"; $0.originalBackup = backup }
                return
            }

            var outURL = url
            var note: String
            var afterCh: [[Float]]
            var limiting = 0.0
            var repaired = 0
            let steps = Loudness.mp3Steps(lufs: lufsSrc, peakDB: peakSrc, target: target)
            let lossless = eq == nil && t.ext == "mp3" && clips < 20 && abs(lufsSrc + Double(steps) * 1.5 - target) <= 0.8

            if lossless {
                // MP3: tabsfri ændring af global_gain – ingen genkodning
                let data = try Data(contentsOf: source)
                let (out, frames) = Loudness.mp3ApplyGain(data, steps: steps)
                guard frames > 0 else { throw LoudnessError.failed("Ingen MP3-rammer fundet") }
                let tmp = url.deletingLastPathComponent().appendingPathComponent(".modulr-\(UUID().uuidString).mp3")
                try out.write(to: tmp)
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
                let g = Float(pow(10, Double(steps) * 1.5 / 20))
                afterCh = srcCh.map { $0.map { $0 * g } }
                note = String(format: "%+.1f dB uden genkodning", Double(steps) * 1.5)
            } else {
                // PCM: (EQ) → klippede toppe genskabes → gain → limiter (top −1 dBFS)
                let input = eq.map { e in (try? EQRender.render(url: source, eq: e).0) ?? srcCh } ?? srcCh
                let (out, res) = Loudness.normalizePCM(input, sr: sr, target: target, maxLimitingDB: Loudness.maxLimitingDB)
                limiting = res.limitingDB
                repaired = res.clipsRepaired
                afterCh = out
                let keepFormat = ["wav", "aif", "aiff"].contains(t.ext)
                if !keepFormat {
                    // MP3/FLAC/M4A kan ikke skrives tilbage uden tab → gemmes som 24-bit WAV ved siden af
                    let dir = url.deletingLastPathComponent()
                    let base = url.deletingPathExtension().lastPathComponent
                    var dest = dir.appendingPathComponent("\(base).wav")
                    var n = 2
                    while fm.fileExists(atPath: dest.path) {
                        dest = dir.appendingPathComponent("\(base) (\(n)).wav")
                        n += 1
                    }
                    outURL = dest
                }
                let tmp = outURL.deletingLastPathComponent().appendingPathComponent(".modulr-\(UUID().uuidString).\(outURL.pathExtension)")
                try Loudness.writePCM(out, sr: sr, to: tmp)
                try? AudioTagger.setFrames(tagFrames(for: t, from: url), on: tmp)
                if outURL == url {
                    _ = try fm.replaceItemAt(url, withItemAt: tmp)
                } else {
                    try fm.moveItem(at: tmp, to: outURL)
                    try? fm.trashItem(at: url, resultingItemURL: nil)     // originalen ligger i Musik/MODULR/Originaler
                }
                note = res.note
                if !keepFormat { note += " · gemt som WAV" }
            }

            let afterEnv = Loudness.envelope(afterCh)
            try? afterEnv.data.write(to: Self.processFolder.appendingPathComponent("\(id.uuidString)-after.bin"))
            let m = try? Loudness.measure(url: outURL)
            let size = ((try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? NSNumber)?.int64Value
            let finalNote = note
            let newPath = outURL.path
            let lim = limiting
            let rep = repaired
            let before = lufsSrc
            update(id) {
                if $0.path != newPath {
                    $0.history.append($0.path)
                    $0.path = newPath
                    $0.codec = "WAV"
                }
                if let m { $0.lufs = m.lufs; $0.peakDB = m.peakDB }
                $0.lufsBefore = before
                $0.loudnessFixedAt = target
                $0.loudnessNote = finalNote
                $0.originalBackup = backup
                $0.limitingDB = lim
                $0.clipsRepaired = rep
                if let eq { $0.eqApplied = [eq.low, eq.mid, eq.high] } else if source != url { $0.eqApplied = nil }
                if !lossless { $0.bitDepth = 24 }
                if let size { $0.fileSize = size }
            }
            job.status = .done
            job.after = m?.lufs
            job.limitingDB = limiting
            job.clips = max(clips, repaired)
            job.note = finalNote
            setJob(job)
            if eq != nil || outURL != url { reanalyze([id]) }
        } catch {
            job.status = .failed
            job.note = "Fejl: \(error.localizedDescription) – intet er ændret"
            setJob(job)
            update(id) { $0.loudnessNote = job.note; $0.originalBackup = backup }
        }
    }

    /// Tags og cover til den behandlede fil: filens egne ID3-frames, ellers MODULRs data.
    private func tagFrames(for t: LibTrack, from url: URL) -> [ID3.Frame] {
        if let tag = try? AudioTagger.readTag(of: url), let frames = ID3.parse(tag)?.frames, !frames.isEmpty { return frames }
        var frames = [ID3.Frame]()
        let yearText: String? = t.year.map { String($0) }
        let bpmText: String? = t.bpm.map { String(Int($0.rounded())) }
        var values = [(String, String?)]()
        values.append(("TIT2", t.title))
        values.append(("TPE1", t.artist))
        values.append(("TALB", t.album))
        values.append(("TCON", t.genre))
        values.append(("TYER", yearText))
        values.append(("TBPM", bpmText))
        values.append(("TKEY", t.key?.classic))
        for (fid, v) in values { if let v, !v.isEmpty { frames.append(ID3.textFrame(fid, v)) } }
        if let a = artURL(t), let raw = try? Data(contentsOf: a), let cdj = ArtworkImage.cdjJPEG(data: raw) {
            frames.append(ID3.pictureFrame(jpeg: cdj))
        }
        return frames
    }

    /// Lægger den urørte original tilbage og lader den være.
    func restoreOriginal(_ ids: [UUID]) {
        fixQueue.addOperation { [weak self] in self?.restoreNow(ids) }
    }

    private func restoreNow(_ ids: [UUID]) {
        let fm = FileManager.default
        var n = 0
        for t in snapshot().tracks where ids.contains(t.id) {
            guard let b = t.originalBackup, fm.fileExists(atPath: b) else { continue }
            let backupURL = URL(fileURLWithPath: b)
            var dest = t.url
            do {
                if backupURL.pathExtension.lowercased() == t.ext {
                    let tmp = t.url.deletingLastPathComponent().appendingPathComponent(".modulr-\(UUID().uuidString).\(t.ext)")
                    try fm.copyItem(at: backupURL, to: tmp)
                    _ = try fm.replaceItemAt(t.url, withItemAt: tmp)
                } else {
                    // Blev gemt som WAV – læg den oprindelige MP3/FLAC tilbage og fjern WAV'en
                    let dir = t.url.deletingLastPathComponent()
                    let base = t.url.deletingPathExtension().lastPathComponent
                    dest = dir.appendingPathComponent("\(base).\(backupURL.pathExtension)")
                    var k = 2
                    while fm.fileExists(atPath: dest.path) {
                        dest = dir.appendingPathComponent("\(base) (\(k)).\(backupURL.pathExtension)")
                        k += 1
                    }
                    try fm.copyItem(at: backupURL, to: dest)
                    try? fm.trashItem(at: t.url, resultingItemURL: nil)
                }
            } catch { continue }
            let m = try? Loudness.measure(url: dest)
            let newPath = dest.path
            update(t.id) {
                if $0.path != newPath {
                    $0.history.append($0.path)
                    $0.path = newPath
                    $0.codec = dest.pathExtension.uppercased()
                }
                if let m { $0.lufs = m.lufs; $0.peakDB = m.peakDB }
                $0.loudnessFixedAt = nil
                $0.loudnessSkip = true
                $0.eqApplied = nil
                $0.limitingDB = nil
                $0.clipsRepaired = nil
                $0.loudnessNote = "Original gendannet"
            }
            reanalyze([t.id])
            n += 1
        }
        let count = n
        DispatchQueue.main.async { self.lastMessage = count > 0 ? "\(count) originaler gendannet" : "Ingen originaler at gendanne" }
    }

    // MARK: Grid og markeringer

    func setGrid(_ id: UUID, bpm: Double, firstBeatMs: Double) {
        update(id) {
            $0.bpm = max(40, min(300, bpm))
            $0.firstBeatMs = firstBeatMs
            $0.gridEdited = true
        }
    }

    func addCue(_ id: UUID, at seconds: Double) {
        update(id) {
            var c = $0.cues ?? []
            if !c.contains(where: { abs($0 - seconds) < 0.05 }) { c.append(seconds) }
            $0.cues = c.sorted()
        }
    }

    func removeCue(_ id: UUID, near seconds: Double, tolerance: Double) {
        update(id) {
            guard var c = $0.cues, let i = c.indices.min(by: { abs(c[$0] - seconds) < abs(c[$1] - seconds) }),
                  abs(c[i] - seconds) <= tolerance else { return }
            c.remove(at: i)
            $0.cues = c
        }
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
            $0.resetLoudness()
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
            $0.resetLoudness()
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
        for w in [120, 192, 600, 1200, 2400] { cache.removeObject(forKey: "\(id.uuidString)-\(w)" as NSString) }
    }

    /// RGB-waveform som i rekordbox: tegnes nedefra; farven via WaveColor (bas rød, mellem grøn, diskant blå).
    func image(for t: LibTrack, width: Int, height: Int, store: LibraryStore) -> CGImage? {
        let key = "\(t.id.uuidString)-\(width)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let img = WaveformCache.render(bands: store.bands(t), width: width, height: height) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    static func render(bands: [UInt8], width: Int, height: Int) -> CGImage? {
        WaveShape.image(bands: bands, width: width, height: height)
    }
}
