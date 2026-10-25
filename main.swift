// MODULR – finder "falske" 320 kbps-filer ved at analysere selve lyden.
//
// En MP3-encoder fjerner altid de højeste frekvenser, og grænsen afhænger af bitraten:
//   128 kbps ≈ 16–17 kHz   192 kbps ≈ 18,5–19 kHz   256 kbps ≈ 19,5 kHz   320 kbps ≈ 20–20,5 kHz
// Hvis en fil er konverteret fra 128 til 320, er den "kant" stadig ved ~16–17 kHz.
// Appen måler hvor kanten ligger og sammenligner med den bitrate filen påstår at have.

import SwiftUI
import AppKit
import AVFoundation
import AudioToolbox
import Accelerate
import UniformTypeIdentifiers

// MARK: - Analyse

enum Verdict {
    case ok, suspicious, fake

    var icon: String {
        switch self {
        case .ok: return "✅"
        case .suspicious: return "⚠️"
        case .fake: return "❌"
        }
    }

    var word: String {
        switch self {
        case .ok: return "Ægte"
        case .suspicious: return "Mistænkelig"
        case .fake: return "Fake"
        }
    }
}

struct Tier {
    let kbps: Int        // 9999 = fuld båndbredde (lossless-niveau)
    let label: String
}

struct AnalysisResult {
    let sampleRate: Double
    let statedKbps: Int?
    let cutoffHz: Double?
    let tier: Tier
    let verdict: Verdict
    let verdictText: String
    let spectrogram: CGImage?
    let artist: String?
    let title: String?
}

enum AnalyzerError: LocalizedError {
    case tooShort, unreadable, silent

    var errorDescription: String? {
        switch self {
        case .tooShort: return "Filen er for kort"
        case .unreadable: return "Filen kunne ikke læses"
        case .silent: return "Filen er stille"
        }
    }
}

enum Analyzer {
    static let n = 8192
    static let log2n: vDSP_Length = 13
    static let frameCount = 300
    static let bandHz = 100.0
    static let losslessExtensions: Set<String> = ["wav", "aif", "aiff", "flac", "alac", "caf"]

