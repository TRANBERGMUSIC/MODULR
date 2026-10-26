// MODULR – USB: finder USB-stik med rekordbox-bibliotek, viser deres playlister og skriver
// MODULRs mapper, playlister og sange ind (via usb/pioneer_usb.py, som følger med appen).

import Foundation
import SwiftUI
import AppKit

struct UsbDrive: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
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

final class UsbStore: ObservableObject {
    static let shared = UsbStore()

    @Published var drives: [UsbDrive] = []
    @Published var contents: [String: UsbContents] = [:]
    @Published var loading: Set<String> = []
    @Published var pending: [String: [UsbPending]] = [:]
    @Published var writing: Set<String> = []
    @Published var message: String?

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    static var script: URL? { Bundle.main.url(forResource: "pioneer_usb", withExtension: "py") }

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeNameKey]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        drives = vols.compactMap { v in
            let pdb = v.appendingPathComponent("PIONEER/rekordbox/export.pdb")
            guard FileManager.default.fileExists(atPath: pdb.path) else { return nil }
            let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
            return UsbDrive(url: v, name: name)
        }
        for d in drives where contents[d.id] == nil { load(d) }
    }

    private func run(_ args: [String], input: Data?) throws -> Data {
        guard let script = Self.script else { throw UpdateError.message("USB-modulet mangler i appen – geninstallér MODULR") }
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
            DispatchQueue.main.async {
                self.contents[d.id] = result
                self.loading.remove(d.id)
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

    func eject(_ d: UsbDrive) {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: d.url)
            message = "\(d.name) er skubbet ud – klar til CDJ'en."
        } catch {
            message = "Kunne ikke skubbe \(d.name) ud: \(error.localizedDescription)"
        }
    }
}
