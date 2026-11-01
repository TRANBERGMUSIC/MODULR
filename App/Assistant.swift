// MODULR – AI-assistenten: skriv hvad du vil have gjort ("læg alle techno over 140 i en playliste sorteret
// efter toneart", "brug coveret fra den gamle version på wav'en", "udskift X med filen her") – den bruger
// MODULRs egne funktioner til at gøre det. Den billigste model (Claude Haiku 5.5): en typisk opgave koster
// under 1 øre. Biblioteket sendes ikke med – assistenten søger selv i det med små, korte opslag.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model og pris

enum AIPricing {
    static let model = "claude-haiku-5-5"
    // USD pr. million tokens (prompter under 100.000 tokens – vi holder os altid under)
    static let input = 0.10, output = 0.50, cacheRead = 0.01, cacheWrite = 0.125
    static let dkkPerUSD = 6.9   // ca.

    static func dkk(input i: Int, output o: Int, cacheRead cr: Int, cacheWrite cw: Int) -> Double {
        let usd = (Double(i) * input + Double(o) * output + Double(cr) * cacheRead + Double(cw) * cacheWrite) / 1_000_000
        return usd * dkkPerUSD
    }

    static func text(_ dkk: Double) -> String {
        let ore = dkk * 100
        if ore < 10 { return String(format: "%.2f øre", ore).replacingOccurrences(of: ".", with: ",") }
        return String(format: "%.2f kr.", dkk).replacingOccurrences(of: ".", with: ",")
    }
}

struct ChatLine: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant, action, error }
    let id = UUID()
    var kind: Kind
    var text: String
}

@MainActor
final class AssistantModel: ObservableObject {
    static let shared = AssistantModel()

    @Published var lines: [ChatLine] = []
    @Published var running = false
    @Published var costDKK = 0.0
    @Published var lastCostDKK = 0.0
    var openFindBetter: ((URL) -> Void)?

    private var history: [[String: Any]] = []
    private var task: Task<Void, Never>?

    var hasKey: Bool { !APIKeys.load().anthropic.trimmingCharacters(in: .whitespaces).isEmpty }

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !running else { return }
        lines.append(ChatLine(kind: .user, text: t))
        history.append(["role": "user", "content": t])
        trimHistory()
        running = true
        lastCostDKK = 0
        task = Task { await loop() }
    }

    func stop() {
        task?.cancel()
        running = false
    }

    func clear() {
        stop()
        lines = []
        history = []
        costDKK = 0
        lastCostDKK = 0
    }

    /// Hold samtalen kort (billigere): de ældste beskeder smides væk, men altid fra en ren brugerbesked.
    private func trimHistory() {
        while history.count > 30 {
            history.removeFirst()
            while let first = history.first, !(first["role"] as? String == "user" && first["content"] is String) {
                history.removeFirst()
            }
        }
    }

    // MARK: Samtale-løkken (model → værktøjer → model …)

    private func loop() async {
        defer { running = false }
        let key = APIKeys.load().anthropic.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            lines.append(ChatLine(kind: .error, text: "Indsæt din Anthropic API-nøgle øverst først."))
            return
        }
        for _ in 0..<14 {
            if Task.isCancelled { return }
            let response: [String: Any]
            do {
                response = try await call(key: key)
            } catch {
                lines.append(ChatLine(kind: .error, text: error.localizedDescription))
                return
            }
            if let u = response["usage"] as? [String: Any] {
                let c = AIPricing.dkk(input: u["input_tokens"] as? Int ?? 0, output: u["output_tokens"] as? Int ?? 0,
                                      cacheRead: u["cache_read_input_tokens"] as? Int ?? 0,
                                      cacheWrite: u["cache_creation_input_tokens"] as? Int ?? 0)
                costDKK += c
                lastCostDKK += c
            }
            let content = response["content"] as? [[String: Any]] ?? []
            history.append(["role": "assistant", "content": content])
            var results = [[String: Any]]()
            for block in content {
                switch block["type"] as? String {
                case "text":
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lines.append(ChatLine(kind: .assistant, text: t))
                    }
                case "tool_use":
                    let name = block["name"] as? String ?? ""
                    let input = block["input"] as? [String: Any] ?? [:]
                    let id = block["id"] as? String ?? ""
                    lines.append(ChatLine(kind: .action, text: AssistantTools.describe(name, input)))
                    let out = await AssistantTools.run(name, input, model: self)
                    results.append(["type": "tool_result", "tool_use_id": id, "content": out])
                default:
                    break
                }
            }
            if results.isEmpty || (response["stop_reason"] as? String) != "tool_use" { return }
            history.append(["role": "user", "content": results])
        }
        lines.append(ChatLine(kind: .error, text: "Stoppede efter mange trin – skriv hvis den skal fortsætte."))
    }

    private func call(key: String) async throws -> [String: Any] {
        var tools = AssistantTools.definitions
        if !tools.isEmpty { tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"] }
        let body: [String: Any] = [
            "model": AIPricing.model,
            "max_tokens": 1024,
            "system": [["type": "text", "text": AssistantTools.systemPrompt, "cache_control": ["type": "ephemeral"]]],
            "tools": tools,
            "messages": history,
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 60
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "ukendt fejl"
            if status == 401 { throw AssistantError.message("API-nøglen blev afvist – tjek at den er indsat rigtigt.") }
            if status == 429 || status == 529 { throw AssistantError.message("Claude har travlt lige nu – prøv igen om lidt.") }
            throw AssistantError.message("Fejl fra Claude (\(status)): \(msg)")
        }
        return obj
    }
}

