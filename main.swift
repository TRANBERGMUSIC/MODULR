// MODULR – Your tools. One platform.
// App-indgang, Bitrate-tjek-værktøjet og auto-opdatering.
// Analyse- og matchlogikken ligger i Core/, "Find bedre version" i App/.

import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

// MARK: - Model

struct TrackRow: Identifiable {
    let id = UUID()
    let url: URL
    var result: AnalysisResult?
    var error: String?

    var name: String { url.lastPathComponent }
    var format: String { url.pathExtension.uppercased() }

    var icon: String {
        if let r = result { return r.verdict.icon }
        if error != nil { return "⛔️" }
        return "⏳"
    }

    var statedText: String {
        guard let k = result?.statedKbps else { return result == nil ? "" : "–" }
        return "\(k) kbps"
    }

    var cutoffText: String {
        guard let r = result else { return "" }
        guard let c = r.cutoffHz else { return "Ingen kant" }
        return khz(c)
    }

    var verdictText: String {
        if let r = result { return r.verdictText }
        if let e = error { return "Fejl: \(e)" }
        return "Analyserer…"
    }
}

func khz(_ hz: Double) -> String {
    String(format: "%.1f kHz", hz / 1000).replacingOccurrences(of: ".", with: ",")
}

enum Tool: String, CaseIterable, Identifiable {
    case library = "Bibliotek"
    case bitrate = "Bitrate-tjek"
    case findBetter = "Find bedre version"
    case artwork = "Artwork"
    case accounts = "Konti"
    var id: String { rawValue }
}

