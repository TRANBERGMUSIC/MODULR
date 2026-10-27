// MODULR – USB: finder USB-stik med rekordbox-bibliotek, viser deres playlister og skriver
// MODULRs mapper, playlister og sange ind (via usb/pioneer_usb.py, som følger med appen).

import Foundation
import SwiftUI
import AppKit

struct UsbDrive: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    var format: String = ""

    /// CDJ'er læser kun FAT32 og exFAT (exFAT kun på nyere spillere som CDJ-3000). APFS/Mac OS Extended kan de ikke.
    var formatWarning: String? {
        let f = format.lowercased()
        if f.isEmpty || f.contains("fat") || f.contains("ms-dos") { return nil }
        return "USB'en er formateret som \(format). CDJ'er kan kun læse FAT32 eller exFAT – formatér den i Diskværktøj (MS-DOS (FAT) eller ExFAT, skema: Master Boot Record)."
    }
}

struct UsbTrackInfo: Codable, Identifiable, Hashable {
    let id: Int
    let title: String
    let artist: String
    let bpm: Double
    let key: String
    let duration: Int
    let path: String
    let artwork: String?

    /// Coverets fil på USB'en (den store udgave, hvis den findes).
    func artworkURL(root: URL) -> URL? {
        guard let a = artwork, !a.isEmpty else { return nil }
        let small = root.appendingPathComponent(String(a.drop(while: { $0 == "/" })))
        let big = URL(fileURLWithPath: small.path.replacingOccurrences(of: ".jpg", with: "_m.jpg"))
        if FileManager.default.fileExists(atPath: big.path) { return big }
        return FileManager.default.fileExists(atPath: small.path) ? small : nil
    }

    /// Samme id for samme fil hver gang (så afspilleren kan finde sangen i listen igen).
    static func stableID(_ path: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var h1: UInt64 = 1469598103934665603
        var h2: UInt64 = 1099511628211
        for b in path.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 1099511628211
            h2 = (h2 &+ UInt64(b)) &* 6364136223846793005
        }
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: h1 >> (UInt64(i) * 8)) }
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: h2 >> (UInt64(i) * 8)) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func fileURL(root: URL) -> URL {
        root.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
    }

    /// Til afspilleren: sangen fra biblioteket hvis den findes der (samme filnavn), ellers sangen fra USB'en.
    func playable(root: URL) -> LibTrack {
        let file = fileURL(root: root)
        let name = file.deletingPathExtension().lastPathComponent.lowercased()
        if let lib = LibraryStore.shared.index.tracks.first(where: {
            $0.url.deletingPathExtension().lastPathComponent.lowercased() == name && FileManager.default.fileExists(atPath: $0.path)
        }) {
            return lib
        }
        var t = LibTrack(path: file.path)
        t.id = UsbTrackInfo.stableID(file.path)
        t.title = title
        t.artist = artist
        t.bpm = bpm > 0 ? bpm : nil
        t.key = MusicalKey.parse(key)
        t.duration = Double(duration)
        return t
    }
}

struct UsbNodeInfo: Codable, Identifiable, Hashable {
    let id: Int
    let parent: Int
    let sort: Int
    let folder: Bool
    let name: String
    let tracks: [Int]
}

struct UsbContents: Codable {
    let ok: Bool
    let error: String?
    let tracks: [UsbTrackInfo]?
    let nodes: [UsbNodeInfo]?
    let onelibrary: Bool?
    var misplaced: Int? = nil       // MODULR-sange hvis analyse ligger et sted CDJ'en ikke kigger
}

/// Ændringer der venter på at blive skrevet til USB'en.
struct UsbPending: Identifiable, Equatable {
    enum Parent: Hashable { case root, existing(Int), new(String) }
    enum Kind: Equatable { case folder, playlist, addTo(Int) }

    let id = UUID()
    let key: String
    var kind: Kind
    var name: String
    var parent: Parent
    var tracks: [UUID]
}

