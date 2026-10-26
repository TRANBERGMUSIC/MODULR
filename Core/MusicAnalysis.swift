// MODULR – kerne: musikanalyse til biblioteket – BPM, første slag, toneart (Camelot), energi (1–10)
// og RGB-waveform (bas/mellem/diskant, 150 kolonner pr. sekund som rekordbox).
// Algoritmerne er prototypet og testet i Python (10/10 BPM og toneart på testnumre) og oversat hertil.

import Foundation
import AVFoundation
import Accelerate

struct MusicAnalysisResult: Equatable {
    var bpm: Double
    var firstBeatMs: Double
    var key: MusicalKey?
    var energy: Int
    var duration: Double
    var loudnessDB: Double
    /// 3 bytes pr. kolonne (lav, mellem, høj), 150 kolonner pr. sekund.
    var bands: [UInt8]
}

enum MusicAnalyzer {
    static let waveformRate = 150.0

    // MARK: Dekodning

    /// Læser filen som mono og halverer samplefrekvensen (44,1/48 kHz → 22,05/24 kHz).
    static func decodeMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let srcRate = format.sampleRate
        let factor = max(1, Int((srcRate / 22050).rounded()))
        let chunk: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw AnalyzerError.unreadable }
        var out = [Float]()
        out.reserveCapacity(Int(file.length) / factor + 1)
        var acc: Float = 0
        var accN = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let scale = 1 / Float(channels)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += data[c][i] }
                acc += s * scale
                accN += 1
                if accN == factor {
                    out.append(acc / Float(factor))
                    acc = 0
                    accN = 0
                }
            }
        }
        return (out, srcRate / Double(factor))
    }

    // MARK: FFT

    final class FFT {
        let n: Int
        let log2n: vDSP_Length
        let setup: FFTSetup
        let window: [Float]
        private var real: [Float]
        private var imag: [Float]
        private var windowed: [Float]

        init(n: Int) {
            self.n = n
            log2n = vDSP_Length(log2(Double(n)))
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: n)
            vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
            window = w
            real = [Float](repeating: 0, count: n / 2)
            imag = [Float](repeating: 0, count: n / 2)
            windowed = [Float](repeating: 0, count: n)
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        /// Effekt-spektrum (|X|²) for et vindue der starter ved `start`.
        func power(_ x: [Float], start: Int, into out: inout [Float]) {
            let half = n / 2
            x.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(n))
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    out.withUnsafeMutableBufferPointer { op in
                        vDSP_zvmags(&split, 1, op.baseAddress!, 1, vDSP_Length(half))
                    }
                }
            }
            out[0] = 0   // DC/Nyquist-pakning fra zrip
        }
    }

    // MARK: Analyse

    static func analyze(url: URL) throws -> MusicAnalysisResult {
        let (x, sr) = try decodeMono(url: url)
        guard x.count > Int(sr * 2) else { throw AnalyzerError.tooShort }
        let duration = Double(x.count) / sr
        let tempo = estimateTempo(x, sr: sr)
        let key = estimateKey(x, sr: sr)
        let (bands, bandStats) = waveformBands(x, sr: sr)

        var rms: Float = 0
        vDSP_rmsqv(x, 1, &rms, vDSP_Length(x.count))
        let loud = 20 * log10(Double(max(rms, 1e-9)))
        let energy = energyRating(loudnessDB: loud, brightness: bandStats.brightness, density: tempo.density)
        return MusicAnalysisResult(bpm: tempo.bpm, firstBeatMs: tempo.firstBeatMs, key: key, energy: energy,
                                   duration: duration, loudnessDB: loud, bands: bands)
    }

    // MARK: Tempo

    struct Tempo {
        var bpm: Double
        var firstBeatMs: Double
        var density: Double
    }

    static func estimateTempo(_ x: [Float], sr: Double) -> Tempo {
        let n = 1024, hop = 256
        let fft = FFT(n: n)
        let half = n / 2
        let frames = (x.count - n) / hop + 1
        guard frames > 16 else { return Tempo(bpm: 0, firstBeatMs: 0, density: 0) }
        let binHz = sr / Double(n)
        let lowBins = max(2, Int(150 / binHz))
        var power = [Float](repeating: 0, count: half)
        var prev = [Float](repeating: 0, count: half)
        var cur = [Float](repeating: 0, count: half)
        var flux = [Float](repeating: 0, count: frames)
        var lowFlux = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            fft.power(x, start: f * hop, into: &power)
            for k in 0..<half { cur[k] = log1pf(100 * sqrtf(power[k])) }
            if f > 0 {
                var s: Float = 0, sl: Float = 0
                for k in 1..<half {
                    let d = cur[k] - prev[k]
                    if d > 0 {
                        s += d
                        if k < lowBins { sl += d }
                    }
                }
                flux[f - 1] = s
                lowFlux[f - 1] = sl
            }
            swap(&prev, &cur)
        }
        let fps = sr / Double(hop)
        // Onset-kurve: flux minus glidende middel (0,5 s), halvbølge-ensrettet
        let k = max(1, Int(fps * 0.5))
        var prefix = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { prefix[i + 1] = prefix[i] + Double(flux[i]) }
        var rect = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            // centreret glidende middel (som numpy.convolve(mode="same"))
            let a = max(0, i - k / 2), b = min(frames, i - k / 2 + k)
            let mean = Float((prefix[b] - prefix[a]) / Double(k))
            rect[i] = max(0, flux[i] - mean)
        }
        var envMean: Float = 0
        vDSP_meanv(rect, 1, &envMean, vDSP_Length(frames))
        let centered = rect.map { $0 - envMean }
        let env = centered.map { max(0, $0) }

        // Autokorrelation op til 4 × længste periode (60 BPM)
        let maxLag = min(frames - 2, Int(fps * 60 / 60 * 4) + 2)
        var ac = [Float](repeating: 0, count: maxLag + 2)
        centered.withUnsafeBufferPointer { cp in
            for lag in 0...(maxLag + 1) where lag < frames {
                var d: Float = 0
                vDSP_dotpr(cp.baseAddress!, 1, cp.baseAddress! + lag, 1, &d, vDSP_Length(frames - lag))
                ac[lag] = d
            }
        }
        func acAt(_ l: Double) -> Float {
            let i = Int(l)
            guard i + 1 < ac.count else { return 0 }
            let f = Float(l - Double(i))
            return (1 - f) * ac[i] + f * ac[i + 1]
        }
        var bestScore = -Double.infinity
        var bpm = 120.0
        var b = 60.0
        while b < 200 {
            let lag = fps * 60 / b
            var sc = 0.0
            for (m, w) in [(1.0, 1.0), (2.0, 0.5), (4.0, 0.25)] where lag * m + 1 < Double(ac.count) {
                sc += w * Double(acAt(lag * m))
            }
            let octaves: Double = log2(b / 125) / 0.6
            let prior: Double = exp(-0.5 * octaves * octaves)
            if sc * prior > bestScore {
                bestScore = sc * prior
                bpm = b
            }
            b += 0.05
        }
        while bpm < 85 { bpm *= 2 }
        while bpm > 175 { bpm /= 2 }

        // Finjustering: kam over onset-kurven (±1 BPM, trin 0,02)
        func comb(_ bb: Double, _ curve: [Float]) -> (Double, Double) {
            let period = fps * 60 / bb
            var best = 0.0, bestPh = 0.0
            for j in 0..<24 {
                let ph = period * Double(j) / 24
                var pos = ph
                var v = 0.0
                while pos < Double(curve.count - 1) {
                    let i = Int(pos)
                    let f = pos - Double(i)
                    v += (1 - f) * Double(curve[i]) + f * Double(curve[i + 1])
                    pos += period
                }
                if v > best { best = v; bestPh = ph }
            }
            return (best, bestPh)
        }
        var bestFine = (0.0, bpm)
        var c = bpm - 1.0
        while c <= bpm + 1.0 {
            let v = comb(c, env).0
            if v > bestFine.0 { bestFine = (v, c) }
            c += 0.02
        }
        bpm = bestFine.1
        if abs(bpm - bpm.rounded()) < 0.2 { bpm = bpm.rounded() } else { bpm = (bpm * 100).rounded() / 100 }

        // Første slag ud fra kick-området; vindue k er centreret om k·hop + n/2
        let period = fps * 60 / bpm
        var bestPh = 0.0, bestV = 0.0
        var ph = 0.0
        while ph < period {
            var pos = ph, v = 0.0
            while pos < Double(frames - 2) {
                let i = Int(pos)
                let f = pos - Double(i)
                v += (1 - f) * Double(lowFlux[i]) + f * Double(lowFlux[i + 1])
                pos += period
            }
            if v > bestV { bestV = v; bestPh = ph }
            ph += 0.25
        }
        let beatMs = 60000 / bpm
        let centerSamples: Double = (bestPh + 1) * Double(hop) + Double(n) / 2
        let rawMs: Double = centerSamples / sr * 1000 + 10
        var first: Double = rawMs.truncatingRemainder(dividingBy: beatMs)
        if first > beatMs - 25 { first -= beatMs }

        // Tæthed: andel af rammer med tydelige anslag (til energi)
        let thr = (rect.max() ?? 0) * 0.25
        let density = Double(rect.filter { $0 > thr }.count) / Double(frames)
        return Tempo(bpm: bpm, firstBeatMs: max(0, first), density: density)
    }

    // MARK: Toneart

    static let majorProfile: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimateKey(_ x: [Float], sr: Double) -> MusicalKey? {
        let n = 4096, hop = 2048
        let fft = FFT(n: n)
        let half = n / 2
        let frames = (x.count - n) / hop + 1
        guard frames > 4 else { return nil }
        var sum = [Double](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        for f in 0..<frames {
            fft.power(x, start: f * hop, into: &power)
            for k in 0..<half { sum[k] += Double(power[k]) }
        }
        var chroma = [Double](repeating: 0, count: 12)
        let binHz = sr / Double(n)
        for k in 1..<half {
            let freq = Double(k) * binHz
            guard freq > 50, freq < 2000 else { continue }
            let pc = (Int((12 * log2(freq / 440) + 9).rounded()) % 12 + 12) % 12
            chroma[pc] += sqrt(sum[k])
        }
        let total = chroma.reduce(0, +)
        guard total > 0 else { return nil }
        chroma = chroma.map { $0 / total }

        func corr(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<12 {
                num += (a[i] - ma) * (b[i] - mb)
                da += (a[i] - ma) * (a[i] - ma)
                db += (b[i] - mb) * (b[i] - mb)
            }
            return num / max(1e-12, sqrt(da * db))
        }
        var best = (-2.0, MusicalKey(pitchClass: 0, minor: false))
        for pc in 0..<12 {
            for (minor, profile) in [(false, majorProfile), (true, minorProfile)] {
                // profilen roteret så tonika ligger på pc
                let rotated = (0..<12).map { profile[(($0 - pc) % 12 + 12) % 12] }
                let c = corr(chroma, rotated)
                if c > best.0 { best = (c, MusicalKey(pitchClass: pc, minor: minor)) }
            }
        }
        return best.1
    }

    // MARK: Waveform

    struct BandStats {
        var brightness: Double
    }

    /// 3 bånd pr. kolonne som rekordbox' RGB-waveform: lav < 200 Hz, mellem 200–2500 Hz, høj > 2500 Hz
    /// (4. ordens filtre), RMS i 150 kolonner/s. Hvert bånd normaliseres mod sit eget 95-percentil og
    /// vægtes 1 : 0,5 : 0,4, så et fuldt klub-mix bliver laksefarvet, breaks grønne og hi-hats blå.
    static func waveformBands(_ x: [Float], sr: Double) -> ([UInt8], BandStats) {
        let hop = max(1, Int((sr / waveformRate).rounded()))
        let cols = max(1, x.count / hop)
        let low = biquadCascade(x, sections: [rbj(lowpass: true, f0: 200, sr: sr), rbj(lowpass: true, f0: 200, sr: sr)])
        let mid = biquadCascade(x, sections: [rbj(lowpass: false, f0: 200, sr: sr), rbj(lowpass: false, f0: 200, sr: sr),
                                              rbj(lowpass: true, f0: 2500, sr: sr), rbj(lowpass: true, f0: 2500, sr: sr)])
        let high = biquadCascade(x, sections: [rbj(lowpass: false, f0: 2500, sr: sr), rbj(lowpass: false, f0: 2500, sr: sr)])
        var raw = [Float](repeating: 0, count: cols * 3)
        var sumHigh = 0.0, sumAll = 0.0
        let signals = [low, mid, high]
        for band in 0..<3 {
            signals[band].withUnsafeBufferPointer { p in
                for c in 0..<cols {
                    let start = c * hop
                    let n = min(hop, p.count - start)
                    guard n > 0 else { continue }
                    var ms: Float = 0
                    vDSP_measqv(p.baseAddress! + start, 1, &ms, vDSP_Length(n))
                    raw[c * 3 + band] = sqrtf(ms)
                    sumAll += Double(ms)
                    if band == 2 { sumHigh += Double(ms) }
                }
            }
        }
        // Per-bånd reference (95-percentil), med gulv så et næsten tomt bånd ikke forstærkes til støj
        var refs = [Float](repeating: 1, count: 3)
        for band in 0..<3 {
            var v = [Float](repeating: 0, count: cols)
            for c in 0..<cols { v[c] = raw[c * 3 + band] }
            v.sort()
            refs[band] = v[min(cols - 1, Int(Double(cols) * 0.95))]
        }
        let floorRef: Float = max(1e-6, refs.max()! * 0.08)
        let weights: [Float] = [1.0, 0.5, 0.4]
        var tops = [Float](repeating: 0, count: cols)
        for c in 0..<cols {
            var top: Float = 0
            for band in 0..<3 {
                let v = raw[c * 3 + band] / max(refs[band], floorRef) * weights[band]
                raw[c * 3 + band] = v
                top = max(top, v)
            }
            tops[c] = top
        }
        var sortedTops = tops
        sortedTops.sort()
        let ref: Float = max(1e-6, sortedTops[min(cols - 1, Int(Double(cols) * 0.995))])
        var out = [UInt8](repeating: 0, count: cols * 3)
        for i in 0..<(cols * 3) {
            out[i] = UInt8((min(1, raw[i] / ref) * 255).rounded())
        }
        return (out, BandStats(brightness: sumAll > 0 ? sumHigh / sumAll : 0))
    }

    /// RBJ-biquad (Q = 0,707) som vDSP-koefficienter [b0, b1, b2, a1, a2].
    static func rbj(lowpass: Bool, f0: Double, sr: Double) -> [Double] {
        let w = 2 * Double.pi * f0 / sr
        let alpha = sin(w) / (2 * 0.7071)
        let c = cos(w)
        let a0 = 1 + alpha
        let b: [Double] = lowpass ? [(1 - c) / 2, 1 - c, (1 - c) / 2] : [(1 + c) / 2, -(1 + c), (1 + c) / 2]
        return [b[0] / a0, b[1] / a0, b[2] / a0, (-2 * c) / a0, (1 - alpha) / a0]
    }

    static func biquadCascade(_ x: [Float], sections: [[Double]]) -> [Float] {
        let coeffs: [Double] = sections.flatMap { $0 }
        guard let setup = vDSP_biquad_CreateSetup(coeffs, vDSP_Length(sections.count)) else { return x }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * sections.count + 2)
        var y = [Float](repeating: 0, count: x.count)
        vDSP_biquad(setup, &delay, x, 1, &y, 1, vDSP_Length(x.count))
        return y
    }

    // MARK: Energi

    /// 1–10 som i Mixed In Key: lydstyrke, diskant og tæthed af anslag.
    static func energyRating(loudnessDB: Double, brightness: Double, density: Double) -> Int {
        func norm(_ v: Double, _ a: Double, _ b: Double) -> Double { min(1, max(0, (v - a) / (b - a))) }
        let a: Double = 0.55 * norm(loudnessDB, -24, -8)
        let b: Double = 0.25 * norm(brightness, 0.002, 0.06)
        let c: Double = 0.20 * norm(density, 0.05, 0.3)
        let score: Double = a + b + c
        return Int(min(10, max(1, (1 + 9 * score).rounded())))
    }
}
