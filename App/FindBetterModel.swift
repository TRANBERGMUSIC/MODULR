// MODULR – "Find bedre version": hele forløbet fra uploadet fil til verificeret, bedre fil.

import Foundation
import SwiftUI
import AppKit

enum FBStep: Int, CaseIterable, Identifiable {
    case identifying, analyzing, searching, candidates, gate, downloading, verifying

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .identifying: return "Identificerer"
        case .analyzing: return "Analyserer kvalitet"
        case .searching: return "Søger"
        case .candidates: return "Kandidater"
        case .gate: return "Gate"
        case .downloading: return "Henter"
        case .verifying: return "Verificerer"
        }
    }
}

struct SourceState: Identifiable, Equatable {
    var id: SourceKind { kind }
    var kind: SourceKind
    var text: String
    var ok: Bool?          // nil = i gang
}

struct FBResult: Equatable {
    var savedFile: URL
    var provenanceFile: URL
    var summary: String
}

struct PurchaseLink: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var url: URL
}

final class FindBetterModel: ObservableObject {
    @Published var file: URL?
    @Published var step: FBStep?
    @Published var busy = false
    @Published var message: String?
    @Published var errorText: String?

    @Published var original: QualityReport?
    @Published var identityOptions: [IdentityOption] = []
    @Published var needsIdentityChoice = false
    @Published var identity: TrackIdentity?
    @Published var identityNote: String?

    @Published var sources: [SourceState] = []
    @Published var candidates: [Candidate] = []
    @Published var hiddenOtherVersions = 0
    @Published var purchaseLinks: [PurchaseLink] = []
    @Published var rejections: [String] = []

    @Published var gateTicket: GateSessionTicket?
    @Published var pendingGateCandidate: Candidate?
    @Published var result: FBResult?
    @Published var nothingBetter = false

    let settings: FBSettings
    private var originalFP: Fingerprint?
    private var artistLinks = ArtistLinks()
    private var activeCandidate: Candidate?

    let library: ArtworkLibrary
    @Published var watchingDownloads = false
    private var watcher: DownloadsWatcher?

    init(settings: FBSettings, library: ArtworkLibrary) {
        self.settings = settings
        self.library = library
    }

    func reset() {
        file = nil; step = nil; busy = false; message = nil; errorText = nil
        original = nil; identityOptions = []; needsIdentityChoice = false; identity = nil; identityNote = nil
        sources = []; candidates = []; hiddenOtherVersions = 0; purchaseLinks = []; rejections = []
        gateTicket = nil; pendingGateCandidate = nil; result = nil; nothingBetter = false
        originalFP = nil; artistLinks = ArtistLinks(); activeCandidate = nil
    }

    @MainActor
    private func set(_ s: FBStep, _ msg: String? = nil) {
        step = s
        message = msg
    }

    // MARK: 1–2: identifikation og kvalitet

    func start(file url: URL) {
        reset()
        file = url
        busy = true
        Task { await run(url) }
    }