/// Én indstilling i en af USB'ens My Settings-filer (MYSETTING/MYSETTING2/DJMMYSETTING/DEVSETTING.DAT).
struct UsbSettingField: Identifiable, Hashable {
    var id: String { file + "/" + name }
    let file: String
    let name: String
    let label: String
    let options: [UsbSettingOption]
    let defaultValue: Int
}

struct UsbSettingOption: Hashable, Identifiable {
    var id: Int { value }
    let value: Int
    let label: String
}

struct UsbSettings {
    var fields: [UsbSettingField] = []
    var values: [String: [String: Int]] = [:]     // fil → felt → værdi
    var missing: Set<String> = []
    var problems: [String: String] = [:]

    static let fileOrder = ["DEVSETTING.DAT", "MYSETTING.DAT", "MYSETTING2.DAT", "DJMMYSETTING.DAT"]
    static let fileTitle = ["DEVSETTING.DAT": "Visning (waveform og toneart)", "MYSETTING.DAT": "CDJ – My Settings",
                            "MYSETTING2.DAT": "CDJ – My Settings 2", "DJMMYSETTING.DAT": "DJM-mixer"]

    func value(_ f: UsbSettingField) -> Int? { values[f.file]?[f.name] }

    /// 1 = BLUE, 3 = RGB, 4 = 3Band (DEVSETTING.DAT)
    var waveformColor: Int? { values["DEVSETTING.DAT"]?["waveform_color"] }

    static func decode(_ obj: [String: Any]) -> UsbSettings {
        var out = UsbSettings()
        let layout = obj["layout"] as? [String: Any] ?? [:]
        for file in fileOrder {
            guard let l = layout[file] as? [String: Any], let fs = l["fields"] as? [[Any]] else { continue }
            for f in fs where f.count >= 5 {
                let opts = (f[3] as? [[Any]] ?? []).compactMap { o -> UsbSettingOption? in
                    guard o.count >= 2, let v = (o[0] as? NSNumber)?.intValue else { return nil }
                    return UsbSettingOption(value: v, label: o[1] as? String ?? "\(v)")
                }
                out.fields.append(UsbSettingField(file: file, name: f[0] as? String ?? "", label: f[2] as? String ?? "",
                                                  options: opts, defaultValue: (f[4] as? NSNumber)?.intValue ?? 0))
            }
        }
        for (file, any) in obj["files"] as? [String: Any] ?? [:] {
            guard let d = any as? [String: Any] else { continue }
            if d["missing"] as? Bool == true { out.missing.insert(file); continue }
            if let e = d["error"] as? String { out.problems[file] = e; continue }
            if d["crc_ok"] as? Bool == false { out.problems[file] = "tjeksummen passer ikke – filen kan være beskadiget" }
            var vals = [String: Int]()
            for (k, v) in d["values"] as? [String: Any] ?? [:] { vals[k] = (v as? NSNumber)?.intValue }
            out.values[file] = vals
        }
        return out
    }
}

final class UsbStore: ObservableObject {
    static let shared = UsbStore()

    @Published var drives: [UsbDrive] = []
    @Published var contents: [String: UsbContents] = [:]
    @Published var loading: Set<String> = []
    @Published var pending: [String: [UsbPending]] = [:]
    @Published var writing: Set<String> = []
    @Published var message: String?
    /// Tælles op hver gang en USB er læst igen (så waveform-cellerne genindlæser fra stikket).
    @Published var revision = 0

