// MODULR – sørger for at det der lægges på USB'en, kan spilles på CDJ'en.
// CDJ-3000 spiller MP3, AAC/M4A, WAV, AIFF, FLAC og ALAC – men kun 16/24 bit og 44,1–96 kHz, og WAV skal
// være almindelig PCM. Ellers står der "unsupported". Filer der ikke passer, laves om til 24-bit WAV
// (originalen røres ikke – kun kopien på stikket). Filer med forkert endelse (fx en ".mp3" der i virkeligheden
// er AAC) får den rigtige endelse, så CDJ'en bruger den rigtige afkoder.

import Foundation
import AVFoundation

enum UsbCompat {
    enum Container: String { case wav, aiff, aifc, flac, mp3, m4a, unknown }

    struct Probe {
        var container: Container
        var wavFormatTag: Int?      // 1 = PCM, 3 = float, 0xFFFE = extensible
        var bits: Int?
        var sampleRate: Double?
    }

    /// Læser starten af filen og finder ud af hvad den reelt er.
    static func probe(_ url: URL) -> Probe {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Probe(container: .unknown) }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 65536)) ?? Data()
        let b = [UInt8](d)
        func ascii(_ at: Int, _ n: Int) -> String {
            guard at + n <= b.count else { return "" }
            return String(bytes: b[at..<(at + n)], encoding: .ascii) ?? ""
        }
        func le16(_ at: Int) -> Int {
            guard at + 2 <= b.count else { return 0 }
            let lo: Int = Int(b[at]), hi: Int = Int(b[at + 1])
            return lo + hi * 256
        }
        func le32(_ at: Int) -> Int {
            guard at + 4 <= b.count else { return 0 }
            let lo: Int = le16(at), hi: Int = le16(at + 2)
            return lo + hi * 65536
        }
        if ascii(0, 4) == "RIFF" && ascii(8, 4) == "WAVE" {
            var p = 12
            while p + 8 <= b.count {
                let id = ascii(p, 4), size = le32(p + 4)
                if id == "fmt " {
                    var tag = le16(p + 8)
                    let sr = Double(le32(p + 12))
                    let bits = le16(p + 22)
                    if tag == 0xFFFE, size >= 40 { tag = le16(p + 8 + 24) == 3 ? 0xFFFE + 3 : 0xFFFE }   // extensible: float eller PCM
                    return Probe(container: .wav, wavFormatTag: tag, bits: bits, sampleRate: sr)
                }
                p += 8 + size + (size & 1)
            }
            return Probe(container: .wav)
        }
        if ascii(0, 4) == "FORM" {
            return Probe(container: ascii(8, 4) == "AIFC" ? .aifc : .aiff)
        }
        if ascii(0, 4) == "fLaC" { return Probe(container: .flac) }
        if ascii(4, 4) == "ftyp" { return Probe(container: .m4a) }
        if ascii(0, 3) == "ID3" || (b.count > 1 && b[0] == 0xFF && (b[1] & 0xE0) == 0xE0) { return Probe(container: .mp3) }
        return Probe(container: .unknown)
    }

    struct Result {
        var path: String          // filen der skal kopieres
        var note: String?         // hvad der blev gjort (vises i loggen)
        var sampleRate: Int?
        var depth: Int?
    }

    /// Den fil der skal lægges på USB'en for denne sang – originalen, eller en CDJ-venlig kopi i `tempDir`.
    static func prepare(_ t: LibTrack, tempDir: URL) -> Result {
        let src = t.url
        let ext = src.pathExtension.lowercased()
        let p = probe(src)
        let base = src.deletingPathExtension().lastPathComponent
        let dir = tempDir.appendingPathComponent(t.id.uuidString, isDirectory: true)

        // 1) Lydformater CDJ'en ikke kan: 32-bit/float, over 96 kHz, AIFF-C → 24-bit WAV
        var convert = false
        var why = ""
        switch p.container {
        case .wav:
            if let tag = p.wavFormatTag, tag != 1 && tag != 0xFFFE { convert = true; why = "float/usædvanlig WAV" }
            if let tag = p.wavFormatTag, tag == 0xFFFE + 3 { convert = true; why = "32-bit float WAV" }
            if (p.bits ?? 16) > 24 { convert = true; why = "\(p.bits ?? 32)-bit WAV" }
            if (p.sampleRate ?? 44100) > 96000 { convert = true; why = "\(Int((p.sampleRate ?? 0) / 1000)) kHz" }
        case .aifc:
            convert = true; why = "AIFF-C"
        case .aiff, .flac, .m4a:
            if (t.bitDepth ?? 16) > 24 { convert = true; why = "\(t.bitDepth ?? 32)-bit" }
            if (t.sampleRate ?? 44100) > 96000 { convert = true; why = "\(Int((t.sampleRate ?? 0) / 1000)) kHz" }
        case .mp3:
            break
        case .unknown:
            if !["mp3", "m4a", "aac", "mp4"].contains(ext) { convert = true; why = "ukendt format" }
        }
        if convert {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent(base + ".wav")
            if let sr = toWav24(src, out: out) {
                return Result(path: out.path, note: "Lavet om til 24-bit WAV (\(why)) – CDJ'en kan ikke spille originalen", sampleRate: sr, depth: 24)
            }
            return Result(path: src.path, note: "⚠︎ Kunne ikke laves om (\(why)) – CDJ'en kan måske ikke spille den")
        }

        // 2) Forkert endelse: kopiér med den rigtige, så CDJ'en vælger den rigtige afkoder
        let right: String? = {
            switch p.container {
            case .mp3: return ext == "mp3" ? nil : "mp3"
            case .m4a: return ["m4a", "aac", "mp4", "alac"].contains(ext) ? nil : "m4a"
            case .wav: return ext == "wav" ? nil : "wav"
            case .aiff: return ["aif", "aiff"].contains(ext) ? nil : "aiff"
            case .flac: return ext == "flac" ? nil : "flac"
            default: return nil
            }
        }()
        if let right {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let out = dir.appendingPathComponent(base + "." + right)
            try? FileManager.default.removeItem(at: out)
            if (try? FileManager.default.linkItem(at: src, to: out)) != nil || (try? FileManager.default.copyItem(at: src, to: out)) != nil {
                return Result(path: out.path, note: "Endelsen rettet: .\(ext) → .\(right) (filen er i virkeligheden \(right.uppercased()))")
            }
        }
        return Result(path: src.path)
    }

    /// Afkoder og skriver almindelig 24-bit PCM-WAV (over 96 kHz → 48 kHz). Returnerer samplefrekvensen.
    static func toWav24(_ src: URL, out: URL) -> Int? {
        guard let file = try? AVAudioFile(forReading: src) else { return nil }
        let fmt = file.processingFormat
        let chans = Int(fmt.channelCount)
        guard chans > 0, file.length > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buf) } catch { if buf.frameLength == 0 { return nil } }
        var rate = fmt.sampleRate
        var source = buf
        if rate > 96000 {
            guard let target = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: fmt.channelCount),
                  let conv = AVAudioConverter(from: fmt, to: target) else { return nil }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 48000 / rate) + 4096
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
            var fed = false
            var err: NSError?
            _ = conv.convert(to: outBuf, error: &err) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            if err != nil || outBuf.frameLength == 0 { return nil }
            source = outBuf
            rate = 48000
        }
        guard let data = source.floatChannelData else { return nil }
        let n = Int(source.frameLength)
        var channels = [[Float]]()
        for c in 0..<min(2, chans) { channels.append(Array(UnsafeBufferPointer(start: data[c], count: n))) }
        do {
            try Loudness.wav24(channels, sr: rate).write(to: out)
            return Int(rate)
        } catch {
            return nil
        }
    }
}
