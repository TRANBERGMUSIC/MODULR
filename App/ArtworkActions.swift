// MODULR – artwork fra én sang over på en anden: "Kopiér artwork" på den gamle sang → "Indsæt artwork" på WAV'en,
// eller "Hent artwork fra fil…" (en lydfil med cover, eller et billede). Coveret gemmes i Artwork-biblioteket under
// BEGGE sangenes navne – så når en bedre version uden cover kommer ind senere, får den det automatisk.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Indstillinger for artwork.
enum ArtworkPrefs {
    static let autoEmbedKey = "artwork.autoEmbed"

    /// Læg automatisk et kendt cover ind i filer der mangler et (WAV/AIFF/MP3), når de kommer ind i biblioteket.
    static var autoEmbed: Bool {
        get { UserDefaults.standard.object(forKey: autoEmbedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoEmbedKey) }
    }
}

/// Det kopierede cover (MODULRs egen udklipsholder – billedet lægges også på Macens, så det kan sættes ind andre steder).
struct CopiedArtwork {
    var data: Data
    var song: SongInfo?
    var name: String          // "Kunstner – Titel", vises i menuen
    var changeCount: Int      // Macens udklipsholder på det tidspunkt
}

extension LibraryStore {
    private static var copied: CopiedArtwork?

    static func songInfo(_ t: LibTrack) -> SongInfo? {
        SongInfo(artist: t.artist.isEmpty ? nil : t.artist, rawTitle: t.title)
    }

    static func displayName(_ t: LibTrack) -> String {
        t.artist.isEmpty ? t.title : "\(t.artist) – \(t.title)"
    }

    /// Coveret på en sang: MODULRs kopi, ellers det der ligger i filen.
    func artworkData(_ t: LibTrack) async -> Data? {
        if let u = artURL(t), let d = try? Data(contentsOf: u) { return d }
        return await ArtworkLibrary.extract(from: t.url)
    }

    // MARK: Kopiér / indsæt

