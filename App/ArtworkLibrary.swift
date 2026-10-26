// MODULR – Artwork-bibliotek: samler covers fra dine filer (også de dårlige versioner), gemmer dem,
// lægger dem automatisk på filer der mangler (fx WAV) og flytter dem med over på bedre versioner.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class ArtworkLibrary: ObservableObject {
    static let shared = ArtworkLibrary()

    @Published private(set) var entries: [ArtworkEntry] = []

    private let lock = NSLock()
    private var store: [ArtworkEntry] = []

    static var folder: URL {
        let d = AppFolders.support.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var indexFile: URL { folder.appendingPathComponent("index.json") }

    static let writableExts: Set<String> = ["wav", "aif", "aiff", "mp3"]
    static let audioExts: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "aac", "flac", "alac"]

    init() {
        if let d = try? Data(contentsOf: Self.indexFile),
           let list = try? JSONDecoder().decode([ArtworkEntry].self, from: d) {
            store = list.filter { FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent($0.imageFile).path) }
        }
        entries = store.sorted { $0.addedAt > $1.addedAt }
    }

    private func publish() {
        let snapshot = store.sorted { $0.addedAt > $1.addedAt }
        if let d = try? JSONEncoder().encode(store) { try? d.write(to: Self.indexFile, options: .atomic) }
        DispatchQueue.main.async { self.entries = snapshot }
    }

    func imageURL(_ e: ArtworkEntry) -> URL { Self.folder.appendingPathComponent(e.imageFile) }

    func imageData(_ e: ArtworkEntry) -> Data? { try? Data(contentsOf: imageURL(e)) }

    // MARK: Tilføj / find / udskift / slet

    /// Gemmer et cover for en sang. Findes sangen allerede, beholdes det STØRSTE billede.
    @discardableResult
    func add(_ data: Data, song: SongInfo, source: String, file: URL? = nil) -> ArtworkEntry? {
        guard let jpeg = ArtworkImage.libraryJPEG(data: data), let (w, h) = ArtworkImage.pixelSize(jpeg) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let i = store.firstIndex(where: { ArtworkMatcher.sameSong($0, song) }) {
            if w * h > store[i].pixels {
                try? jpeg.write(to: Self.folder.appendingPathComponent(store[i].imageFile), options: .atomic)
                store[i].width = w
                store[i].height = h
                store[i].source = source
            }
            if let f = file?.path, !store[i].files.contains(f) { store[i].files.append(f) }
            if store[i].artists.isEmpty && !song.artists.isEmpty { store[i].artists = song.artists }
            let e = store[i]
            publish()
            return e
        }
        let id = UUID()
        let name = "\(id.uuidString).jpg"
        do { try jpeg.write(to: Self.folder.appendingPathComponent(name), options: .atomic) } catch { return nil }
        let e = ArtworkEntry(id: id, artists: song.artists, title: song.title, version: song.version, imageFile: name,
                             width: w, height: h, source: source, addedAt: Date(), files: file.map { [$0.path] } ?? [])
        store.append(e)
        publish()
        return e
    }

    func find(for song: SongInfo) -> ArtworkEntry? {
        lock.lock()
        defer { lock.unlock() }
        return ArtworkMatcher.best(for: song, in: store)
    }

    func noteApplied(_ e: ArtworkEntry, to file: URL) {
        lock.lock()
        if let i = store.firstIndex(where: { $0.id == e.id }), !store[i].files.contains(file.path) {
            store[i].files.append(file.path)
        }
        lock.unlock()
        publish()
    }

    /// Udskift coveret med et bedre billede og opdatér alle filer, det er lagt på.
    func replace(_ e: ArtworkEntry, with imageURL: URL) -> (updated: Int, failed: Int) {
        guard let raw = try? Data(contentsOf: imageURL), let jpeg = ArtworkImage.libraryJPEG(data: raw),
              let (w, h) = ArtworkImage.pixelSize(jpeg), let cdj = ArtworkImage.cdjJPEG(data: jpeg) else { return (0, 0) }
        lock.lock()
        guard let i = store.firstIndex(where: { $0.id == e.id }) else { lock.unlock(); return (0, 0) }
        try? jpeg.write(to: Self.folder.appendingPathComponent(store[i].imageFile), options: .atomic)
        store[i].width = w
        store[i].height = h
        store[i].source = "Manuelt: \(imageURL.lastPathComponent)"
        let files = store[i].files
        lock.unlock()
        publish()
        var ok = 0, bad = 0
        for path in files {
            let u = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path), Self.writableExts.contains(u.pathExtension.lowercased()) else { continue }
            do { try AudioTagger.setFrames([ID3.pictureFrame(jpeg: cdj)], on: u); ok += 1 } catch { bad += 1 }
        }
        return (ok, bad)
    }

    func delete(_ e: ArtworkEntry) {
        lock.lock()
        store.removeAll { $0.id == e.id }
        lock.unlock()
        try? FileManager.default.removeItem(at: imageURL(e))
        publish()
    }

    /// Ret sang-oplysningerne på et cover.
    func update(_ e: ArtworkEntry, song: SongInfo) {
        lock.lock()
        if let i = store.firstIndex(where: { $0.id == e.id }) {
            store[i].artists = song.artists
            store[i].title = song.title
            store[i].version = song.version
        }
        lock.unlock()
        publish()
    }

    // MARK: Læs fra filer

    static func song(for url: URL) -> SongInfo? {
        let tags = Analyzer.readAllTags(url: url)
        let fallback = Analyzer.readTags(url: url)
        return SongInfo(artist: tags["artist"] ?? fallback.artist, rawTitle: tags["title"] ?? fallback.title)
    }

    /// Indlejret cover i en fil: ID3 (MP3/WAV/AIFF) eller hvad AVFoundation kan læse (M4A, FLAC …).
    static func extract(from url: URL) async -> Data? {
        if let tag = try? AudioTagger.readTag(of: url), let parsed = ID3.parse(tag),
           let apic = parsed.frames.first(where: { $0.id == "APIC" }), let d = ID3.pictureData(apic), !d.isEmpty {
            return d
        }
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.commonMetadata)) ?? []
        if let all = try? await asset.load(.metadata) { items += all }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let d = try? await item.load(.dataValue), !d.isEmpty { return d }
        }
        return nil
    }

    // MARK: iTunes (offentligt søge-API) som reserve

    struct ITunesResult: Decodable {
        struct Item: Decodable {
            let trackName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
        let results: [Item]
    }

    static func fetchFromITunes(_ song: SongInfo) async -> Data? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        let term = (song.artists + [song.title]).joined(separator: " ")
        c.queryItems = [
            URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"), URLQueryItem(name: "country", value: "DK"),
        ]
        guard let (data, http) = try? await HTTP.shared.get(c.url!), http.statusCode == 200,
              let r = try? JSONDecoder().decode(ITunesResult.self, from: data) else { return nil }
        for item in r.results {
            guard let name = item.trackName, let art = item.artworkUrl100 else { continue }
            let found = SongInfo(artist: item.artistName, rawTitle: name)
            let probe = ArtworkEntry(id: UUID(), artists: found?.artists ?? [], title: found?.title ?? name,
                                     version: found?.version, imageFile: "", width: 0, height: 0, source: "",
                                     addedAt: Date(), files: [])
            guard ArtworkMatcher.score(probe, for: song) > 0 else { continue }
            let big = art.replacingOccurrences(of: "100x100bb", with: "1400x1400bb")
            if let u = URL(string: big), let (img, resp) = try? await HTTP.shared.get(u), resp.statusCode == 200 {
                return img
            }
        }
        return nil
    }

    /// Lægger det bedste kendte cover på en fil, der mangler et. Bruges også af "Find bedre version".
    func applyBest(to url: URL, song: SongInfo?, fallbackData: Data?, useITunes: Bool) async -> String {
        guard Self.writableExts.contains(url.pathExtension.lowercased()) else {
            return "\(url.pathExtension.uppercased()) understøttes ikke til artwork (brug WAV, AIFF eller MP3)"
        }
        var entry: ArtworkEntry?
        if let fb = fallbackData, let song { entry = add(fb, song: song, source: "Fra den gamle version") }
        if entry == nil, let song { entry = find(for: song) }
        if entry == nil, useITunes, let song, let data = await Self.fetchFromITunes(song) {
            entry = add(data, song: song, source: "iTunes")
        }
        guard let e = entry, let data = imageData(e), let cdj = ArtworkImage.cdjJPEG(data: data) else {
            return "Intet artwork fundet"
        }
        do {
            try AudioTagger.setFrames([ID3.pictureFrame(jpeg: cdj)], on: url)
            noteApplied(e, to: url)
            return "Artwork tilføjet (\(e.source))"
        } catch {
            return "Kunne ikke skrive artwork: \(error.localizedDescription)"
        }
    }
}