enum AssistantError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

// MARK: - Værktøjerne (MODULRs egne funktioner)

@MainActor
enum AssistantTools {
    static let systemPrompt = """
    Du er assistenten i MODULR, en DJ-app (bibliotek som rekordbox, eksport til CDJ-3000 via USB). Du taler dansk, kort og venligt.
    Du udfører opgaver med værktøjerne i stedet for at forklare hvordan. Søg altid først (search_tracks / list_playlists) for at
    få id'er – find aldrig selv på id'er. Sange har korte id'er (8 tegn). Når flere sange passer på en beskrivelse, så tag dem alle,
    medmindre brugeren tydeligt mener én. Er det uklart hvilken sang der menes, så spørg kort.
    Regler:
    - Søg kun efter bedre versioner (find_better_version), når brugeren selv beder om det. Den søgning finder kun det kunstneren
      selv har gjort gratis tilgængeligt – lov aldrig andet.
    - replace_file erstatter en sangs fil med en fil brugeren har givet (stien står i beskeden). Den gamle fil lægges i papirkurven.
    - Slet aldrig sange eller playlister – det har du ikke værktøjer til; bed brugeren gøre det selv.
    - Hot cue A er altid cue-punktet. Genrer er brede (Techno, Hard Techno, Tech House, House, Trance …).
    - Afslut med én kort linje om hvad der blev gjort (antal sange osv.). Ingen lange lister, medmindre brugeren beder om det.
    """

