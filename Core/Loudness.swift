// MODULR – kerne: lydstyrke som i Platinum Notes.
//  • Måling: ITU-R BS.1770-4 / EBU R128 integreret lydstyrke (LUFS) med K-vægtning og gating.
//  • WAV/AIFF: gain + transparent look-ahead-limiter (loft −1 dBFS), skrevet som 24-bit i samme format.
//  • MP3: tabsfri ændring af "global_gain" i hver ramme (1,5 dB pr. trin) – ingen genkodning (som mp3gain).
// Testet i Python mod pyloudnorm (±0,05 dB) og ffmpeg's ebur128 (MP3-trin præcist 1,5 dB).

import Foundation
import AVFoundation
import Accelerate

struct LoudnessMeasurement: Equatable {
    var lufs: Double
    var peakDB: Double
}

struct LoudnessFixResult: Equatable {
    var before: Double
    var after: Double
    var gainDB: Double
    var limitingDB: Double
    var note: String
    var clipsRepaired: Int = 0
}

/// Overblik over en fil til før/efter-visningen: top pr. kolonne (0–255) og om kolonnen har klippede toppe.
struct LoudnessEnvelope: Codable, Equatable {
    var peaks: [UInt8]
    var clips: [Bool]

    var data: Data { Data(peaks + clips.map { $0 ? 1 : 0 }) }

    init(peaks: [UInt8], clips: [Bool]) {
        self.peaks = peaks
        self.clips = clips
    }

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2, b.count % 2 == 0 else { return nil }
        let n = b.count / 2
        peaks = Array(b[0..<n])
        clips = b[n...].map { $0 != 0 }
    }
}

enum LoudnessError: LocalizedError {
    case unsupported(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let f): return "\(f) kan ikke rettes automatisk (WAV, AIFF og MP3 kan)"
        case .failed(let m): return m
        }
    }
}

enum Loudness {
    static let ceilingDB = -1.0          // højeste top efter limiteren
    static let mp3CeilingDB = -0.3       // MP3 har ingen limiter – kun løft så langt der er plads
    static let defaultTarget = -9.0      // klubniveau (justerbart −6 … −12 i Indstillinger)
    static let maxLimitingDB = 5.0       // mere end det, og lyden begynder at pumpe – så hellere lidt lavere

    // MARK: Indlæsning

    /// Hele filen som flydende tal, én række pr. kanal.
    static func read(url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let n = AVAudioFrameCount(file.length)
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else {
            throw LoudnessError.failed("Filen kunne ikke læses")
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw LoudnessError.failed("Filen kunne ikke læses") }
        let frames = Int(buffer.frameLength)
        let chans = min(2, Int(format.channelCount))
        var out = [[Float]]()
        for c in 0..<chans { out.append(Array(UnsafeBufferPointer(start: data[c], count: frames))) }
        return (out, format.sampleRate)
    }

    // MARK: Måling (BS.1770-4)