    func copyArtwork(_ id: UUID) {
        guard let t = index.track(id) else { return }
        Task {
            guard let data = await artworkData(t) else {
                await MainActor.run { lastMessage = "\"\(t.title)\" har intet artwork at kopiere" }
                return
            }
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                if let img = NSImage(data: data) { pb.writeObjects([img]) }
                Self.copied = CopiedArtwork(data: data, song: Self.songInfo(t), name: Self.displayName(t), changeCount: pb.changeCount)
                lastMessage = "Artwork kopieret fra \"\(t.title)\" – højreklik på en sang → Indsæt artwork"
            }
            // Gem det også i biblioteket under sangens navn (så det findes igen senere)
            if let song = Self.songInfo(t) {
                ArtworkLibrary.shared.add(data, song: song, source: "Fra fil: \(t.url.lastPathComponent)", file: t.url)
            }
        }
    }

    /// Hvad der kan indsættes lige nu: MODULRs kopi, eller et billede du har kopieret et andet sted (Finder, browser …).
    var pastableArtwork: CopiedArtwork? {
        let pb = NSPasteboard.general
        if let c = Self.copied, c.changeCount == pb.changeCount { return c }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation {
            return CopiedArtwork(data: tiff, song: nil, name: "udklipsholderen", changeCount: pb.changeCount)
        }
        return nil
    }

    func pasteArtwork(to ids: [UUID]) {
        guard let c = pastableArtwork else {
            lastMessage = "Intet artwork kopieret – højreklik på en sang med cover → Kopiér artwork"
            return
        }
        setArtwork(c.data, sourceSong: c.song, sourceName: c.name, on: ids)
    }

    // MARK: Hent fra fil

    /// Vælg en lydfil (med cover) eller et billede og læg coveret på sangene.
    func pickArtworkFile(for ids: [UUID]) {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.image, .audio]
        p.message = "Vælg en sang med det cover du vil bruge – eller et billede"
        p.prompt = "Hent artwork"
        guard p.runModal() == .OK, let u = p.url else { return }
        artworkFromFile(u, to: ids)
    }

    func artworkFromFile(_ url: URL, to ids: [UUID]) {
        Task {
            let isAudio = ArtworkLibrary.audioExts.contains(url.pathExtension.lowercased())
            let data: Data? = isAudio ? await ArtworkLibrary.extract(from: url) : (try? Data(contentsOf: url))
            guard let data, NSImage(data: data) != nil else {
                await MainActor.run {
                    lastMessage = isAudio ? "\"\(url.lastPathComponent)\" har intet artwork" : "Billedet kunne ikke læses"
                }
                return
            }
            let song = isAudio ? ArtworkLibrary.song(for: url) : nil
            let name = song.map { ($0.artists.isEmpty ? "" : $0.artists.joined(separator: ", ") + " – ") + $0.title } ?? url.lastPathComponent
            if isAudio, let song {
                ArtworkLibrary.shared.add(data, song: song, source: "Fra fil: \(url.lastPathComponent)", file: url)
            }
            await MainActor.run { setArtwork(data, sourceSong: song, sourceName: name, on: ids) }
        }
    }

    // MARK: Læg på

    /// Lægger coveret på sangene: i MODULR, ind i filen (WAV/AIFF/MP3) og i Artwork-biblioteket under sangens navn
    /// og kildens navn. Bagefter får andre sange i biblioteket uden cover, der er samme sang, det også.
    func setArtwork(_ input: Data, sourceSong: SongInfo?, sourceName: String, on ids: [UUID]) {
        let targets = ids.compactMap { index.track($0) }
        guard !targets.isEmpty else { return }
        let all = index.tracks
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Et screenshot/foto i forkert format bliver til et kvadratisk cover, der passer
            let fitted = ArtworkImage.fitSquare(data: input)
            let data = fitted?.data ?? input
            var written = 0, onlyApp = 0, failed = 0
            var entries = [ArtworkEntry]()
            if let s = sourceSong, let e = ArtworkLibrary.shared.add(data, song: s, source: "Fra \(sourceName)") { entries.append(e) }
            for t in targets {
                let r = embed(data, in: t, source: "Fra \(sourceName)")
                switch r {
                case .written: written += 1
                case .appOnly: onlyApp += 1
                case .failed: failed += 1
                }
                if let s = Self.songInfo(t), let e = ArtworkLibrary.shared.add(data, song: s, source: "Fra \(sourceName)", file: t.url) {
                    entries.append(e)
                }
            }
            let more = fillMissing(using: entries, in: all, except: Set(ids))
            var parts = ["Artwork fra \(sourceName) lagt på \(written + onlyApp) sang\(written + onlyApp == 1 ? "" : "e")"]
            if fitted?.changed == true { parts.append("tilpasset til kvadrat") }
            if onlyApp > 0 { parts.append("\(onlyApp) kun i MODULR (FLAC/M4A kan ikke få cover i filen)") }
            if failed > 0 { parts.append("\(failed) fejlede") }
            if more > 0 { parts.append("+ \(more) andre versioner uden cover fik det også") }
            let msg = parts.joined(separator: " · ")
            DispatchQueue.main.async { self.lastMessage = msg }
        }
    }

    enum EmbedResult { case written, appOnly, failed }

    /// Coveret på én sang: MODULRs kopi (nyt filnavn, så visningen opdateres) og ind i selve filen.
    @discardableResult
    func embed(_ data: Data, in t: LibTrack, source: String) -> EmbedResult {
        guard let jpeg = ArtworkImage.libraryJPEG(data: data) else { return .failed }
        let name = "\(t.id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
        guard (try? jpeg.write(to: Self.artFolder.appendingPathComponent(name), options: .atomic)) != nil else { return .failed }
        let old = t.artFile
        update(t.id) { $0.artFile = name }
        if let old, old != name { try? FileManager.default.removeItem(at: Self.artFolder.appendingPathComponent(old)) }
        guard ArtworkLibrary.writableExts.contains(t.url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: t.path) else { return .appOnly }
        guard let cdj = ArtworkImage.cdjJPEG(data: jpeg) else { return .failed }
        do {
            try AudioTagger.setFrames([ID3.pictureFrame(jpeg: cdj)], on: t.url)
            return .written
        } catch {
            return .failed
        }
    }

    /// Andre sange i biblioteket uden cover, som coveret passer til (samme sang, fx en bedre version) – får det også.
    func fillMissing(using entries: [ArtworkEntry], in tracks: [LibTrack], except: Set<UUID> = []) -> Int {
        guard !entries.isEmpty else { return 0 }
        var n = 0
        for t in tracks where t.artFile == nil && !except.contains(t.id) {
            guard let song = Self.songInfo(t), let e = ArtworkMatcher.best(for: song, in: entries),
                  let d = ArtworkLibrary.shared.imageData(e) else { continue }
            if embed(d, in: t, source: e.source) != .failed {
                ArtworkLibrary.shared.noteApplied(e, to: t.url)
                n += 1
            }
        }
        return n
    }
}

extension LibraryStore {
    /// Billeder trukket ind på en sang (fra Finder, skrivebordet, en browser …) bliver sangens artwork.
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tif", "tiff", "bmp"]

    /// Deler et træk op: billeder → artwork på `ids`, resten importeres som normalt. Returnerer de øvrige filer.
    func takeArtworkImages(_ urls: [URL], for ids: [UUID]) -> [URL] {
        let images = urls.filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
        if let img = images.first, !ids.isEmpty, let data = try? Data(contentsOf: img) {
            setArtwork(data, sourceSong: nil, sourceName: img.lastPathComponent, on: ids)
        }
        return urls.filter { !Self.imageExts.contains($0.pathExtension.lowercased()) }
    }
}