    static func analyze(url: URL) throws -> AnalysisResult {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let channels = max(1, Int(format.channelCount))
        let length = file.length
        guard length > AVAudioFramePosition(n * 4) else { throw AnalyzerError.tooShort }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else {
            throw AnalyzerError.unreadable
        }
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { throw AnalyzerError.unreadable }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = n / 2
        let nyquist = sr / 2
        let bandCount = Int(nyquist / bandHz)
        let binHz = sr / Double(n)

        var bandStart = [Int]()
        var bandEnd = [Int]()
        for b in 0..<bandCount {
            let s = min(half - 1, Int(Double(b) * bandHz / binHz))
            let e = max(s + 1, min(half, Int(Double(b + 1) * bandHz / binHz)))
            bandStart.append(s)
            bandEnd.append(e)
        }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))

        var accumulated = [Double](repeating: 0, count: half)
        var counted = 0
        var columns = [[Float]]()
        var mono = [Float](repeating: 0, count: n)
        var windowed = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        let start = AVAudioFramePosition(Double(length) * 0.05)
        let end = AVAudioFramePosition(Double(length) * 0.95) - AVAudioFramePosition(n)

        for i in 0..<frameCount {
            let pos = start + (end - start) * AVAudioFramePosition(i) / AVAudioFramePosition(frameCount - 1)
            file.framePosition = pos
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(n))
            } catch {
                continue
            }
            let got = min(n, Int(buffer.frameLength))
            guard got > 0, let data = buffer.floatChannelData else { continue }

            for j in 0..<n { mono[j] = 0 }
            for c in 0..<channels {
                let ch = data[c]
                for j in 0..<got { mono[j] += ch[j] }
            }
            let scale = 1.0 / Float(channels)
            var sumSquares: Float = 0
            for j in 0..<n {
                let v = mono[j] * scale
                sumSquares += v * v
                windowed[j] = v * window[j]
            }
            let rms = (sumSquares / Float(got)).squareRoot()

            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mags.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }
            mags[0] = 0 // DC/Nyquist-pakning fra zrip – irrelevant her

            var column = [Float](repeating: 0, count: bandCount)
            for b in 0..<bandCount {
                var sum: Float = 0
                for k in bandStart[b]..<bandEnd[b] { sum += mags[k] }
                let meanPower = sum / Float(bandEnd[b] - bandStart[b])
                column[b] = 10 * log10(meanPower + 1e-20)
            }
            columns.append(column)

            if rms > 1e-3 {
                for k in 0..<half { accumulated[k] += Double(mags[k]) }
                counted += 1
            }
        }

        guard counted > 0 else { throw AnalyzerError.silent }

        // Gennemsnitligt spektrum i 100 Hz-bånd (dB)
        var bandDB = [Double](repeating: -200, count: bandCount)
        for b in 0..<bandCount {
            var sum = 0.0
            for k in bandStart[b]..<bandEnd[b] { sum += accumulated[k] }
            let meanPower = sum / Double(bandEnd[b] - bandStart[b]) / Double(counted)
            bandDB[b] = 10 * log10(meanPower + 1e-30)
        }

        let cutoff = findCutoff(bandDB: bandDB)
        let tier = tierFor(cutoff: cutoff)
        let stated = statedBitrate(url: url)
        let lossless = losslessExtensions.contains(url.pathExtension.lowercased()) || (stated ?? 0) >= 600
        let (verdict, text) = judge(tier: tier, stated: stated, lossless: lossless)
        let tags = readTags(url: url)

        return AnalysisResult(
            sampleRate: sr,
            statedKbps: stated,
            cutoffHz: cutoff,
            tier: tier,
            verdict: verdict,
            verdictText: text,
            spectrogram: makeSpectrogram(columns: columns, bandCount: bandCount),
            artist: tags.artist,
            title: tags.title
        )
    }

    /// Kunstner og titel: først fra filens tags, ellers gættet ud fra filnavnet ("Kunstner - Titel").
    static func readTags(url: URL) -> (artist: String?, title: String?) {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        var artist: String?
        var title: String?
        var fileID: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fid = fileID {
            var dict: Unmanaged<CFDictionary>?
            var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
            if AudioFileGetProperty(fid, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
               let info = dict?.takeRetainedValue() as? [String: Any] {
                artist = clean(info["artist"] as? String)
                title = clean(info["title"] as? String)
            }
            AudioFileClose(fid)
        }
        if artist == nil || title == nil {
            var base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            if let r = base.range(of: #"^\s*(\d{1,3}\s*[-.)]\s*|\d{2,3}\s+)"#, options: .regularExpression) {
                base.removeSubrange(r)
            }
            let parts = base.components(separatedBy: " - ")
            if parts.count >= 2 {
                artist = artist ?? clean(parts[0])
                title = title ?? clean(parts.dropFirst().joined(separator: " - "))
            } else {
                title = title ?? clean(base)
            }
        }
        return (artist, title)
    }

    /// Finder den skarpe "kant" hvor encoderen har skåret diskanten af.
    static func findCutoff(bandDB: [Double]) -> Double? {
        let nb = bandDB.count
        func mean(_ a: Int, _ b: Int) -> Double {
            let lo = max(0, a), hi = min(nb, b)
            guard hi > lo else { return -200 }
            var s = 0.0
            for i in lo..<hi { s += bandDB[i] }
            return s / Double(hi - lo)
        }
        let first = Int(8000 / bandHz)
        guard nb > first + 4 else { return nil }
        var best = -1
        var bestDrop = 0.0
        for b in first..<(nb - 3) {
            let drop = mean(b - 6, b - 1) - mean(b + 1, b + 6)
            if drop > bestDrop {
                bestDrop = drop
                best = b
            }
        }
        guard best >= 0, bestDrop >= 15 else { return nil }
        let above = mean(best + 2, min(nb - 2, best + 30))
        let below = mean(best - 15, best - 2)
        guard below - above >= 20 else { return nil }
        return Double(best) * bandHz
    }

    static func tierFor(cutoff: Double?) -> Tier {
        guard let c = cutoff, c < 21000 else { return Tier(kbps: 9999, label: "Fuld båndbredde") }
        switch c {
        case 19900...: return Tier(kbps: 320, label: "320 kbps")
        case 19300...: return Tier(kbps: 256, label: "256 kbps")
        case 18300...: return Tier(kbps: 192, label: "192 kbps")
        case 17300...: return Tier(kbps: 160, label: "160 kbps")
        case 15900...: return Tier(kbps: 128, label: "128 kbps")
        case 14000...: return Tier(kbps: 96, label: "96 kbps")
        default: return Tier(kbps: 64, label: "≤ 64 kbps")
        }
    }

    static func judge(tier: Tier, stated: Int?, lossless: Bool) -> (Verdict, String) {
        if lossless {
            if tier.kbps >= 9999 { return (.ok, "Ægte lossless – lyd i hele frekvensområdet") }
            if tier.kbps >= 320 {
                return (.suspicious, "Lossless-fil, men lyden stopper ved ca. 20 kHz – kan være lavet ud fra en 320 kbps MP3")
            }
            return (.fake, "Falsk lossless – lavet ud fra en MP3 på ca. \(tier.kbps) kbps")
        }
        guard let stated, stated > 0 else { return (.ok, "Målt kvalitet: \(tier.label)") }
        if tier.kbps >= 320 || tier.kbps >= min(stated, 320) - 40 {
            return (.ok, "Ægte – lyden passer til \(stated) kbps")
        }
        if Double(tier.kbps) <= Double(stated) * 0.7 {
            return (.fake, "Fake – filen siger \(stated) kbps, men lyden svarer til ca. \(tier.kbps) kbps")
        }
        return (.suspicious, "Mistænkelig – filen siger \(stated) kbps, men lyden ligner ca. \(tier.kbps) kbps")
    }

    /// Den bitrate filen selv påstår at have (fra filens header).
    static func statedBitrate(url: URL) -> Int? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fid = fileID else { return nil }
        defer { AudioFileClose(fid) }
        var bitRate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(fid, kAudioFilePropertyBitRate, &size, &bitRate) == noErr, bitRate > 0 else { return nil }
        return Int((Double(bitRate) / 1000).rounded())
    }

    static func makeSpectrogram(columns: [[Float]], bandCount: Int) -> CGImage? {
        let w = columns.count
        let h = bandCount
        guard w > 0, h > 0 else { return nil }
        var maxDB: Float = -300
        for col in columns { for v in col where v > maxDB { maxDB = v } }
        let minDB = maxDB - 90

        // MODULR-paletten: Void → Ember → Amber → Mist
        let stops: [(Float, Float, Float, Float)] = [
            (0.00, 10, 10, 10),
            (0.35, 80, 28, 0),
            (0.60, 255, 107, 0),
            (0.82, 255, 209, 102),
            (1.00, 245, 245, 245),
        ]
        func color(_ t: Float) -> (UInt8, UInt8, UInt8) {
            let x = min(1, max(0, t))
            for i in 1..<stops.count where x <= stops[i].0 {
                let a = stops[i - 1], b = stops[i]
                let f = (x - a.0) / (b.0 - a.0)
                return (UInt8(a.1 + (b.1 - a.1) * f), UInt8(a.2 + (b.2 - a.2) * f), UInt8(a.3 + (b.3 - a.3) * f))
            }
            return (255, 245, 180)
        }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for x in 0..<w {
            let col = columns[x]
            for y in 0..<h {
                let band = h - 1 - y
                let t = (col[band] - minDB) / (maxDB - minDB)
                let (r, g, b) = color(t)
                let i = (y * w + x) * 4
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
                pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}

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

final class AppModel: ObservableObject {
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

struct BrandHeader: View {
    let tool: String
    private let logo: NSImage? = Bundle.main.image(forResource: "logo")

    var body: some View {
        HStack(spacing: 14) {
            if let logo {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 38)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("MODULR")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(5)
                    .foregroundColor(.mist)
                Text("YOUR TOOLS. ONE PLATFORM.")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(3)
                    .foregroundColor(.mist.opacity(0.55))
            }
            Spacer()
            Text(tool.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2)
                .foregroundColor(.ember)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(Color.ember.opacity(0.6), lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.void)
    }
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
            BrandHeader(tool: "Bitrate-tjek")
            Divider()
            HStack(spacing: 12) {
                Button("Tilføj filer eller mapper…") { openPanel() }
                    .buttonStyle(.borderedProminent)
                Picker("", selection: $filter) {
                    Text("Alle").tag(Filter.all)
                    Text("Kun fakes og mistænkelige").tag(Filter.problems)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Spacer()
                if !model.rows.isEmpty {
                    Text("\(model.doneCount)/\(model.rows.count) analyseret · \(model.fakeCount) fake · \(model.suspiciousCount) mistænkelige")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Eksportér CSV…") { exportCSV() }
                    Button("Ryd") { model.clear() }
                }
            }
            .padding(10)
            .background(Color.graphite)

            Divider()

            if model.rows.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 54))
                        .foregroundColor(.ember)
                    Text("Træk dine filer eller mapper herind")
                        .font(.title2)
                    Text("Appen lytter til selve lyden og afslører filer, der er opkonverteret fra lav bitrate.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dropTargeted ? Color.ember.opacity(0.12) : Color.void)
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

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private func set(_ s: Status) {
        DispatchQueue.main.async { self.status = s }
    }

    func check(manual: Bool = false) {
        if case .working = status { return }
        if manual { set(.checking) }
        guard let url = URL(string: "https://raw.githubusercontent.com/\(Self.owner)/\(Self.repo)/\(Self.branch)/VERSION") else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error == nil, code == 200, let data, let text = String(data: data, encoding: .utf8) else {
                self.set(manual ? .failed("Kunne ikke tjekke for opdateringer. Tjek internetforbindelsen.") : .idle)
                return
            }
            let latest = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if latest.compare(self.currentVersion, options: .numeric) == .orderedDescending {
                self.set(.available(latest))
            } else {
                self.set(manual ? .upToDate : .idle)
            }
        }.resume()
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
                Text("🎉 Ny version \(version) er klar (du har \(updater.currentVersion)).")
                Spacer()
                Button("Senere") { updater.status = .idle }
                Button("Opdatér nu") { updater.install() }
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
        VStack(spacing: 0) {
            HStack(spacing: 10) { content() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ember.opacity(0.18))
            Divider()
        }
    }
}

// MARK: - App

@main
struct ModulrApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup("MODULR") {
            VStack(spacing: 0) {
                UpdateBanner()
                ContentView()
            }
            .environmentObject(model)
            .environmentObject(updater)
            .frame(minWidth: 1100, minHeight: 700)
            .background(Color.void)
            .preferredColorScheme(.dark)
            .tint(Color.ember)
            .onAppear { updater.check() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Søg efter opdateringer…") { updater.check(manual: true) }
            }
        }
    }
}