final class AppModel: ObservableObject {
    @Published var tool: Tool = .library
    @Published var findBetterRequest: URL?
    @Published var rows: [TrackRow] = []
    @Published var selection: TrackRow.ID?

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "caf"]

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        q.qualityOfService = .userInitiated
        return q
    }()
    private var known = Set<String>()

    var doneCount: Int { rows.filter { $0.result != nil || $0.error != nil }.count }
    var fakeCount: Int { rows.filter { $0.result?.verdict == .fake }.count }
    var suspiciousCount: Int { rows.filter { $0.result?.verdict == .suspicious }.count }

    func add(urls: [URL]) {
        var newRows = [TrackRow]()
        for url in urls {
            for file in expand(url) where !known.contains(file.path) {
                known.insert(file.path)
                newRows.append(TrackRow(url: file))
            }
        }
        rows.append(contentsOf: newRows)
        // Alt du sætter ind i MODULR havner i biblioteket
        LibraryStore.shared.importFiles(newRows.map(\.url))
        if selection == nil { selection = newRows.first?.id }
        for row in newRows {
            let id = row.id
            let url = row.url
            queue.addOperation { [weak self] in
                var result: AnalysisResult?
                var errorText: String?
                do {
                    result = try Analyzer.analyze(url: url)
                } catch {
                    errorText = error.localizedDescription
                }
                DispatchQueue.main.async {
                    guard let self, let i = self.rows.firstIndex(where: { $0.id == id }) else { return }
                    self.rows[i].result = result
                    self.rows[i].error = errorText
                }
            }
        }
    }

    func clear() {
        queue.cancelAllOperations()
        rows = []
        known = []
        selection = nil
    }

    private func expand(_ url: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue {
            return Self.audioExtensions.contains(url.pathExtension.lowercased()) ? [url] : []
        }
        var out = [URL]()
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in en where Self.audioExtensions.contains(f.pathExtension.lowercased()) {
                out.append(f)
            }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func csv() -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Vurdering;Fil;Kunstner;Titel;Format;Angivet kbps;Målt kant;Reel kvalitet;Forklaring;Beatport-søgning;Sti"]
        for r in rows {
            let query = Stores.query(artist: r.result?.artist ?? "", title: r.result?.title ?? "")
            let fields = [
                r.result?.verdict.word ?? (r.error != nil ? "Fejl" : ""),
                r.name,
                r.result?.artist ?? "",
                r.result?.title ?? "",
                r.format,
                r.result?.statedKbps.map(String.init) ?? "",
                r.cutoffText,
                r.result?.tier.label ?? "",
                r.verdictText,
                query.isEmpty ? "" : (Stores.all[0].url(query)?.absoluteString ?? ""),
                r.url.path,
            ]
            lines.append(fields.map(q).joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Visning

extension Color {
    static let ember = Color(red: 1.0, green: 107 / 255, blue: 0)
    static let amber = Color(red: 1.0, green: 209 / 255, blue: 102 / 255)
    static let mist = Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
    static let void = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let graphite = Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
}

enum Filter: Hashable { case all, problems }

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: Filter = .all
    @State private var dropTargeted = false

    var visibleRows: [TrackRow] {
        switch filter {
        case .all: return model.rows
        case .problems: return model.rows.filter { $0.result?.verdict == .fake || $0.result?.verdict == .suspicious }
        }
    }

    var selectedRow: TrackRow? {
        guard let id = model.selection else { return nil }
        return model.rows.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Tilføj filer eller mapper…") { openPanel() }
                    .buttonStyle(.ember)
                if !model.rows.isEmpty {
                    ModSegmented(selection: $filter, options: [(Filter.all, "Alle"), (Filter.problems, "Kun problemer")])
                        .frame(width: 230)
                }
                Spacer()
                if !model.rows.isEmpty {
                    StatTile(value: "\(model.doneCount)/\(model.rows.count)", label: "Analyseret")
                    StatTile(value: "\(model.fakeCount)", label: "Fake", accent: model.fakeCount > 0)
                    StatTile(value: "\(model.suspiciousCount)", label: "Mistænkelige")
                    Button("Eksportér CSV…") { exportCSV() }
                    Button("Ryd") { model.clear() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)

            if model.rows.isEmpty {
                DropZone(icon: "waveform.badge.magnifyingglass", title: "Træk dine filer eller mapper herind",
                         subtitle: "MODULR lytter til selve lyden og afslører filer, der er opkonverteret fra lav bitrate – fx 128 kbps gemt som 320.",
                         targeted: dropTargeted, buttonTitle: "Vælg filer…", action: openPanel)
            } else {
                VSplitView {
                    Table(visibleRows, selection: $model.selection) {
                        TableColumn("") { r in Text(r.icon) }
                            .width(28)
                        TableColumn("Fil") { r in Text(r.name).lineLimit(1).help(r.url.path) }
                            .width(min: 180, ideal: 320)
                        TableColumn("Format") { r in Text(r.format) }
                            .width(55)
                        TableColumn("Filen siger") { r in Text(r.statedText).monospacedDigit() }
                            .width(80)
                        TableColumn("Målt kant") { r in Text(r.cutoffText).monospacedDigit() }
                            .width(85)
                        TableColumn("Reel kvalitet") { r in Text(r.result?.tier.label ?? "") }
                            .width(110)
                        TableColumn("Vurdering") { r in Text(r.verdictText).lineLimit(1).help(r.verdictText) }
                            .width(min: 200, ideal: 380)
                    }
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .background(Color.white.opacity(0.02))

                    Group {
                        if let row = selectedRow {
                            DetailView(row: row)
                        } else {
                            Text("Vælg en fil for at se dens spektrum")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minHeight: 360)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.hairline, lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        DispatchQueue.main.async { model.add(urls: [url]) }
                    }
                }
            }
            return true
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Analysér"
        if panel.runModal() == .OK {
            model.add(urls: panel.urls)
        }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bitrate_rapport.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            try? ("\u{FEFF}" + model.csv()).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Find en bedre version

struct Store {
    let name: String
    let note: String
    let url: (String) -> URL?
}

enum Stores {
    static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    static func query(artist: String, title: String) -> String {
        [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Fjerner "(Original Mix)", "[Label]" osv. – giver flere træf i iTunes.
    static func simplify(_ s: String) -> String {
        s.replacingOccurrences(of: #"\([^)]*\)|\[[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static let all: [Store] = [
        Store(name: "Beatport", note: "320 MP3 · WAV · AIFF · FLAC") {
            URL(string: "https://www.beatport.com/search?q=" + Stores.enc($0))
        },
        Store(name: "Traxsource", note: "320 MP3 · WAV · AIFF") {
            URL(string: "https://www.traxsource.com/search?term=" + Stores.enc($0))
        },
        Store(name: "Bandcamp", note: "FLAC · WAV · 320 MP3") {
            URL(string: "https://bandcamp.com/search?q=" + Stores.enc($0))
        },
    ]
}

struct ITunesResponse: Decodable {
    let results: [ITunesTrack]
}

struct ITunesTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let trackViewUrl: String?
    let trackPrice: Double?
    let currency: String?
}

struct FindBetterView: View {
    @EnvironmentObject var app: AppModel
    let row: TrackRow
    @State private var artist: String
    @State private var title: String
    @State private var matches: [ITunesTrack] = []
    @State private var lookupState: LookupState = .idle

    enum LookupState { case idle, loading, done, failed }

    init(row: TrackRow) {
        self.row = row
        _artist = State(initialValue: row.result?.artist ?? "")
        _title = State(initialValue: row.result?.title ?? "")
    }

    var query: String { Stores.query(artist: artist, title: title) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(row.result?.verdict == .ok ? "Find en version i endnu bedre kvalitet" : "Find en bedre version")
                    .font(.headline)
                Button("Find gratis fra kunstneren …") {
                    app.findBetterRequest = row.url
                    app.tool = .findBetter
                }
                .buttonStyle(.ember)
                Text("Genkender sangen og leder efter gratis downloads, kunstneren selv har lagt op.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Kunstner", text: $artist)
                    .textFieldStyle(.roundedBorder)
                TextField("Titel", text: $title)
                    .textFieldStyle(.roundedBorder)

                Text("Søg i DJ-butikkerne")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(Stores.all.indices, id: \.self) { i in
                    let store = Stores.all[i]
                    HStack {
                        Button(store.name) {
                            if let u = store.url(query) { NSWorkspace.shared.open(u) }
                        }
                        .disabled(query.isEmpty)
                        .frame(width: 120, alignment: .leading)
                        Text(store.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("Fundet i iTunes Store")
                    .font(.subheadline.weight(.semibold))
                switch lookupState {
                case .idle:
                    Text("Skriv kunstner og titel for at søge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case .failed:
                    Text("Kunne ikke kontakte iTunes – tjek internetforbindelsen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .done:
                    if matches.isEmpty {
                        Text("Ingen træf. Prøv at rette kunstner/titel, eller brug butikkerne ovenfor.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(matches.indices, id: \.self) { i in
                            let m = matches[i]
                            HStack(alignment: .center, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.trackName ?? "?")
                                        .lineLimit(1)
                                    Text([m.artistName, m.collectionName].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if let p = m.trackPrice, p > 0 {
                                    Text("\(String(format: "%.2f", p)) \(m.currency ?? "")")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                                if let s = m.trackViewUrl, let u = URL(string: s) {
                                    Button("Åbn") { NSWorkspace.shared.open(u) }
                                        .controlSize(.small)
                                }
                            }
                        }
                        Text("iTunes sælger 256 kbps AAC, som i praksis lyder lige så godt som 320 kbps MP3.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.trailing, 6)
        }
        .task(id: query) {
            await lookup()
        }
    }

    func lookup() async {
        let term = Stores.simplify(query)
        guard !term.isEmpty else {
            lookupState = .idle
            return
        }
        // Vent lidt, så der ikke søges for hvert tastetryk
        try? await Task.sleep(nanoseconds: 600_000_000)
        if Task.isCancelled { return }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: "DK"),
        ]
        guard let url = components.url else { return }
        lookupState = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if Task.isCancelled { return }
            matches = try JSONDecoder().decode(ITunesResponse.self, from: data).results
            lookupState = .done
        } catch {
            if Task.isCancelled { return }
            lookupState = .failed
        }
    }
}

struct DetailView: View {
    let row: TrackRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name)
                .font(.headline)
                .lineLimit(1)
            if let r = row.result {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(r.verdict.icon)  \(r.verdictText)")
                            .font(.title3)
                        if let img = r.spectrogram {
                            SpectrogramView(image: img, nyquist: r.sampleRate / 2, cutoff: r.cutoffHz)
                        }
                        Text("Spektrogram: tid fra venstre mod højre, frekvens nedefra og op. En ægte 320 kbps-fil har lyd helt op til ca. 20 kHz. En fil, der er opkonverteret fra 128 kbps, har en skarp kant ved ca. 16–17 kHz, og over den er alt sort.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    FindBetterView(row: row)
                        .id(row.id)
                        .frame(width: 330)
                }
            } else if let e = row.error {
                Text("Kunne ikke analysere filen: \(e)")
            } else {
                ProgressView("Analyserer…")
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct SpectrogramView: View {
    let image: CGImage
    let nyquist: Double
    let cutoff: Double?

    let marks: [(Double, String)] = [
        (16000, "16 kHz · 128 kbps"),
        (19500, "19,5 kHz · 256 kbps"),
        (20500, "20,5 kHz · 320 kbps"),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: geo.size.width, height: geo.size.height)

                ForEach(marks.indices, id: \.self) { i in
                    let y = geo.size.height * (1 - marks[i].0 / nyquist)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    Text(marks[i].1)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.leading, 6)
                        .offset(x: 0, y: y + 1)
                }

                if let c = cutoff {
                    let y = geo.size.height * (1 - c / nyquist)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                    .stroke(Color.mist, lineWidth: 2)
                    Text("Målt kant: \(khz(c))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.mist)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.6))
                        .offset(x: max(0, geo.size.width - 170), y: max(0, y - 20))
                }
            }
        }
        .frame(minHeight: 200)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Auto-opdatering
//
// Appen tjekker filen VERSION i GitHub-repoet. Er der en nyere version, henter den
// koden, bygger den nye app med Installer.command og skifter den gamle ud.

enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

final class Updater: ObservableObject {
    static let owner = "TRANBERGMUSIC"
    static let repo = "MODULR"
    static let branch = "main"

    enum Status: Equatable {
        case idle, checking, upToDate, available(String), working(String), failed(String)
    }

    @Published var status: Status = .idle
    @Published var lastChecked: Date?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    /// Tjek ved start, hver 30. minut og når du skifter tilbage til appen (højst hvert 5. minut).
    func startAutomaticChecks() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in self?.check() }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let last = self.lastChecked, Date().timeIntervalSince(last) < 5 * 60 { return }
            self.check()
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func set(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    func check(manual: Bool = false) {
        if case .working = status { return }
        if case .available = status, !manual { return }
        if manual { set(.checking) }
        // GitHubs API giver den aktuelle fil med det samme (raw-adressen kan være op til 5 min gammel)
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/contents/VERSION?ref=\(Self.branch)")!,
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        req.setValue("MODULR/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        fetchVersion(req) { [weak self] latest in
            guard let self else { return }
            if let latest {
                self.handle(latest: latest, manual: manual)
                return
            }
            // Reserve: raw-adressen med cache-buster
            let ts = Int(Date().timeIntervalSince1970)
            let raw = URLRequest(url: URL(string: "https://raw.githubusercontent.com/\(Self.owner)/\(Self.repo)/\(Self.branch)/VERSION?t=\(ts)")!,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
            self.fetchVersion(raw) { latest in
                if let latest {
                    self.handle(latest: latest, manual: manual)
                } else {
                    self.set(manual ? .failed("Kunne ikke tjekke for opdateringer. Tjek internetforbindelsen.") : .idle)
                }
            }
        }
    }

    private func fetchVersion(_ req: URLRequest, done: @escaping (String?) -> Void) {
        URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, code == 200, let data, let text = String(data: data, encoding: .utf8) else { done(nil); return }
            let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
            done(v.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil ? v : nil)
        }.resume()
    }

    private func handle(latest: String, manual: Bool) {
        DispatchQueue.main.async { self.lastChecked = Date() }
        if latest.compare(currentVersion, options: .numeric) == .orderedDescending {
            set(.available(latest))
            DispatchQueue.main.async { NSApp.requestUserAttention(.informationalRequest) }
        } else {
            set(manual ? .upToDate : .idle)
        }
    }

    func install() {
        set(.working("Henter den nye version…"))
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MODULR-update-\(UUID().uuidString)")
        guard let zipURL = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/archive/refs/heads/\(Self.branch).zip") else { return }

        URLSession.shared.downloadTask(with: zipURL) { tmp, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, code == 200, let tmp else {
                self.set(.failed("Download af opdateringen fejlede."))
                return
            }
            let zip = work.appendingPathComponent("src.zip")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.moveItem(at: tmp, to: zip)
            } catch {
                self.set(.failed("Kunne ikke gemme opdateringen: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                    let src = work.appendingPathComponent("\(Self.repo)-\(Self.branch)")
                    self.set(.working("Bygger den nye version (ca. et minut)…"))
                    let out = work.appendingPathComponent("out")
                    try self.run("/bin/bash", [src.appendingPathComponent("Installer.command").path, "--build-only", out.path])
                    let newApp = out.appendingPathComponent("MODULR.app")
                    guard fm.fileExists(atPath: newApp.path) else {
                        throw UpdateError.message("Byggeriet gav ingen app.")
                    }
                    self.set(.working("Genstarter…"))
                    try self.swapAndRelaunch(newApp: newApp, work: work)
                } catch {
                    self.set(.failed("Opdateringen fejlede: \(error.localizedDescription)"))
                }
            }
        }.resume()
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            let errors = output.split(separator: "\n").filter { $0.contains("error:") }
            if let first = errors.first {
                // fx ".../App/LibraryView.swift:412:17: error: ..." → "LibraryView.swift:412: ..."
                let line = String(first)
                let short = line.components(separatedBy: "/").last ?? line
                throw UpdateError.message(short + (errors.count > 1 ? " (+\(errors.count - 1) flere)" : ""))
            }
            throw UpdateError.message(String(output.suffix(400)))
        }
        return output
    }

    /// Venter til appen er lukket, skifter den gamle app ud med den nye og åbner den igen.
    private func swapAndRelaunch(newApp: URL, work: URL) throws {
        let current = Bundle.main.bundleURL
        // Den nye app lægges samme sted som den gamle, under sit (evt. nye) navn
        let destination = current.deletingLastPathComponent().appendingPathComponent(newApp.lastPathComponent).path
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(current.path)"
        rm -rf "\(destination)"
        mv "\(newApp.path)" "\(destination)"
        open "\(destination)"
        rm -rf "\(work.path)"
        """
        let scriptURL = work.appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try run("/bin/bash", ["-c", "nohup /bin/bash \"\(scriptURL.path)\" >/dev/null 2>&1 &"])
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

struct UpdateBanner: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        switch updater.status {
        case .idle, .checking:
            EmptyView()
        case .upToDate:
            bar {
                Text("Du har den nyeste version (\(updater.currentVersion)).")
                Spacer()
                Button("OK") { updater.status = .idle }
            }
        case .available(let version):
            bar {
                Text("Ny version \(version) er klar – du har \(updater.currentVersion).").fontWeight(.medium)
                Spacer()
                Button("Senere") { updater.status = .idle }
                Button("Opdatér nu") { updater.install() }
                    .buttonStyle(.ember)
                    .keyboardShortcut(.defaultAction)
            }
        case .working(let message):
            bar {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                Spacer()
            }
        case .failed(let message):
            bar {
                Text("⚠️ \(message)")
                    .lineLimit(2)
                Spacer()
                Button("Luk") { updater.status = .idle }
            }
        }
    }

    func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Color.ember.opacity(0.22), Color.ember.opacity(0.08)],
                                         startPoint: .leading, endPoint: .trailing))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.ember.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 24)
            .padding(.top, 38)
    }
}

// MARK: - App

enum EditMenu {
    static var textFocused: Bool {
        guard let r = NSApp.keyWindow?.firstResponder else { return false }
        return r is NSText || r is NSTextView
    }
}

@main
struct ModulrApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()
    @StateObject private var settings: FBSettings
    @StateObject private var findBetter: FindBetterModel
    @StateObject private var artwork = ArtworkModel()
    @StateObject private var accounts = AccountsModel()
    @StateObject private var library: ArtworkLibrary
    @StateObject private var libraryStore = LibraryStore.shared
    @StateObject private var usbStore = UsbStore.shared

    init() {
        let s = FBSettings()
        let lib = ArtworkLibrary.shared
        _settings = StateObject(wrappedValue: s)
        _library = StateObject(wrappedValue: lib)
        _findBetter = StateObject(wrappedValue: FindBetterModel(settings: s, library: lib))
    }

    var body: some Scene {
        WindowGroup("MODULR") {
            RootView()
                .environmentObject(model)
                .environmentObject(updater)
                .environmentObject(settings)
                .environmentObject(findBetter)
                .environmentObject(artwork)
                .environmentObject(accounts)
                .environmentObject(library)
                .environmentObject(libraryStore)
                .environmentObject(usbStore)
                .buttonStyle(.ghost)
                .frame(minWidth: 1280, minHeight: 820)
                .background(Color.void)
                .preferredColorScheme(.dark)
                .tint(Color.ember)
                .onAppear { updater.startAutomaticChecks() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Søg efter opdateringer…") { updater.check(manual: true) }
            }
            // ⌘Z / ⇧⌘Z: i et tekstfelt fortryder det teksten – ellers dine rettelser på sangene (cues, grid, EQ …)
            CommandGroup(replacing: .undoRedo) {
                Button("Fortryd") {
                    if EditMenu.textFocused { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) } else { EditHistory.shared.undo() }
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Gentag") {
                    if EditMenu.textFocused { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) } else { EditHistory.shared.redo() }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .preferredColorScheme(.dark)
                .tint(Color.ember)
        }
    }
}