    private func run(_ url: URL) async {
        await set(.identifying, "Beregner fingerprint …")
        let keys = settings.keys
        let identifier = Identifier(keys: keys)
        var fp: Fingerprint?
        do {
            fp = try await Task.detached { try Fingerprinter.fingerprint(of: url) }.value
        } catch {
            await MainActor.run { self.identityNote = error.localizedDescription }
        }
        let duration = fp?.duration ?? Analyzer.duration(url: url) ?? 0
        let tagOption = Identifier.fromTags(url: url, duration: duration)

        var options = [IdentityOption]()
        var notes = [String]()
        if let fp {
            if keys.acoustID.isEmpty { notes.append("AcoustID ikke konfigureret") }
            do { if let o = try await identifier.acoustID(fp, hint: tagOption?.identity) { options.append(o) } }
            catch { notes.append(error.localizedDescription) }
        }
        if options.isEmpty && (!keys.audd.isEmpty || settings.acrConfigured) {
            if let snippet = try? Analyzer.writeSnippet(from: url) {
                defer { try? FileManager.default.removeItem(at: snippet) }
                do { if let o = try await identifier.acrCloud(snippet: snippet, duration: duration) { options.append(o) } }
                catch { notes.append(error.localizedDescription) }
                if options.isEmpty {
                    do { if let o = try await identifier.audd(snippet: snippet, duration: duration) { options.append(o) } }
                    catch { notes.append(error.localizedDescription) }
                }
            }
        }
        if let t = tagOption { options.append(t) }

        // Fingerprint og tags uenige → vis begge og lad brugeren vælge
        let fpOption = options.first { $0.fromFingerprint }
        var disagree = false
        if let a = fpOption?.identity, let b = tagOption?.identity {
            disagree = TextMatch.similarity(a.title, b.title) < 0.9 ||
                TextMatch.artistSimilarity(a.artists, b.artists) < 0.9 ||
                TextMatch.normalizeVersion(a.version) != TextMatch.normalizeVersion(b.version)
        }

        if fpOption == nil {
            notes.append("Sangen er ikke genkendt ud fra lyden – kun tags/filnavn. Tjek at den er rigtig.")
        }
        let finalFP = fp
        let finalOptions = options
        let noteText = notes.isEmpty ? nil : notes.joined(separator: " · ")
        await MainActor.run {
            self.originalFP = finalFP
            self.identityOptions = finalOptions
            self.identityNote = noteText
        }

        // Kvalitet
        await set(.analyzing, "Måler den reelle kvalitet …")
        do {
            let (report, _) = try await Task.detached { try Analyzer.quality(url: url) }.value
            await MainActor.run { self.original = report }
            LibraryStore.shared.importFiles([url])
        } catch {
            await fail("Kunne ikke analysere filen: \(error.localizedDescription)")
            return
        }

        if let fpOption, !disagree {
            await MainActor.run { self.identity = fpOption.identity }
            await search()
        } else if finalOptions.isEmpty {
            await MainActor.run {
                self.identity = TrackIdentity(title: url.deletingPathExtension().lastPathComponent, artists: [], duration: duration)
                self.needsIdentityChoice = true
                self.busy = false
            }
        } else {
            let preselected = (fpOption ?? finalOptions[0]).identity
            await MainActor.run {
                self.needsIdentityChoice = true
                self.identity = preselected
                self.busy = false
            }
        }
    }

    /// Brugeren har valgt/rettet identiteten.
    func confirmIdentity(_ id: TrackIdentity) {
        identity = id
        needsIdentityChoice = false
        busy = true
        Task { await search() }
    }

    // MARK: 3–4: søgning og kandidater