    /// K-vægtningens to biquads (samme formler som libebur128/pyloudnorm), som vDSP-koefficienter.
    static func kWeighting(_ sr: Double) -> [Double] {
        var f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / sr)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let s1: [Double] = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                            2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sr)
        a0 = 1 + k / q + k * k
        let s2: [Double] = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return s1 + s2
    }

    static func kFilter(_ x: [Float], sr: Double) -> [Float] {
        let coeffs = kWeighting(sr)
        guard let setup = vDSP_biquad_CreateSetup(coeffs, 2) else { return x }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * 2 + 2)
        var y = [Float](repeating: 0, count: x.count)
        vDSP_biquad(setup, &delay, x, 1, &y, 1, vDSP_Length(x.count))
        return y
    }

    static func integratedLUFS(_ channels: [[Float]], sr: Double) -> Double {
        guard let first = channels.first, first.count > Int(sr * 0.4) else { return -70 }
        let seg = max(1, Int(sr * 0.1))              // 100 ms
        let nSeg = first.count / seg
        var segPower = [Double](repeating: 0, count: nSeg)
        for ch in channels {
            let f = kFilter(ch, sr: sr)
            f.withUnsafeBufferPointer { fp in
                for s in 0..<nSeg {
                    var ms: Float = 0
                    vDSP_measqv(fp.baseAddress! + s * seg, 1, &ms, vDSP_Length(seg))
                    segPower[s] += Double(ms)
                }
            }
        }
        // 400 ms-blokke med 75 % overlap = 4 segmenter
        guard nSeg >= 4 else { return -70 }
        var blocks = [Double]()
        blocks.reserveCapacity(nSeg)
        for s in 0...(nSeg - 4) {
            let z: Double = (segPower[s] + segPower[s + 1] + segPower[s + 2] + segPower[s + 3]) / 4
            blocks.append(z)
        }
        func loud(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let absGated = blocks.filter { loud($0) > -70 }
        guard !absGated.isEmpty else { return -70 }
        let relGate = loud(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { loud($0) > relGate }
        guard !gated.isEmpty else { return -70 }
        return loud(gated.reduce(0, +) / Double(gated.count))
    }

    static func peakDB(_ channels: [[Float]]) -> Double {
        var peak: Float = 0
        for ch in channels {
            var m: Float = 0
            vDSP_maxmgv(ch, 1, &m, vDSP_Length(ch.count))
            peak = max(peak, m)
        }
        return 20 * log10(Double(max(peak, 1e-9)))
    }

    static func measure(url: URL) throws -> LoudnessMeasurement {
        let (ch, sr) = try read(url: url)
        return LoudnessMeasurement(lufs: integratedLUFS(ch, sr: sr), peakDB: peakDB(ch))
    }

    // MARK: Klippede toppe

    /// Niveauet en fil er klippet ved (højeste top), hvis toppen ligger over −1 dBFS.
    static func clipLevel(_ channels: [[Float]]) -> Float? {
        var m: Float = 0
        for ch in channels {
            var v: Float = 0
            vDSP_maxmgv(ch, 1, &v, vDSP_Length(ch.count))
            m = max(m, v)
        }
        return m >= 0.89 ? m * 0.999 : nil
    }

    /// Antal klippede toppe: mindst 2 samples i træk på klip-niveauet.
    static func countClips(_ channels: [[Float]]) -> Int {
        guard let thr = clipLevel(channels) else { return 0 }
        var runs = 0
        for ch in channels {
            var len = 0
            for v in ch {
                if abs(v) >= thr { len += 1 } else {
                    if len >= 2 { runs += 1 }
                    len = 0
                }
            }
            if len >= 2 { runs += 1 }
        }
        return runs
    }

    /// Genskaber klippede toppe (kubisk kurve hen over det flade stykke, som før det blev klippet).
    /// Toppen bliver højere end før – gain og limiter tager sig af det bagefter. Returnerer antal rettede.
    static func declip(_ channels: inout [[Float]]) -> Int {
        guard let thr = clipLevel(channels) else { return 0 }
        var fixed = 0
        for c in channels.indices {
            var x = channels[c]
            let n = x.count
            var i = 2
            while i < n - 2 {
                guard abs(x[i]) >= thr else { i += 1; continue }
                let sign: Float = x[i] >= 0 ? 1 : -1
                var b = i
                while b + 1 < n && abs(x[b + 1]) >= thr && (x[b + 1] >= 0 ? 1 : -1) == sign { b += 1 }
                let a = i
                if b > a, b - a < 400, a >= 2, b + 2 < n {
                    let p0 = x[a - 1], p1 = x[b + 1]
                    let m0 = x[a - 1] - x[a - 2], m1 = x[b + 2] - x[b + 1]
                    let len = Float(b - a + 2)
                    for k in a...b {
                        let t = Float(k - (a - 1)) / len
                        let t2 = t * t, t3 = t2 * t
                        let h00 = 2 * t3 - 3 * t2 + 1, h10 = t3 - 2 * t2 + t
                        let h01 = -2 * t3 + 3 * t2, h11 = t3 - t2
                        let v = h00 * p0 + h10 * len * m0 + h01 * p1 + h11 * len * m1
                        x[k] = sign * max(abs(v), thr)
                    }
                    fixed += 1
                }
                i = b + 1
            }
            channels[c] = x
        }
        return fixed
    }

    /// Overblik til før/efter-visningen (som Platinum Notes): 600 kolonner.
    static func envelope(_ channels: [[Float]], columns: Int = 600) -> LoudnessEnvelope {
        let n = channels.first?.count ?? 0
        guard n > 0 else { return LoudnessEnvelope(peaks: [], clips: []) }
        let thr = clipLevel(channels) ?? 2
        var peaks = [UInt8](repeating: 0, count: columns)
        var clips = [Bool](repeating: false, count: columns)
        for col in 0..<columns {
            let a = col * n / columns
            let b = max(a + 1, (col + 1) * n / columns)
            var m: Float = 0
            var run = 0
            var clipped = false
            for ch in channels {
                run = 0
                for i in a..<min(b, n) {
                    let v = abs(ch[i])
                    if v > m { m = v }
                    if v >= thr { run += 1; if run >= 2 { clipped = true } } else { run = 0 }
                }
            }
            peaks[col] = UInt8(min(255, (min(m, 1) * 255).rounded()))
            clips[col] = clipped
        }
        return LoudnessEnvelope(peaks: peaks, clips: clips)
    }

    // MARK: Limiter

    /// Gain + look-ahead-limiter (5 ms frem, 120 ms slip). Returnerer de nye kanaler og den største dæmpning (dB).
    static func applyGainAndLimit(_ channels: [[Float]], sr: Double, gainDB: Double, ceilingDB: Double = Loudness.ceilingDB) -> ([[Float]], Double) {
        let n = channels.first?.count ?? 0
        guard n > 0 else { return (channels, 0) }
        let g = Float(pow(10, gainDB / 20))
        let ceil = Float(pow(10, ceilingDB / 20))
        // Krævet dæmpning pr. sample
        var req = [Float](repeating: 1, count: n)
        for ch in channels {
            for i in 0..<n {
                let a = abs(ch[i] * g)
                if a > ceil {
                    let r = ceil / a
                    if r < req[i] { req[i] = r }
                }
            }
        }
        let look = max(1, Int(sr * 0.005))
        // Glidende minimum fremad (lookahead) med deque
        var mn = [Float](repeating: 1, count: n)
        var dq = [Int]()
        dq.reserveCapacity(look + 2)
        var head = 0
        let total = n + look
        for i in 0..<total {
            let v: Float = i < n ? req[i] : 1
            while dq.count > head, (dq.last! < n ? req[dq.last!] : 1) >= v { dq.removeLast() }
            dq.append(i)
            let j = i - look
            if j >= 0 {
                while dq[head] < j { head += 1 }
                let idx = dq[head]
                mn[j] = idx < n ? req[idx] : 1
            }
            if head > 4096 { dq.removeFirst(head); head = 0 }
        }
        // Blødt angreb (gennemsnit over lookahead) og eksponentielt slip
        var att = [Float](repeating: 1, count: n)
        var run: Float = Float(look - 1)       // forudgående 1-taller
        var window = [Float](repeating: 1, count: look)
        var wi = 0
        for i in 0..<n {
            run += mn[i] - window[wi]
            window[wi] = mn[i]
            wi = (wi + 1) % look
            att[i] = min(run / Float(look), mn[i])
        }
        let rel = Float(exp(-1 / (sr * 0.12)))
        var cur: Float = 1
        var minGain: Float = 1
        var gains = [Float](repeating: 1, count: n)
        for i in 0..<n {
            cur = att[i] < cur ? att[i] : att[i] + (cur - att[i]) * rel
            gains[i] = cur
            if cur < minGain { minGain = cur }
        }
        var out = [[Float]]()
        for ch in channels {
            var y = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let v = ch[i] * g * gains[i]
                y[i] = max(-ceil, min(ceil, v))
            }
            out.append(y)
        }
        return (out, 20 * log10(Double(max(minGain, 1e-9))))
    }

    /// Finder den gain der rammer målet, uden mere limiting end `maxLimitingDB`.
    static func normalizePCM(_ input: [[Float]], sr: Double, target: Double, maxLimitingDB: Double,
                             repairClips: Bool = true) -> ([[Float]], LoudnessFixResult) {
        let before = integratedLUFS(input, sr: sr)
        var channels = input
        let repaired = repairClips ? declip(&channels) : 0
        var gain = target - before
        var best = channels
        var got = false
        var after = before
        var limiting = 0.0
        for _ in 0..<5 {
            let (y, gr) = applyGainAndLimit(channels, sr: sr, gainDB: gain)
            if -gr > maxLimitingDB + 0.05 {
                // For meget limiting: skru ned, så dæmpningen holdes på loftet
                gain -= (-gr - maxLimitingDB)
                continue
            }
            best = y
            got = true
            limiting = -gr
            after = integratedLUFS(y, sr: sr)
            if abs(after - target) < 0.15 { break }
            gain += target - after
        }
        if !got {
            let (y, gr) = applyGainAndLimit(channels, sr: sr, gainDB: gain)
            best = y
            limiting = -gr
            after = integratedLUFS(y, sr: sr)
        }
        var note = String(format: "%.1f → %.1f LUFS", before, after)
        if repaired > 0 { note += " · \(repaired) klippede toppe rettet" }
        if after < target - 0.5 { note += String(format: " (holdt %.0f dB under målet for ikke at maste lyden)", target - after) }
        return (best, LoudnessFixResult(before: before, after: after, gainDB: gain, limitingDB: limiting, note: note,
                                        clipsRepaired: repaired))
    }

    // MARK: Skrivning (WAV/AIFF)

    static func writePCM(_ channels: [[Float]], sr: Double, to url: URL) throws {
        if url.pathExtension.lowercased() == "wav" {
            try wav24(channels, sr: sr).write(to: url)
            return
        }
        let n = channels.first?.count ?? 0
        let chans = channels.count
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: AVAudioChannelCount(chans)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let data = buffer.floatChannelData else { throw LoudnessError.failed("Kunne ikke lave lydbuffer") }
        buffer.frameLength = AVAudioFrameCount(n)
        for c in 0..<chans {
            channels[c].withUnsafeBufferPointer { src in data[c].update(from: src.baseAddress!, count: n) }
        }
        let aiff = ["aif", "aiff"].contains(url.pathExtension.lowercased())
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: chans,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: aiff,
        ]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try out.write(from: buffer)
    }

    /// Almindelig 24-bit PCM-WAV (formatkode 1) – det CDJ'er og rekordbox læser uden problemer.
    static func wav24(_ channels: [[Float]], sr: Double) -> Data {
        let n = channels.first?.count ?? 0
        let nch = channels.count
        let dataBytes = n * nch * 3
        var d = Data(capacity: 44 + dataBytes + 1)
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes + (dataBytes & 1))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(nch); u32(Int(sr))
        u32(Int(sr) * nch * 3); u16(nch * 3); u16(24)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        var buf = [UInt8](repeating: 0, count: dataBytes)
        var o = 0
        for i in 0..<n {
            for c in 0..<nch {
                let v = Int32((Double(max(-1, min(1, channels[c][i]))) * 8_388_607).rounded())
                buf[o] = UInt8(truncatingIfNeeded: v)
                buf[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
                buf[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
                o += 3
            }
        }
        d.append(contentsOf: buf)
        if dataBytes & 1 == 1 { d.append(0) }
        return d
    }

    // MARK: MP3 (tabsfri global_gain)

    static func id3Length(_ d: [UInt8]) -> Int {
        guard d.count > 10, d[0] == 0x49, d[1] == 0x44, d[2] == 0x33 else { return 0 }
        let size = (Int(d[6]) << 21) | (Int(d[7]) << 14) | (Int(d[8]) << 7) | Int(d[9])
        return 10 + size + ((d[5] & 0x10) != 0 ? 10 : 0)
    }

    /// Ændrer global_gain i alle MP3-rammer med `steps` (1,5 dB pr. trin). Returnerer antal rammer.
    static func mp3ApplyGain(_ input: Data, steps: Int) -> (Data, Int) {
        var d = [UInt8](input)
        let bitrates1: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let bitrates2: [Int] = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let rates: [Int: [Int]] = [1: [44100, 48000, 32000], 2: [22050, 24000, 16000], 25: [11025, 12000, 8000]]
        var pos = id3Length(d)
        var end = d.count
        if end >= 128, d[end - 128] == 0x54, d[end - 127] == 0x41, d[end - 126] == 0x47 { end -= 128 }
        var frames = 0

        while pos + 4 <= end {
            let h = (UInt32(d[pos]) << 24) | (UInt32(d[pos + 1]) << 16) | (UInt32(d[pos + 2]) << 8) | UInt32(d[pos + 3])
            guard (h >> 21) & 0x7FF == 0x7FF else { pos += 1; continue }
            let ver = Int((h >> 19) & 3), layer = Int((h >> 17) & 3), prot = Int((h >> 16) & 1)
            let bri = Int((h >> 12) & 15), sri = Int((h >> 10) & 3), pad = Int((h >> 9) & 1), mode = Int((h >> 6) & 3)
            guard layer == 1, ver != 1, bri != 0, bri != 15, sri != 3 else { pos += 1; continue }
            let mpeg = ver == 3 ? 1 : (ver == 2 ? 2 : 25)
            let br = (mpeg == 1 ? bitrates1[bri] : bitrates2[bri]) * 1000
            let sr = rates[mpeg]![sri]
            let flen = (mpeg == 1 ? 144 * br / sr : 72 * br / sr) + pad
            guard flen >= 4, pos + flen <= end else { break }
            let nch = mode == 3 ? 1 : 2
            var bit = (pos + 4 + (prot == 0 ? 2 : 0)) * 8

            func read(_ n: Int) -> Int {
                var v = 0
                for _ in 0..<n {
                    v = (v << 1) | Int((d[bit >> 3] >> (7 - UInt8(bit & 7))) & 1)
                    bit += 1
                }
                return v
            }
            func write(at start: Int, _ n: Int, _ value: Int) {
                for i in 0..<n {
                    let b = (value >> (n - 1 - i)) & 1
                    let p = start + i
                    let mask = UInt8(1) << (7 - UInt8(p & 7))
                    if b == 1 { d[p >> 3] |= mask } else { d[p >> 3] &= ~mask }
                }
            }

            let granules: Int
            if mpeg == 1 {
                _ = read(9); _ = read(nch == 1 ? 5 : 3); _ = read(4 * nch)
                granules = 2
            } else {
                _ = read(8); _ = read(nch == 1 ? 1 : 2)
                granules = 1
            }
            for _ in 0..<granules {
                for _ in 0..<nch {
                    _ = read(12); _ = read(9)
                    let gpos = bit
                    let gg = read(8)
                    write(at: gpos, 8, max(0, min(255, gg + steps)))
                    _ = read(mpeg == 1 ? 4 : 9)
                    if read(1) == 1 {
                        _ = read(2); _ = read(1); _ = read(10); _ = read(9)
                    } else {
                        _ = read(15); _ = read(4); _ = read(3)
                    }
                    if mpeg == 1 { _ = read(1) }
                    _ = read(1); _ = read(1)
                }
            }
            frames += 1
            pos += flen
        }
        return (Data(d), frames)
    }

    /// Antal 1,5 dB-trin for en MP3 – kun op til `mp3CeilingDB` (MP3 har ingen limiter).
    static func mp3Steps(lufs: Double, peakDB: Double, target: Double) -> Int {
        var steps = Int(((target - lufs) / 1.5).rounded())
        while steps > 0 && peakDB + Double(steps) * 1.5 > mp3CeilingDB { steps -= 1 }
        return steps
    }
}
