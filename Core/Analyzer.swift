// MODULR – kerne: lydanalyse (spektral cutoff, kvalitet, tags).
// Bruges af både appen og testene.

import Foundation
import AVFoundation
import AudioToolbox
import Accelerate
import CoreGraphics

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


// MARK: - Format, kvalitet og tags

extension Analyzer {
    /// Containerens tekniske data (codec, bitrate, samplerate, bitdybde, kanaler).
    static func formatInfo(url: URL) -> FormatInfo {
        let ext = url.pathExtension.uppercased()
        var codec = ext
        var sampleRate = 44100.0
        var bitDepth: Int?
        var channels = 2

        var fileID: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fid = fileID {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            if AudioFileGetProperty(fid, kAudioFilePropertyDataFormat, &size, &asbd) == noErr {
                sampleRate = asbd.mSampleRate
                channels = Int(asbd.mChannelsPerFrame)
                switch asbd.mFormatID {
                case kAudioFormatMPEGLayer3: codec = "MP3"
                case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: codec = "AAC"
                case kAudioFormatFLAC: codec = "FLAC"
                case kAudioFormatAppleLossless: codec = "ALAC"
                case kAudioFormatLinearPCM:
                    codec = (ext == "AIF" || ext == "AIFF") ? "AIFF" : (ext == "WAV" ? "WAV" : "PCM")
                    bitDepth = Int(asbd.mBitsPerChannel)
                default: break
                }
                if codec == "FLAC" || codec == "ALAC" {
                    // Bitdybden ligger i formatflagene for FLAC/ALAC
                    switch asbd.mFormatFlags {
                    case 1: bitDepth = 16
                    case 2: bitDepth = 20
                    case 3: bitDepth = 24
                    case 4: bitDepth = 32
                    default: bitDepth = nil
                    }
                }
            }
            AudioFileClose(fid)
        }
        return FormatInfo(codec: codec, container: ext, nominalKbps: statedBitrate(url: url),
                          sampleRate: sampleRate, bitDepth: bitDepth, channels: channels)
    }

    /// Kvalitetsrapport: nominelle data + målt reel kvalitet (spektral cutoff).
    static func quality(url: URL) throws -> (QualityReport, AnalysisResult) {
        let analysis = try analyze(url: url)
        let report = Quality.make(format: formatInfo(url: url), cutoffHz: analysis.cutoffHz,
                                  tierKbps: analysis.tier.kbps, tierLabel: analysis.tier.label)
        return (report, analysis)
    }

    /// Alle tekst-tags Core Audio kan læse (artist, title, album, genre, year, …).
    static func readAllTags(url: URL) -> [String: String] {
        var out = [String: String]()
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fid = fileID else { return out }
        defer { AudioFileClose(fid) }
        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        if AudioFileGetProperty(fid, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
           let info = dict?.takeRetainedValue() as? [String: Any] {
            for (k, v) in info {
                if let s = v as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { out[k] = s }
            }
        }
        return out
    }

    /// Varighed i sekunder.
    static func duration(url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// Klip et stykke af filen ud som mono 16-bit WAV (til genkendelsestjenester).
    static func writeSnippet(from url: URL, seconds: Double = 15, startFraction: Double = 0.3) throws -> URL {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let total = file.length
        let count = AVAudioFrameCount(min(Double(total), seconds * sr))
        file.framePosition = max(0, min(total - AVAudioFramePosition(count), AVAudioFramePosition(Double(total) * startFraction)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: count) else {
            throw AnalyzerError.unreadable
        }
        try file.read(into: buffer, frameCount: count)
        let n = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        guard let src = buffer.floatChannelData, let dst = mono.floatChannelData else { throw AnalyzerError.unreadable }
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<channels { s += src[c][i] }
            dst[0][i] = s / Float(max(1, channels))
        }
        mono.frameLength = AVAudioFrameCount(n)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("modulr-snippet-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let outFile = try AVAudioFile(forWriting: out, settings: settings)
        try outFile.write(from: mono)
        return out
    }
}