    private func search() async {
        guard let identity = await MainActor.run(body: { self.identity }) else { return }
        await set(.searching, "Søger i officielle kilder …")
        let s = settings
        let keys = s.keys
        let query = "\(identity.artists.joined(separator: " ")) \(identity.title)"

        // Kunstnerens egne links (MusicBrainz) – bruges til at godkende kunstnerens domæner
        let links = await Identifier(keys: keys).artistLinks(recordingID: identity.musicBrainzID)
        await MainActor.run { self.artistLinks = links }

        var raws = [RawCandidate]()
        var states = [SourceState]()
        var domains = links.domains

        if let cached = SearchCache.load(identity.cacheKey) {
            raws = cached.candidates
            domains = Array(Set(domains + cached.artistDomains))
            states.append(SourceState(kind: .soundcloud, text: "Fra cache (under 24 t gammel)", ok: true))
        } else {
            await MainActor.run {
                self.sources = SourceKind.allCases.filter { $0 != .artistSite && $0 != .gate }.map {
                    SourceState(kind: $0, text: "Søger …", ok: nil)
                }
            }
            // SoundCloud
            if s.useSoundCloud {
                if s.soundCloudConfigured {
                    do {
                        let api = SoundCloudAPI(clientID: keys.soundCloudClientID, clientSecret: keys.soundCloudClientSecret)
                        let tracks = try await api.search(query)
                        let found = tracks.flatMap(CandidateBuilder.fromSoundCloud)
                        raws += found.filter { s.useGates || $0.kind != .gate }
                        states.append(SourceState(kind: .soundcloud, text: "\(tracks.count) spor gennemset", ok: true))
                    } catch {
                        states.append(SourceState(kind: .soundcloud, text: error.localizedDescription, ok: false))
                    }
                } else {
                    states.append(SourceState(kind: .soundcloud, text: "SoundCloud ikke konfigureret", ok: false))
                }
            } else {
                states.append(SourceState(kind: .soundcloud, text: "Slået fra", ok: false))
            }
            let soFar = states
            await MainActor.run { self.sources = soFar }
            // Bandcamp
            if s.useBandcamp {
                do {
                    let found = try await BandcampSearch.search(query, identity: identity)
                    raws += found
                    states.append(SourceState(kind: .bandcamp, text: "\(found.count) mulige spor", ok: true))
                } catch {
                    states.append(SourceState(kind: .bandcamp, text: error.localizedDescription, ok: false))
                }
            } else {
                states.append(SourceState(kind: .bandcamp, text: "Slået fra", ok: false))
            }
            // MusicBrainz "download for free"
            for u in links.freeDownloadPages {
                raws.append(RawCandidate(source: .artistSite, kind: .artistPage, title: identity.title + (identity.version.map { " (\($0))" } ?? ""),
                                         artist: identity.artists.first ?? "", duration: nil, isrc: identity.isrc,
                                         pageURL: u.absoluteString, downloadURL: nil, downloadable: false,
                                         format: nil, license: nil, price: nil))
            }
            // Websøgning
            if s.useWebSearch {
                do {
                    let found = try await WebSearch.search(identity, key: keys.brave, artistDomains: domains)
                    raws += found.filter { s.useGates || $0.kind != .gate }
                    states.append(SourceState(kind: .webSearch, text: "\(found.count) resultater fra tilladte domæner", ok: true))
                } catch {
                    states.append(SourceState(kind: .webSearch, text: error.localizedDescription, ok: false))
                }
            } else {
                states.append(SourceState(kind: .webSearch, text: "Slået fra", ok: false))
            }
            SearchCache.save(identity.cacheKey, candidates: raws, artistDomains: domains)
        }

        // Godkend (også cachede) via politikken og match præcis sangen
        let approved = raws.compactMap { CandidateBuilder.approve($0, identity: identity, artistDomains: domains) }
        let downloadable = approved.filter { $0.raw.kind != .purchaseOnly }
        let shown = CandidateBuilder.filter(downloadable, showOtherVersions: s.showOtherVersions)
        let hidden = downloadable.filter { $0.match.isOtherVersion }.count
        var buy = approved.filter { $0.raw.kind == .purchaseOnly && $0.match.isMatch }.compactMap { c -> PurchaseLink? in
            guard let u = URL(string: c.raw.pageURL) else { return nil }
            let label = c.raw.source == .bandcamp ? "Bandcamp" : (c.raw.price ?? "Køb")
            return PurchaseLink(title: label + (c.raw.price.map { " (\($0))" } ?? ""), url: u)
        }
        if let beatport = StoreSearch.beatportURL(query) { buy.append(PurchaseLink(title: "Søg på Beatport", url: beatport)) }

        let finalDomains = domains
        let finalStates = states
        let finalBuy = buy
        let hideCount = s.showOtherVersions ? 0 : hidden
        await MainActor.run {
            self.artistLinks.domains = finalDomains
            self.sources = finalStates
            self.candidates = shown
            self.hiddenOtherVersions = hideCount
            self.purchaseLinks = finalBuy
            self.step = .candidates
            self.message = shown.isEmpty ? nil : "Vælg en kandidat. Alle tjekkes med fingerprint efter download."
            self.nothingBetter = shown.isEmpty
            self.busy = false
        }
    }

    // MARK: 5: download og verifikation

    func choose(_ c: Candidate) {
        rejections.removeAll()
        activeCandidate = c
        if let dl = c.download {
            busy = true
            step = .downloading
            message = "Henter fra SoundCloud …"
            let keys = settings.keys
            Task {
                do {
                    let api = SoundCloudAPI(clientID: keys.soundCloudClientID, clientSecret: keys.soundCloudClientSecret)
                    let file = try await api.download(dl)
                    await verify(files: [file], approved: dl, candidate: c, pageTitle: nil)
                } catch {
                    await MainActor.run {
                        self.busy = false
                        self.step = .candidates
                        self.errorText = error.localizedDescription
                    }
                }
            }
        } else if let page = c.page {
            if settings.askBeforeGate {
                pendingGateCandidate = c
            } else {
                openGate(page)
            }
        }
    }