// MARK: - Skærme

enum ArtworkMode: String, CaseIterable, Identifiable {
    case covers = "Covers"
    case manual = "Manuelt"
    var id: String { rawValue }
}

struct ArtworkToolView: View {
    @State private var mode: ArtworkMode = .covers

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ModSegmented(selection: $mode, options: ArtworkMode.allCases.map { ($0, $0.rawValue) })
                    .frame(width: 440)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            switch mode {
            case .covers: ArtworkLibraryView()
            case .manual: ManualArtworkView()
            }
        }
    }
}

final class URLCollector {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

struct ArtworkLibraryView: View {
    @EnvironmentObject var library: ArtworkLibrary
    @State private var search = ""
    @State private var message: String?

    var filtered: [ArtworkEntry] {
        guard !search.isEmpty else { return library.entries }
        return library.entries.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Søg i covers", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                Text("\(library.entries.count) covers").foregroundStyle(.secondary)
                Spacer()
                if let m = message { Text(m).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
            if library.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundColor(.ember)
                    Text("Biblioteket er tomt").font(.title3)
                    Text("Covers samles automatisk her, når du sætter sange ind i biblioteket.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 18) {
                        ForEach(filtered) { e in
                            ArtworkTile(entry: e, message: $message)
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
}

struct ArtworkTile: View {
    @EnvironmentObject var library: ArtworkLibrary
    let entry: ArtworkEntry
    @Binding var message: String?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.graphite)
                if let img = NSImage(contentsOf: library.imageURL(entry)) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
                if targeted {
                    RoundedRectangle(cornerRadius: 8).fill(Color.ember.opacity(0.35))
                    Text("Slip for at udskifte").font(.caption.bold())
                }
            }
            .frame(width: 170, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { replace(with: url) } }
                }
                return true
            }
            Text(entry.displayName)
                .font(.caption)
                .lineLimit(2)
            Text("\(entry.width)×\(entry.height) · \(entry.files.count) fil\(entry.files.count == 1 ? "" : "er")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 170)
        .modMenu(title: entry.displayName, subtitle: "\(entry.width)×\(entry.height)") {
            [
                .action("Udskift med bedre billede…", icon: "photo.badge.arrow.down") { pickReplacement() },
                .action("Vis i Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([library.imageURL(entry)]) },
                .divider,
                .action("Slet fra biblioteket", icon: "trash", destructive: true) {
                    Dialogs.shared.confirm("Slet coveret?", message: "Billedet fjernes fra Artwork-biblioteket. Filerne der allerede har det, beholder det.",
                                           icon: "trash.fill", button: "Slet", destructive: true) { library.delete(entry) }
                },
            ]
        }
        .help("\(entry.source)\nTræk et billede herover eller højreklik for at udskifte")
    }

    func pickReplacement() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { replace(with: u) }
    }

    func replace(with url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = library.replace(entry, with: url)
            DispatchQueue.main.async {
                message = r.failed > 0 ? "Udskiftet – \(r.updated) filer opdateret, \(r.failed) fejlede"
                                       : "Udskiftet – \(r.updated) filer opdateret"
            }
        }
    }
}