    private var observers: [NSObjectProtocol] = []
    private var watchTimer: Timer?
    /// Sidst sete ændringstid/størrelse på USB'ens databaser (export.pdb og OneLibrary).
    private var seen: [String: String] = [:]
    /// En ændring skal have stået stille i ét tjek, før vi læser (rekordbox skriver over flere sekunder).
    private var settling: [String: String] = [:]

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        // Hold øje med USB'en: retter du noget i rekordbox, opdateres MODULR af sig selv.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.watch() }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func signature(_ d: UsbDrive) -> String {
        let fm = FileManager.default
        var parts = [String]()
        for rel in ["PIONEER/rekordbox/export.pdb", "PIONEER/rekordbox/exportExt.pdb", "PIONEER/rekordbox/exportLibrary.db",
                    "PIONEER/DEVSETTING.DAT", "PIONEER/MYSETTING.DAT", "PIONEER/MYSETTING2.DAT", "PIONEER/DJMMYSETTING.DAT"] {
            let path = d.url.appendingPathComponent(rel).path
            if let a = try? fm.attributesOfItem(atPath: path) {
                let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (a[.size] as? NSNumber)?.intValue ?? 0
                parts.append("\(rel):\(m):\(size)")
            }
        }
        return parts.joined(separator: "|")
    }

    private func watch() {
        for d in drives {
            // Vores egen skrivning og igangværende læsning tæller ikke
            if writing.contains(d.id) || loading.contains(d.id) || editing.contains(d.id) { continue }
            let sig = signature(d)
            guard !sig.isEmpty else { continue }
            guard let old = seen[d.id] else { seen[d.id] = sig; continue }
            if sig == old { settling[d.id] = nil; continue }
            if settling[d.id] == sig {
                // Stået stille siden sidste tjek → læs USB'en igen
                settling[d.id] = nil
                seen[d.id] = sig
                load(d)
            } else {
                settling[d.id] = sig
            }
        }
    }

    static var script: URL? { Bundle.main.url(forResource: "pioneer_usb", withExtension: "py") }
    static var settingsScript: URL? { Bundle.main.url(forResource: "pioneer_settings", withExtension: "py") }

    @Published var settings: [String: UsbSettings] = [:]

    func loadSettings(_ d: UsbDrive) {
        DispatchQueue.global(qos: .utility).async {
            guard let script = Self.settingsScript,
                  let data = try? self.run(["read", d.url.path], input: nil, script: script),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], obj["ok"] as? Bool == true else { return }
            let st = UsbSettings.decode(obj)
            DispatchQueue.main.async { self.settings[d.id] = st }
        }
    }

    /// changes: fil → felt → ny værdi. Gamle filer gemmes i PIONEER/MODULR-settings-backup.
    func writeSettings(_ d: UsbDrive, _ changes: [String: [String: Int]], done: String = "My Settings er gemt på USB'en – CDJ'en bruger dem, når du loader stikket.") {
        guard let script = Self.settingsScript else { message = "Indstillings-modulet mangler i appen – geninstallér MODULR"; return }
        let plan = changes.filter { !$0.value.isEmpty }
        guard !plan.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var text = done
            do {
                let input = try JSONSerialization.data(withJSONObject: plan)
                let data = try self.run(["write", d.url.path], input: input, script: script)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if obj?["ok"] as? Bool != true {
                    text = "⛔️ My Settings blev ikke ændret: \(obj?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "ukendt fejl")"
                }
            } catch {
                text = "⛔️ My Settings blev ikke ændret: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.message = text
                self.loadSettings(d)
            }
        }
    }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeNameKey, .volumeLocalizedFormatDescriptionKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        drives = vols.compactMap { v in
            let pdb = v.appendingPathComponent("PIONEER/rekordbox/export.pdb")
            guard FileManager.default.fileExists(atPath: pdb.path) else { return nil }
            let rv = try? v.resourceValues(forKeys: [.volumeNameKey, .volumeLocalizedFormatDescriptionKey])
            let name = rv?.volumeName ?? v.lastPathComponent
            return UsbDrive(url: v, name: name, format: rv?.volumeLocalizedFormatDescription ?? "")
        }
        for d in drives where contents[d.id] == nil { load(d) }
        let ids = Set(drives.map(\.id))
        seen = seen.filter { ids.contains($0.key) }
        settling = settling.filter { ids.contains($0.key) }
    }

    private func run(_ args: [String], input: Data?, script given: URL? = nil) throws -> Data {
        guard let script = given ?? Self.script else { throw UpdateError.message("USB-modulet mangler i appen – geninstallér MODULR") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path] + args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inp
        try p.run()
        if let input { inp.fileHandleForWriting.write(input) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    func load(_ d: UsbDrive) {
        loading.insert(d.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: UsbContents
            do {
                let data = try self.run(["read", d.url.path], input: nil)
                result = (try? JSONDecoder().decode(UsbContents.self, from: data))
                    ?? UsbContents(ok: false, error: String(data: data, encoding: .utf8), tracks: nil, nodes: nil, onelibrary: nil)
            } catch {
                result = UsbContents(ok: false, error: error.localizedDescription, tracks: nil, nodes: nil, onelibrary: nil)
            }
            let sig = self.signature(d)
            self.loadSettings(d)
            DispatchQueue.main.async {
                self.contents[d.id] = result
                self.loading.remove(d.id)
                self.revision += 1
                self.seen[d.id] = sig
                self.settling[d.id] = nil
            }
        }
    }

    // MARK: Ventende ændringer

    func newFolder(_ d: UsbDrive, name: String, parent: UsbPending.Parent) {
        pending[d.id, default: []].append(UsbPending(key: "f-\(UUID().uuidString.prefix(8))", kind: .folder, name: name, parent: parent, tracks: []))
    }

    @discardableResult
    func newPlaylist(_ d: UsbDrive, name: String, parent: UsbPending.Parent, tracks: [UUID] = []) -> String {
        let key = "p-\(UUID().uuidString.prefix(8))"
        pending[d.id, default: []].append(UsbPending(key: key, kind: .playlist, name: name, parent: parent, tracks: tracks))
        return key
    }

    /// Sange til en eksisterende USB-playliste (id) eller en ny (key).
    func add(_ tracks: [UUID], to d: UsbDrive, existing: Int? = nil, newKey: String? = nil) {
        var list = pending[d.id, default: []]
        if let key = newKey, let i = list.firstIndex(where: { $0.key == key }) {
            for t in tracks where !list[i].tracks.contains(t) { list[i].tracks.append(t) }
        } else if let pid = existing {
            if let i = list.firstIndex(where: { $0.kind == .addTo(pid) }) {
                for t in tracks where !list[i].tracks.contains(t) { list[i].tracks.append(t) }
            } else {
                list.append(UsbPending(key: "a-\(pid)", kind: .addTo(pid), name: "", parent: .root, tracks: tracks))
            }
        }
        pending[d.id] = list
    }

    func discard(_ d: UsbDrive) { pending[d.id] = [] }

    var pendingCount: Int { pending.values.reduce(0) { $0 + $1.count } }

    // MARK: Skriv

    func commit(_ d: UsbDrive, library: LibraryStore) {
        let ops = pending[d.id] ?? []
        guard !ops.isEmpty else { return }
        writing.insert(d.id)
        message = "Skriver til \(d.name) – kopierer sange og opdaterer rekordbox-databasen …"
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MODULR-usb-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let idx = library.snapshot()
            func tracks(_ ids: [UUID]) -> [[String: Any]] {
                ids.compactMap { idx.track($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
                    .map { library.usbTrack($0, tempDir: tmp) }
            }
            func parent(_ p: UsbPending.Parent) -> Any {
                switch p {
                case .root: return 0
                case .existing(let i): return i
                case .new(let k): return k
                }
            }
            var plan: [String: Any] = ["folders": [], "playlists": [], "add_to": []]
            plan["folders"] = ops.filter { $0.kind == .folder }.map { ["key": $0.key, "name": $0.name, "parent": parent($0.parent)] as [String: Any] }
            plan["playlists"] = ops.filter { $0.kind == .playlist }.map {
                ["key": $0.key, "name": $0.name, "parent": parent($0.parent), "tracks": tracks($0.tracks)] as [String: Any]
            }
            plan["add_to"] = ops.compactMap { op -> [String: Any]? in
                if case .addTo(let pid) = op.kind { return ["playlist": pid, "tracks": tracks(op.tracks)] }
                return nil
            }
            let text: String
            do {
                let input = try JSONSerialization.data(withJSONObject: plan)
                let data = try self.run(["write", d.url.path], input: input)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if obj?["ok"] as? Bool == true {
                    let n = (obj?["log"] as? [Any])?.count ?? 0
                    text = "✅ \(d.name) er opdateret – \(n) sange kopieret. Backup af den gamle database ligger i PIONEER/MODULR-backup-…"
                    DispatchQueue.main.async { self.pending[d.id] = [] }
                } else {
                    text = "⛔️ USB'en blev ikke ændret: \(obj?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "ukendt fejl")"
                }
            } catch {
                text = "⛔️ USB'en blev ikke ændret: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.writing.remove(d.id)
                self.message = text
                self.load(d)
            }
        }
    }

    // MARK: Ret i det der allerede ligger på USB'en (udføres med det samme – med backup og kontrol)

    @Published var editing: Set<String> = []

    func edit(_ d: UsbDrive, _ plan: [String: Any], done text: String) {
        guard !writing.contains(d.id), !editing.contains(d.id) else {
            message = "Vent – MODULR er i gang med \(d.name)."
            return
        }
        editing.insert(d.id)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            do {
                let input = try JSONSerialization.data(withJSONObject: plan)
                let data = try self.run(["edit", d.url.path], input: input)
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if obj?["ok"] as? Bool == true {
                    result = text
                } else {
                    result = "⛔️ USB'en blev ikke ændret: \(obj?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "ukendt fejl")"
                }
            } catch {
                result = "⛔️ USB'en blev ikke ændret: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.editing.remove(d.id)
                self.message = result
                self.load(d)
            }
        }
    }

    func removeFromPlaylist(_ d: UsbDrive, playlist: Int, tracks: [Int]) {
        edit(d, ["remove": [["playlist": playlist, "tracks": tracks]]],
             done: "\(tracks.count) sang\(tracks.count == 1 ? "" : "e") fjernet fra playlisten (de ligger stadig på USB'en).")
    }

    func addExisting(_ d: UsbDrive, playlist: Int, tracks: [Int]) {
        let have = Set(contents[d.id]?.nodes?.first { $0.id == playlist }?.tracks ?? [])
        let new = tracks.filter { !have.contains($0) }
        guard !new.isEmpty else { message = "Sangene ligger allerede i den playliste."; return }
        edit(d, ["add": [["playlist": playlist, "tracks": new]]], done: "\(new.count) sang\(new.count == 1 ? "" : "e") lagt i playlisten.")
    }

    func move(_ d: UsbDrive, from: Int, to: Int, tracks: [Int]) {
        guard from != to else { return }
        edit(d, ["remove": [["playlist": from, "tracks": tracks]], "add": [["playlist": to, "tracks": tracks]]],
             done: "\(tracks.count) sang\(tracks.count == 1 ? "" : "e") flyttet.")
    }

    func reorder(_ d: UsbDrive, playlist: Int, order: [Int]) {
        edit(d, ["order": [["playlist": playlist, "tracks": order]]], done: "Rækkefølgen er gemt på USB'en.")
    }

    /// Flyt MODULRs analysefiler derhen hvor CDJ'en selv kigger (beregnet ud fra filstien).
    func repairAnalysis(_ d: UsbDrive) {
        let n = contents[d.id]?.misplaced ?? 0
        edit(d, ["repair": true], done: "✅ \(n) sang\(n == 1 ? "" : "e") har nu waveform, grid og cues dér hvor CDJ'en kigger.")
    }

    func deleteTracks(_ d: UsbDrive, tracks: [Int]) {
        if let cur = PlayerModel.shared.track?.path, Set(tracks).contains(where: { id in
            contents[d.id]?.tracks?.first { $0.id == id }?.fileURL(root: d.url).path == cur
        }) {
            PlayerModel.shared.release(under: d.url)
        }
        edit(d, ["delete": tracks], done: "\(tracks.count) sang\(tracks.count == 1 ? "" : "e") slettet fra \(d.name).")
    }

    /// Alle almindelige playlister på USB'en med deres sti (til "Flyt til" / "Læg i").
    func playlistPaths(_ d: UsbDrive) -> [(id: Int, path: String)] {
        let nodes = contents[d.id]?.nodes ?? []
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ n: UsbNodeInfo) -> String {
            var parts = [n.name]
            var p = n.parent
            var guardN = 0
            while p != 0, let q = byID[p], guardN < 24 { parts.insert(q.name, at: 0); p = q.parent; guardN += 1 }
            return parts.joined(separator: " › ")
        }
        return nodes.filter { !$0.folder }.map { ($0.id, path($0)) }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Skub sikkert ud: spørger først hvis der er noget der ikke er skrevet, og slipper sange fra USB'en i afspilleren.
    func ejectSafely(_ d: UsbDrive) {
        if writing.contains(d.id) {
            message = "Vent – MODULR skriver stadig til \(d.name)."
            return
        }
        let waiting = pending[d.id]?.count ?? 0
        if waiting > 0 {
            Dialogs.shared.confirm("Skub \(d.name) ud?",
                                   message: "\(waiting) ændring\(waiting == 1 ? "" : "er") er ikke skrevet til USB'en endnu og går tabt.",
                                   icon: "eject.fill", button: "Skub ud alligevel", destructive: true) { [weak self] in
                self?.pending[d.id] = []
                self?.eject(d)
            }
        } else {
            eject(d)
        }
    }

    /// Send MODULRs nyeste analyse (waveform, grid, cues, phrases) til sange der allerede ligger på stikket.
    /// Kun sange der også er i biblioteket; rekordbox' egne analyser røres aldrig.
    func refreshFromLibrary(_ d: UsbDrive, tracks ids: [Int], library: LibraryStore) {
        let usbTracks = (contents[d.id]?.tracks ?? []).filter { ids.contains($0.id) }
        let pairs: [(Int, LibTrack)] = usbTracks.compactMap { u in
            let lib = u.playable(root: d.url)
            return library.index.track(lib.id) != nil ? (u.id, lib) : nil
        }
        guard !pairs.isEmpty else {
            message = "Sangen findes ikke i MODULRs bibliotek – importér den først (højreklik → Importér til biblioteket)."
            return
        }
        guard !writing.contains(d.id) else { return }
        writing.insert(d.id)
        message = "Opdaterer \(pairs.count) sang\(pairs.count == 1 ? "" : "e") på \(d.name) …"
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MODULR-usb-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let items: [[String: Any]] = pairs.map { ["usb_track_id": $0.0, "track": library.usbTrack($0.1, tempDir: tmp)] }
            let plan: [String: Any] = ["folders": [], "playlists": [], "add_to": [], "refresh": items]
            var text: String
            do {
                let data = try self.run(["write", d.url.path], input: try JSONSerialization.data(withJSONObject: plan))
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if obj?["ok"] as? Bool == true {
                    let n = ((obj?["log"] as? [String]) ?? []).filter { $0.hasPrefix("Opdateret") }.count
                    text = "✅ \(n) sang\(n == 1 ? "" : "e") har nu MODULRs nyeste waveform, grid og cues på \(d.name)."
                } else {
                    text = "⛔️ USB'en blev ikke ændret: \(obj?["error"] as? String ?? String(data: data, encoding: .utf8) ?? "ukendt fejl")"
                }
            } catch {
                text = "⛔️ USB'en blev ikke ændret: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.writing.remove(d.id)
                self.message = text
                self.load(d)
            }
        }
    }

    func eject(_ d: UsbDrive) {
        PlayerModel.shared.release(under: d.url)
        message = "Skubber \(d.name) ud …"
        let url = d.url
        DispatchQueue.global(qos: .userInitiated).async {
            var err: Error?
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) } catch { err = error }
            DispatchQueue.main.async {
                if let err {
                    self.message = "Kunne ikke skubbe \(d.name) ud: \(err.localizedDescription) – luk andre programmer der bruger USB'en (fx rekordbox) og prøv igen."
                } else {
                    self.message = "⏏︎ \(d.name) er skubbet ud – klar til CDJ'en."
                    self.contents[d.id] = nil
                    self.pending[d.id] = nil
                    self.refresh()
                }
            }
        }
    }
}