    static func prop(_ type: String, _ desc: String) -> [String: Any] { ["type": type, "description": desc] }
    static func ids(_ desc: String = "Korte sang-id'er fra search_tracks") -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": desc]
    }
    static func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc, "input_schema": ["type": "object", "properties": props, "required": required]]
    }

    static let definitions: [[String: Any]] = [
        tool("search_tracks", "Søg i biblioteket. Returnerer linjer: id|kunstner|titel|bpm|toneart|genre|kvalitet|cover|hotcueA.",
             ["query": prop("string", "Ord i titel/kunstner/album/filnavn"),
              "genre": prop("string", "Bred genre"),
              "bpm_min": prop("number", "Mindste BPM"), "bpm_max": prop("number", "Højeste BPM"),
              "key": prop("string", "Camelot, fx 8A"),
              "playlist": prop("string", "Kun sange i denne playliste (navn eller id)"),
              "missing": ["type": "string", "enum": ["artwork", "genre", "waveform"], "description": "Sange der mangler dette"],
              "bad_quality": prop("boolean", "Kun sange i dårlig kvalitet (under 256 kbps)"),
              "limit": prop("integer", "Højst så mange (standard 40, maks 300)")]),
        tool("list_playlists", "Alle playlister og mapper: id|sti|antal sange.", [:]),
        tool("create_playlist", "Opret en playliste (evt. i en mappe). Returnerer id.",
             ["name": prop("string", "Navn"), "folder": prop("string", "Mappe (navn eller id), valgfri")], ["name"]),
        tool("add_to_playlist", "Læg sange i en playliste.", ["playlist": prop("string", "Navn eller id"), "track_ids": ids()], ["playlist", "track_ids"]),
        tool("remove_from_playlist", "Fjern sange fra en playliste (de bliver i biblioteket).",
             ["playlist": prop("string", "Navn eller id"), "track_ids": ids()], ["playlist", "track_ids"]),
        tool("sort_playlist", "Sortér en playliste.",
             ["playlist": prop("string", "Navn eller id"),
              "by": ["type": "string", "enum": ["bpm", "key", "harmonic", "energy", "title", "artist", "genre", "added"],
                     "description": "harmonic = toneart i Camelot-rækkefølge og så BPM (god til mix)"],
              "descending": prop("boolean", "Faldende")], ["playlist", "by"]),
        tool("set_genre", "Sæt genre. genre=\"suggestion\" bruger appens forslag for hver sang.",
             ["track_ids": ids(), "genre": prop("string", "Genre eller \"suggestion\"")], ["track_ids", "genre"]),
        tool("set_info", "Ret titel/kunstner på én sang (evt. også i selve filen).",
             ["track_id": prop("string", "Kort id"), "title": prop("string", "Ny titel"), "artist": prop("string", "Ny kunstner"),
              "write_to_file": prop("boolean", "Skriv også i filens tags")], ["track_id"]),
        tool("clean_names", "Ryd op i titler/kunstnere (spornumre, _, [www…], STORE BOGSTAVER).", ["track_ids": ids()], ["track_ids"]),
        tool("set_artwork", "Læg et cover på sange: fra en billedfil/lydfil (sti) eller fra en anden sang i biblioteket.",
             ["track_ids": ids(), "from_file": prop("string", "Sti til billede eller lydfil med cover"),
              "from_track": prop("string", "Kort id på sangen coveret skal tages fra")], ["track_ids"]),
        tool("replace_file", "Erstat en sangs fil med en bedre version (sti fra brugeren). Data, cues og cover bevares.",
             ["track_id": prop("string", "Kort id"), "file_path": prop("string", "Sti til den nye fil"),
              "force": prop("boolean", "Også selvom det ikke ligner samme sang (kun hvis brugeren siger det)")], ["track_id", "file_path"]),
        tool("import_files", "Sæt filer/mapper ind i biblioteket (evt. direkte i en playliste).",
             ["paths": ["type": "array", "items": ["type": "string"]], "playlist": prop("string", "Navn eller id, valgfri")], ["paths"]),
        tool("find_better_version", "Åbn 'Find bedre version' for en sang (kun når brugeren beder om det).",
             ["track_id": prop("string", "Kort id")], ["track_id"]),
        tool("send_to_usb", "Læg sange på rekordbox-USB'en i en playliste (findes den ikke, oprettes den). Skrives med det samme.",
             ["track_ids": ids(), "playlist_name": prop("string", "Playliste på USB'en"), "drive": prop("string", "USB-navn, valgfri")],
             ["track_ids", "playlist_name"]),
        tool("analyze_again", "Analysér sange igen (BPM, grid, toneart, waveform).", ["track_ids": ids()], ["track_ids"]),
        tool("fix_loudness", "Ret lydstyrken (som Platinum Notes) til målet i indstillingerne.", ["track_ids": ids()], ["track_ids"]),
    ]

    static func describe(_ name: String, _ i: [String: Any]) -> String {
        let n = (i["track_ids"] as? [Any])?.count
        switch name {
        case "search_tracks": return "Søger i biblioteket" + ((i["query"] as? String).map { ": \($0)" } ?? "")
        case "list_playlists": return "Ser playlisterne"
        case "create_playlist": return "Opretter playlisten \(i["name"] as? String ?? "")"
        case "add_to_playlist": return "Lægger \(n ?? 0) sange i \(i["playlist"] as? String ?? "")"
        case "remove_from_playlist": return "Fjerner \(n ?? 0) sange fra \(i["playlist"] as? String ?? "")"
        case "sort_playlist": return "Sorterer \(i["playlist"] as? String ?? "") efter \(i["by"] as? String ?? "")"
        case "set_genre": return "Sætter genre på \(n ?? 0) sange"
        case "set_info": return "Retter titel/kunstner"
        case "clean_names": return "Rydder op i \(n ?? 0) navne"
        case "set_artwork": return "Lægger cover på \(n ?? 0) sange"
        case "replace_file": return "Udskifter filen"
        case "import_files": return "Sætter filer ind i biblioteket"
        case "find_better_version": return "Åbner Find bedre version"
        case "send_to_usb": return "Sender \(n ?? 0) sange til USB"
        case "analyze_again": return "Analyserer \(n ?? 0) sange igen"
        case "fix_loudness": return "Retter lydstyrken på \(n ?? 0) sange"
        default: return name
        }
    }

    // MARK: Opslag

    static var lib: LibraryStore { LibraryStore.shared }
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func track(_ s: String?) -> LibTrack? {
        guard let s = s?.lowercased().trimmingCharacters(in: .whitespaces), s.count >= 4 else { return nil }
        return lib.index.tracks.first { $0.id.uuidString.lowercased().hasPrefix(s) }
    }

    static func trackIDs(_ v: Any?) -> [UUID] {
        ((v as? [Any]) ?? []).compactMap { track($0 as? String)?.id }
    }

    static func node(_ s: String?) -> LibNode? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let l = s.lowercased()
        let nodes = lib.index.nodes
        if l.count >= 4, let n = nodes.first(where: { $0.id.uuidString.lowercased().hasPrefix(l) }) { return n }
        if let n = nodes.first(where: { $0.name.lowercased() == l }) { return n }
        return nodes.first(where: { $0.name.lowercased().contains(l) })
    }

    static func line(_ t: LibTrack) -> String {
        let genre = t.genre.isEmpty ? (t.genreSuggestion.map { "\($0)?" } ?? "-") : t.genre
        return [short(t.id), t.artist, t.title, t.bpm.map { String(format: "%.1f", $0) } ?? "-", t.key?.camelot ?? "-",
                genre, t.qualityText, t.artFile == nil ? "intet cover" : "cover", t.hotCues?["A"] == nil ? "-" : "A"]
            .joined(separator: "|")
    }

    static func path(_ n: LibNode) -> String {
        var parts = [n.name]
        var p = n.parent
        while let id = p, let parent = lib.index.nodes.first(where: { $0.id == id }) {
            parts.insert(parent.name, at: 0)
            p = parent.parent
        }
        return parts.joined(separator: " / ")
    }

    // MARK: Udfør

    static func run(_ name: String, _ i: [String: Any], model: AssistantModel) async -> String {
        switch name {
        case "search_tracks":
            var list = lib.index.tracks
            if let pl = i["playlist"] as? String {
                guard let n = node(pl) else { return "Playlisten '\(pl)' findes ikke." }
                list = lib.index.tracks(in: n)
            }
            if let q = (i["query"] as? String)?.lowercased(), !q.isEmpty {
                let words = q.split(separator: " ").map(String.init)
                list = list.filter { t in
                    let hay = (t.artist + " " + t.title + " " + t.album + " " + t.fileName).lowercased()
                    return words.allSatisfy { hay.contains($0) }
                }
            }
            if let g = (i["genre"] as? String)?.lowercased(), !g.isEmpty {
                list = list.filter { ($0.genre.isEmpty ? ($0.genreSuggestion ?? "") : $0.genre).lowercased().contains(g) }
            }
            if let a = i["bpm_min"] as? Double { list = list.filter { ($0.bpm ?? 0) >= a } }
            if let b = i["bpm_max"] as? Double { list = list.filter { ($0.bpm ?? 0) <= b } }
            if let k = (i["key"] as? String)?.uppercased(), !k.isEmpty { list = list.filter { $0.key?.camelot == k } }
            switch i["missing"] as? String {
            case "artwork": list = list.filter { $0.artFile == nil }
            case "genre": list = list.filter { $0.genre.isEmpty }
            case "waveform": list = list.filter { !$0.hasWave }
            default: break
            }
            if i["bad_quality"] as? Bool == true { list = list.filter { $0.analyzed && $0.needsUpgrade } }
            let limit = min(300, max(1, i["limit"] as? Int ?? 40))
            if list.isEmpty { return "Ingen sange passer." }
            var out = "\(list.count) sange" + (list.count > limit ? " (viser \(limit))" : "") + ":\n"
            out += list.prefix(limit).map(line).joined(separator: "\n")
            return out

        case "list_playlists":
            let nodes = lib.index.nodes
            if nodes.isEmpty { return "Ingen playlister endnu." }
            return nodes.map { "\(short($0.id))|\(path($0))\($0.isFolder ? " (mappe)" : "")|\($0.isFolder ? "-" : String($0.trackIDs.count))" }
                .joined(separator: "\n")

        case "create_playlist":
            let name = (i["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return "Mangler navn." }
            var parent: UUID?
            if let f = i["folder"] as? String, !f.isEmpty {
                parent = node(f).flatMap { $0.isFolder ? $0.id : nil } ?? lib.createNode(name: f, parent: nil, folder: true)
            }
            let id = lib.createNode(name: name, parent: parent, folder: false)
            return "Oprettet: \(short(id))|\(name)"

        case "add_to_playlist":
            guard let n = node(i["playlist"] as? String), !n.isFolder else { return "Playlisten findes ikke (eller er en mappe)." }
            let t = trackIDs(i["track_ids"])
            lib.add(t, to: n.id)
            return "\(t.count) sange lagt i \(n.name)."

        case "remove_from_playlist":
            guard let n = node(i["playlist"] as? String), !n.isFolder else { return "Playlisten findes ikke." }
            let t = trackIDs(i["track_ids"])
            lib.removeFromPlaylist(t, playlist: n.id)
            return "\(t.count) sange fjernet fra \(n.name)."

        case "sort_playlist":
            guard let n = node(i["playlist"] as? String), !n.isFolder else { return "Playlisten findes ikke." }
            var list = lib.index.tracks(in: n)
            let by = i["by"] as? String ?? "bpm"
            func keyIndex(_ t: LibTrack) -> Int { t.key.map { $0.camelotNumber * 2 + ($0.minor ? 0 : 1) } ?? 99 }
            switch by {
            case "bpm": list.sort { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
            case "key": list.sort { keyIndex($0) < keyIndex($1) }
            case "harmonic": list.sort { (keyIndex($0), $0.bpm ?? 0) < (keyIndex($1), $1.bpm ?? 0) }
            case "energy": list.sort { ($0.energy ?? 0, $0.bpm ?? 0) < ($1.energy ?? 0, $1.bpm ?? 0) }
            case "title": list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            case "artist": list.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
            case "genre": list.sort { $0.genre.localizedCaseInsensitiveCompare($1.genre) == .orderedAscending }
            case "added": list.sort { $0.addedAt < $1.addedAt }
            default: return "Ukendt sortering."
            }
            if i["descending"] as? Bool == true { list.reverse() }
            lib.setOrder(n.id, list.map(\.id))
            return "\(n.name) sorteret efter \(by) (\(list.count) sange)."

        case "set_genre":
            let t = trackIDs(i["track_ids"])
            let g = i["genre"] as? String ?? ""
            lib.setGenre(t, g.lowercased() == "suggestion" ? nil : g)
            return "Genre sat på \(t.count) sange."

        case "set_info":
            guard let t = track(i["track_id"] as? String) else { return "Sangen findes ikke." }
            lib.setInfo(t.id, title: i["title"] as? String ?? t.title, artist: i["artist"] as? String ?? t.artist,
                        genre: t.genre, writeTags: i["write_to_file"] as? Bool ?? false, renameFile: false)
            return "Rettet: \(i["artist"] as? String ?? t.artist) – \(i["title"] as? String ?? t.title)"

        case "clean_names":
            let n = lib.cleanNames(trackIDs(i["track_ids"]))
            return "\(n) navne ryddet op."

        case "set_artwork":
            let t = trackIDs(i["track_ids"])
            guard !t.isEmpty else { return "Ingen sange." }
            if let f = i["from_file"] as? String, !f.isEmpty {
                let url = URL(fileURLWithPath: (f as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { return "Filen findes ikke: \(f)" }
                lib.artworkFromFile(url, to: t)
                return "Cover lægges på \(t.count) sange fra \(url.lastPathComponent)."
            }
            if let src = track(i["from_track"] as? String) {
                guard let data = await lib.artworkData(src) else { return "\(src.title) har intet cover." }
                lib.setArtwork(data, sourceSong: LibraryStore.songInfo(src), sourceName: LibraryStore.displayName(src), on: t)
                return "Cover fra \(src.title) lægges på \(t.count) sange."
            }
            return "Angiv from_file eller from_track."

        case "replace_file":
            guard let t = track(i["track_id"] as? String) else { return "Sangen findes ikke." }
            let f = (i["file_path"] as? String ?? "") as NSString
            let url = URL(fileURLWithPath: f.expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return "Filen findes ikke: \(url.path)" }
            let rule = ImprovementRule(rawValue: UserDefaults.standard.string(forKey: "fb.rule") ?? "") ?? .realTier
            do {
                let r = try await lib.replaceFile(t.id, with: url, rule: rule, force: i["force"] as? Bool ?? false)
                return "Udskiftet: \(r)"
            } catch {
                return "Ikke udskiftet: \(error.localizedDescription)"
            }

        case "import_files":
            let urls = ((i["paths"] as? [Any]) ?? []).compactMap { $0 as? String }
                .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return "Ingen af filerne findes." }
            let pl = (i["playlist"] as? String).flatMap { node($0) }.flatMap { $0.isFolder ? nil : $0.id }
            lib.importDropped(urls, into: pl)
            return "\(urls.count) filer/mapper sat ind – de analyseres nu."

        case "find_better_version":
            guard let t = track(i["track_id"] as? String) else { return "Sangen findes ikke." }
            model.openFindBetter?(t.url)
            return "Find bedre version er åbnet for \(t.title). Den viser kun det kunstneren selv har gjort gratis tilgængeligt."

        case "send_to_usb":
            let usb = UsbStore.shared
            guard !usb.drives.isEmpty else { return "Ingen rekordbox-USB er sat i." }
            let want = (i["drive"] as? String)?.lowercased()
            guard let d = usb.drives.first(where: { want == nil || $0.name.lowercased().contains(want!) }) ?? usb.drives.first else {
                return "USB'en findes ikke."
            }
            let t = trackIDs(i["track_ids"])
            let name = (i["playlist_name"] as? String ?? "MODULR").trimmingCharacters(in: .whitespaces)
            if let existing = usb.contents[d.id]?.nodes?.first(where: { !$0.folder && $0.name.lowercased() == name.lowercased() }) {
                usb.add(t, to: d, existing: existing.id)
            } else {
                usb.newPlaylist(d, name: name, parent: .root, tracks: t)
            }
            return "\(t.count) sange sendes til \(name) på \(d.name) (skrives om et øjeblik)."

        case "analyze_again":
            let t = trackIDs(i["track_ids"])
            lib.reanalyze(t)
            return "\(t.count) sange analyseres igen."

        case "fix_loudness":
            let t = trackIDs(i["track_ids"])
            lib.fixLoudness(t, force: true)
            return "Lydstyrken rettes på \(t.count) sange."

        default:
            return "Ukendt værktøj."
        }
    }
}

// MARK: - Skærmen

struct AssistantView: View {
    @ObservedObject private var model = AssistantModel.shared
    @EnvironmentObject var settings: FBSettings
    @EnvironmentObject var app: AppModel
    @State private var input = ""
    @State private var targeted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if settings.keys.anthropic.trimmingCharacters(in: .whitespaces).isEmpty {
                keyCard
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if model.lines.isEmpty { examples }
                        ForEach(model.lines) { l in bubble(l).id(l.id) }
                        if model.running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Arbejder …").font(.system(size: 12)).foregroundColor(.mist.opacity(0.6))
                            }
                            .id("running")
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.lines.count) { _, _ in
                    if let last = model.lines.last?.id {
                        withAnimation(Motion.snappy) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .overlay { if targeted { DropHint(text: "Slip filerne – stierne sættes ind i beskeden").padding(16) } }
            .fileDrop(targeted: $targeted) { urls in
                let paths = urls.map(\.path).joined(separator: "\n")
                input += (input.isEmpty ? "" : "\n") + paths
                focused = true
            }
            inputBar
        }
        .onAppear {
            model.openFindBetter = { url in
                app.findBetterRequest = url
                app.tool = .findBetter
            }
            focused = true
        }
    }

    var keyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Forbind Claude").font(.system(size: 14, weight: .semibold)).foregroundColor(.mist)
            Text("Assistenten bruger Claude Haiku 5.5 – Anthropics billigste model. En typisk opgave koster under 1 øre. Opret en nøgle på console.anthropic.com (du betaler kun for det du bruger), og indsæt den her. Den gemmes kun på din Mac.")
                .font(.system(size: 12)).foregroundColor(.mist.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("sk-ant-…", text: $settings.keys.anthropic)
                    .textFieldStyle(.roundedBorder)
                Button("Åbn console.anthropic.com") { NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    var examples: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skriv hvad du vil have gjort – fx:").font(.system(size: 13, weight: .semibold)).foregroundColor(.mist)
            ForEach(["Lav en playliste med al hard techno over 145 BPM, sorteret harmonisk",
                     "Giv alle sange uden genre appens forslag",
                     "Brug coveret fra den gamle version af Losing It på wav-filen",
                     "Ryd op i navnene i playlisten Downloads",
                     "Send playlisten Fredag til USB'en",
                     "Find en bedre version af sangene i dårlig kvalitet"], id: \.self) { ex in
                Button { input = ex; focused = true } label: {
                    Text(ex).font(.system(size: 12)).foregroundColor(.mist.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.press)
            }
            Text("Træk filer herind (fx en bedre version eller et cover), så kan du skrive hvad der skal ske med dem.")
                .font(.system(size: 11)).foregroundColor(.mist.opacity(0.5))
        }
    }

    @ViewBuilder
    func bubble(_ l: ChatLine) -> some View {
        switch l.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(l.text).font(.system(size: 13)).foregroundColor(.mist).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.ember.opacity(0.22)))
            }
        case .assistant:
            Text(LocalizedStringKey(l.text)).font(.system(size: 13)).foregroundColor(.mist).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        case .action:
            Label(l.text, systemImage: "gearshape.2").font(.system(size: 11)).foregroundColor(.mist.opacity(0.5))
        case .error:
            Label(l.text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundColor(.orange)
        }
    }

    var inputBar: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Hvad skal der ske?", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
                    .onSubmit(send)
                if model.running {
                    Button("Stop") { model.stop() }
                } else {
                    Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)) }
                        .buttonStyle(.ember)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack {
                Text("Claude Haiku 5.5 · denne samtale ca. \(AIPricing.text(model.costDKK))"
                     + (model.lastCostDKK > 0 ? " · sidste opgave \(AIPricing.text(model.lastCostDKK))" : ""))
                    .font(.system(size: 10)).foregroundColor(.mist.opacity(0.4))
                Spacer()
                if !model.lines.isEmpty {
                    Button("Ny samtale") { model.clear() }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.mist.opacity(0.5))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: 868)
        .frame(maxWidth: .infinity)
    }

    func send() {
        let t = input
        input = ""
        model.send(t)
    }
}