    func openGate(_ page: ApprovedPage) {
        pendingGateCandidate = nil
        step = .gate
        let ticket = SourcePolicy.startSession(for: page)
        if settings.useSystemBrowser {
            // Din egen browser (Safari/Chrome): her virker "Log ind med Google", og du er allerede logget ind.
            message = "Gaten er åbnet i din browser. Gennemfør trinene der – MODULR fanger filen i Overførsler af sig selv."
            watchingDownloads = true
            let w = DownloadsWatcher { [weak self] file, source in
                guard let self else { return }
                self.watchingDownloads = false
                self.watcher = nil
                self.browserDownloaded(file: file, sourceURL: source, ticket: ticket, pageTitle: nil)
            } onTimeout: { [weak self] in
                self?.watchingDownloads = false
                self?.watcher = nil
                self?.step = .candidates
                self?.message = "Ingen ny fil i Overførsler efter 20 minutter – prøv igen."
            }
            watcher = w
            w.start()
            NSWorkspace.shared.open(page.url)
        } else {
            message = "Gennemfør selv trinene på siden. MODULR klikker ikke og udfylder intet for dig."
            gateTicket = ticket
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        watchingDownloads = false
        if step == .gate { step = .candidates; message = nil }
    }

    /// Kaldes af gate-browseren, når en download er færdig.
    func browserDownloaded(file: URL, sourceURL: URL?, ticket: GateSessionTicket, pageTitle: String?) {
        gateTicket = nil
        guard let approved = SourcePolicy.approveBrowserDownload(fileSourceURL: sourceURL, ticket: ticket) else {
            try? FileManager.default.removeItem(at: file)
            errorText = "Filen kom fra en kilde MODULR ikke må hente fra, og er slettet."
            step = .candidates
            return
        }
        busy = true
        let cand = activeCandidate
        Task {
            let files = await Self.expandArchive(file)
            await verify(files: files, approved: approved, candidate: cand, pageTitle: pageTitle)
        }
    }

    func gateClosed() {
        gateTicket = nil
        if step == .gate { step = .candidates; message = nil }
    }

    /// Bandcamp leverer nogle gange en zip – pak ud og find lydfilerne.
    static func expandArchive(_ file: URL) async -> [URL] {
        guard file.pathExtension.lowercased() == "zip" else { return [file] }
        let dir = file.deletingLastPathComponent().appendingPathComponent("unzipped")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, dir.path]
        try? p.run()
        p.waitUntilExit()
        let exts: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "alac"]
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out = [URL]()
        while let f = en?.nextObject() as? URL {
            if exts.contains(f.pathExtension.lowercased()) { out.append(f) }
        }
        return out
    }

    private func verify(files: [URL], approved: ApprovedDownload, candidate: Candidate?, pageTitle: String?) async {
        await set(.verifying, "Tjekker at det er præcis samme sang, og at kvaliteten er bedre …")
        guard let originalFP = await MainActor.run(body: { self.originalFP }),
              let old = await MainActor.run(body: { self.original }),
              let source = await MainActor.run(body: { self.file }) else {
            await fail("Mangler fingerprint af din fil – kan ikke verificere. (Er fpcalc installeret?)")
            return
        }
        let rule = settings.rule
        var reasons = [String]()
        for f in files {
            do {
                let newFP = try await Task.detached { try Fingerprinter.fingerprint(of: f) }.value
                let (verdict, cmp) = Fingerprinter.verdict(originalFP, newFP)
                guard verdict == .same else {
                    switch verdict {
                    case .otherVersion(let m), .different(let m): reasons.append("\(f.lastPathComponent): \(m)")
                    case .same: break
                    }
                    try? FileManager.default.removeItem(at: f)
                    continue
                }
                let (newQ, _) = try await Task.detached { try Analyzer.quality(url: f) }.value
                let (better, why) = Quality.isBetter(newQ, than: old, rule: rule)
                guard better else {
                    reasons.append("\(f.lastPathComponent): \(why)")
                    try? FileManager.default.removeItem(at: f)
                    continue
                }
                let saved = try await save(f, next: source, old: old, new: newQ, comparison: cmp,
                                           approved: approved, candidate: candidate, pageTitle: pageTitle)
                await MainActor.run {
                    self.result = saved
                    self.busy = false
                    self.message = nil
                    self.step = .verifying
                }
                return
            } catch {
                reasons.append("\(f.lastPathComponent): \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: f)
            }
        }
        let finalReasons = reasons.isEmpty ? ["Ingen lydfil i downloaden"] : reasons
        await MainActor.run {
            self.rejections = finalReasons
            self.busy = false
            self.step = .candidates
            self.message = "Den hentede fil blev afvist og slettet. Prøv en anden kandidat."
        }
    }

    private func save(_ f: URL, next original: URL, old: QualityReport, new: QualityReport, comparison: FingerprintComparison,
                      approved: ApprovedDownload, candidate: Candidate?, pageTitle: String?) async throws -> FBResult {
        let dir = original.deletingLastPathComponent()
        let base = original.deletingPathExtension().lastPathComponent
        let shortLabel = new.tierKbps >= 9999 ? new.format.codec : "\(new.tierKbps)"
        var dest = dir.appendingPathComponent("\(base) (MODULR \(shortLabel)).\(f.pathExtension.lowercased())")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (MODULR \(shortLabel) \(n)).\(f.pathExtension.lowercased())")
            n += 1
        }
        try FileManager.default.moveItem(at: f, to: dest)

        // Tags: kopiér titel/kunstner/album fra din fil hvor den nye mangler dem (MP3/WAV/AIFF)
        var tagNote = "Tags uændret"
        let oldTags = Analyzer.readAllTags(url: original)
        let newTags = Analyzer.readAllTags(url: dest)
        var frames = [ID3.Frame]()
        for (key, frame) in [("title", "TIT2"), ("artist", "TPE1"), ("album", "TALB"), ("genre", "TCON"), ("year", "TYER")] {
            if (newTags[key] ?? "").isEmpty, let v = oldTags[key], !v.isEmpty { frames.append(ID3.textFrame(frame, v)) }
        }
        if !frames.isEmpty {
            do {
                try AudioTagger.setFrames(frames, on: dest)
                tagNote = "Kopierede tags fra din fil: \(frames.map(\.id).joined(separator: ", "))"
            } catch {
                tagNote = "Tags kunne ikke kopieres (\(error.localizedDescription))"
            }
        }

        // Artwork: flyt coveret fra din gamle version med over (eller find det i biblioteket/iTunes)
        var artNote = "Artwork: den nye fil havde allerede et cover"
        if await ArtworkLibrary.extract(from: dest) == nil {
            let oldArt = await ArtworkLibrary.extract(from: original)
            let id0 = await MainActor.run { self.identity }
            let song = id0.map { SongInfo(artists: $0.artists, title: $0.title, version: $0.version) } ?? ArtworkLibrary.song(for: original)
            let r = await library.applyBest(to: dest, song: song, fallbackData: oldArt, useITunes: true)
            artNote = "Artwork: \(r)"
        } else if let data = await ArtworkLibrary.extract(from: dest), let song = ArtworkLibrary.song(for: dest) {
            library.add(data, song: song, source: "Fra fil: \(dest.lastPathComponent)", file: dest)
        }

        let id = await MainActor.run { self.identity }
        let df = ISO8601DateFormatter()
        var lines = [
            "MODULR – herkomst",
            "==================",
            "Fil: \(dest.lastPathComponent)",
            "Hentet: \(df.string(from: Date()))",
            "Sang: \(id?.displayName ?? "?")" + (id?.isrc.map { "  ISRC \($0)" } ?? ""),
            "Kilde: \(approved.source.title)\(approved.viaBrowser ? " (hentet af dig i browseren)" : " (officielt API)")",
        ]
        if let p = approved.pageURL ?? candidate.flatMap({ URL(string: $0.raw.pageURL) }) { lines.append("Side: \(p.absoluteString)") }
        if let t = pageTitle { lines.append("Sidens titel: \(t)") }
        if let u = approved.url { lines.append("Fil-URL: \(u.absoluteString)") }
        lines.append("Licens/betingelser: \(candidate?.raw.license ?? "Se siden ovenfor – MODULR henter kun det kunstneren selv har gjort gratis")")
        lines.append("Din fil: \(old.label) (score \(old.score))")
        lines.append("Ny fil: \(new.label) (score \(new.score))")
        lines.append("Fingerprint: \(comparison.percent) % af sangen matcher din fil")
        lines.append(tagNote)
        lines.append(artNote)
        LibraryStore.shared.adoptBetterFile(originalPath: original.path, newPath: dest.path)
        let prov = dir.appendingPathComponent(dest.deletingPathExtension().lastPathComponent + ".herkomst.txt")
        try lines.joined(separator: "\n").write(to: prov, atomically: true, encoding: .utf8)

        return FBResult(savedFile: dest, provenanceFile: prov,
                        summary: "\(new.label) – \(comparison.percent) % fingerprint-match. Gemt ved siden af din fil.")
    }

    private func fail(_ text: String) async {
        await MainActor.run {
            self.errorText = text
            self.busy = false
        }
    }
}

enum StoreSearch {
    static func beatportURL(_ query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        return URL(string: "https://www.beatport.com/search?q=" + q)
    }
}
