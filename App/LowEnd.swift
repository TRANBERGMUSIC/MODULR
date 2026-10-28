// MODULR – "Bas"-visningen: hvordan kicket og bassen ser ud, og om bunden bliver for voldsom på et anlæg.
// Sangen deles i sub (under 60 Hz), kick/bas (60–220 Hz), mellem (220 Hz–3 kHz) og diskant (over 3 kHz)
// med de samme delefrekvenser som EQ'en – så det du skruer på, kan ses med det samme (efter EQ).

import SwiftUI
import AVFoundation

// MARK: - Analyse

/// 2. ordens Butterworth-filter (RBJ). To i træk = 24 dB/oktav.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    static func lowPass(_ f: Double, _ sr: Double) -> Biquad { make(f, sr, high: false) }
    static func highPass(_ f: Double, _ sr: Double) -> Biquad { make(f, sr, high: true) }

    private static func make(_ f: Double, _ sr: Double, high: Bool) -> Biquad {
        let w0 = 2 * Double.pi * min(f, sr * 0.45) / sr
        let c = cos(w0), alpha = sin(w0) / (2 * 0.7071067811865476)
        let a0 = 1 + alpha
        var q = Biquad()
        if high {
            q.b0 = (1 + c) / 2 / a0; q.b1 = -(1 + c) / a0; q.b2 = (1 + c) / 2 / a0
        } else {
            q.b0 = (1 - c) / 2 / a0; q.b1 = (1 - c) / a0; q.b2 = (1 - c) / 2 / a0
        }
        q.a1 = -2 * c / a0
        q.a2 = (1 - alpha) / a0
        return q
    }

    @inline(__always) mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

struct LowEndData {
    static let rate = 100.0          // målinger pr. sekund (10 ms)
    static let waveRate = 500.0      // kick-formen: 2 ms pr. punkt

    var duration: Double
    // RMS og top pr. 10 ms (lineært, 1 = 0 dBFS)
    var subRMS: [Float] = []
    var subPeak: [Float] = []
    var kickRMS: [Float] = []        // 60–220 Hz
    var kickPeak: [Float] = []
    var lowRMS: [Float] = []         // alt under 220 Hz
    var midRMS: [Float] = []
    var highRMS: [Float] = []
    var sideSubRMS: [Float] = []     // stereo-delen af sub'en (L−R)
    // Bunden (under 220 Hz) som bølge: min/maks pr. 2 ms
    var lowMin: [Float] = []
    var lowMax: [Float] = []

    var count: Int { subRMS.count }

    static func analyze(url: URL) throws -> LowEndData {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let chans = Int(fmt.channelCount)
        var d = LowEndData(duration: Double(file.length) / sr)

        var subA = Biquad.lowPass(60, sr), subB = Biquad.lowPass(60, sr)
        var lowA = Biquad.lowPass(220, sr), lowB = Biquad.lowPass(220, sr)
        var kA = Biquad.highPass(60, sr), kB = Biquad.highPass(60, sr)
        var mA = Biquad.highPass(220, sr), mB = Biquad.highPass(220, sr)
        var mC = Biquad.lowPass(3000, sr), mD = Biquad.lowPass(3000, sr)
        var hA = Biquad.highPass(3000, sr), hB = Biquad.highPass(3000, sr)
        var sA = Biquad.lowPass(60, sr), sB = Biquad.lowPass(60, sr)

        let win = max(1, Int(sr / rate))
        let wwin = max(1, Int(sr / waveRate))
        var n = 0, wn = 0
        var sSub = 0.0, pSub = 0.0, sKick = 0.0, pKick = 0.0, sLow = 0.0, sMid = 0.0, sHigh = 0.0, sSide = 0.0
        var wMin = 0.0, wMax = 0.0
        let total = Int(file.length)
        d.subRMS.reserveCapacity(total / win + 1)

        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return d }
        while file.framePosition < file.length {
            try file.read(into: buf, frameCount: chunk)
            let frames = Int(buf.frameLength)
            guard frames > 0, let ch = buf.floatChannelData else { break }
            let L = ch[0]
            let R = chans > 1 ? ch[1] : ch[0]
            for i in 0..<frames {
                let l = Double(L[i]), r = Double(R[i])
                let mono = (l + r) * 0.5
                let side = (l - r) * 0.5
                let sub = subB.run(subA.run(mono))
                let low = lowB.run(lowA.run(mono))
                let kick = kB.run(kA.run(low))
                let mid = mD.run(mC.run(mB.run(mA.run(mono))))
                let high = hB.run(hA.run(mono))
                let ss = sB.run(sA.run(side))
                sSub += sub * sub; pSub = max(pSub, abs(sub))
                sKick += kick * kick; pKick = max(pKick, abs(kick))
                sLow += low * low
                sMid += mid * mid
                sHigh += high * high
                sSide += ss * ss
                if wn == 0 { wMin = low; wMax = low } else { wMin = min(wMin, low); wMax = max(wMax, low) }
                wn += 1
                if wn >= wwin {
                    d.lowMin.append(Float(wMin)); d.lowMax.append(Float(wMax))
                    wn = 0
                }
                n += 1
                if n >= win {
                    let k = Double(n)
                    d.subRMS.append(Float((sSub / k).squareRoot())); d.subPeak.append(Float(pSub))
                    d.kickRMS.append(Float((sKick / k).squareRoot())); d.kickPeak.append(Float(pKick))
                    d.lowRMS.append(Float((sLow / k).squareRoot()))
                    d.midRMS.append(Float((sMid / k).squareRoot()))
                    d.highRMS.append(Float((sHigh / k).squareRoot()))
                    d.sideSubRMS.append(Float((sSide / k).squareRoot()))
                    n = 0
                    sSub = 0; pSub = 0; sKick = 0; pKick = 0; sLow = 0; sMid = 0; sHigh = 0; sSide = 0
                }
            }
        }
        return d
    }
}

// MARK: - Målinger (før og efter EQ)

struct LowEndMetrics: Codable, Equatable {
    var subShare: Double      // sub i forhold til hele lyden i de kraftige dele (dB)
    var lowShare: Double      // alt under 220 Hz i forhold til hele lyden (dB)
    var subPeak: Double       // højeste top i sub'en (dBFS)
    var kickPeak: Double      // højeste top i kick/bas (dBFS)
    var punch: Double         // kickets top over dets gennemsnit (dB) – højt = slag, lavt = fladt/komprimeret
    var stereoSub: Double     // stereo-delen af sub'en i forhold til sub'en (dB) – højt = bred bas
    var tail: Double          // hvor stor del af slaget kicket/bassen hænger (0–1) – højt = buldrer

    enum Verdict { case good, warn, bad }

    static func db(_ v: Double) -> Double { v > 1e-9 ? 20 * log10(v) : -120 }

    /// `gains`: EQ (dB pr. bånd) for hvert 10 ms-vindue – nil = urørt.
    static func measure(_ d: LowEndData, loud: [Bool], beatSec: Double?, firstBeat: Double,
                        gains: ((Int) -> (lo: Double, mi: Double, hi: Double))?) -> LowEndMetrics {
        var eSub = 0.0, eLow = 0.0, eFull = 0.0, eSide = 0.0, eKick = 0.0, n = 0.0
        var subPk = 0.0, kickPk = 0.0
        var kickPeaks = [Double]()
        for i in 0..<d.count {
            let g = gains?(i) ?? (lo: 1.0, mi: 1.0, hi: 1.0)
            let sub = Double(d.subRMS[i]) * g.lo, low = Double(d.lowRMS[i]) * g.lo
            let mid = Double(d.midRMS[i]) * g.mi, high = Double(d.highRMS[i]) * g.hi
            subPk = max(subPk, Double(d.subPeak[i]) * g.lo)
            kickPk = max(kickPk, Double(d.kickPeak[i]) * g.lo)
            guard loud.isEmpty || (i < loud.count && loud[i]) else { continue }
            eSub += sub * sub
            eLow += low * low
            eFull += low * low + mid * mid + high * high
            eSide += pow(Double(d.sideSubRMS[i]) * g.lo, 2)
            let k = Double(d.kickRMS[i]) * g.lo
            eKick += k * k
            kickPeaks.append(Double(d.kickPeak[i]) * g.lo)
            n += 1
        }
        n = max(1, n)
        let kickRMS = (eKick / n).squareRoot()
        // Punch: de kraftigste slag (90-percentil af toppene) over kick-båndets gennemsnit
        let sortedPk = kickPeaks.sorted()
        let p90 = sortedPk.isEmpty ? 0 : sortedPk[min(sortedPk.count - 1, Int(Double(sortedPk.count) * 0.9))]
        return LowEndMetrics(
            subShare: db((eSub / max(1e-12, eFull)).squareRoot()),
            lowShare: db((eLow / max(1e-12, eFull)).squareRoot()),
            subPeak: db(subPk),
            kickPeak: db(kickPk),
            punch: db(p90) - db(kickRMS),
            stereoSub: eSub > 1e-12 ? db((eSide / eSub).squareRoot()) : -120,
            tail: tailRatio(d, loud: loud, beatSec: beatSec, firstBeat: firstBeat))
    }

    /// Hvor længe bunden hænger efter hvert slag: tiden til den er faldet 12 dB, som andel af et slag.
    static func tailRatio(_ d: LowEndData, loud: [Bool], beatSec: Double?, firstBeat: Double) -> Double {
        guard let beat = beatSec, beat > 0.2 else { return 0 }
        let r = LowEndData.rate
        var ratios = [Double]()
        var k = 0
        while true {
            let t = firstBeat + Double(k) * beat
            k += 1
            let a = Int(t * r)
            if a < 0 { continue }
            let b = Int((t + beat) * r)
            if b >= d.count { break }
            if !loud.isEmpty, a < loud.count, !loud[a] { continue }
            // Toppen inden for de første 60 ms af slaget
            var pk = 0.0, pi = a
            for i in a..<min(b, a + 6) where Double(d.lowRMS[i]) > pk { pk = Double(d.lowRMS[i]); pi = i }
            guard pk > 1e-4 else { continue }
            let limit = pk * 0.251   // −12 dB
            var j = pi
            while j < b && Double(d.lowRMS[j]) > limit { j += 1 }
            ratios.append(Double(j - a) / Double(b - a))
        }
        guard !ratios.isEmpty else { return 0 }
        return ratios.sorted()[ratios.count / 2]
    }

    // Vurderinger (vejledende – ørerne og anlægget har sidste ord)

    var subVerdict: (Verdict, String) {
        if subShare > -4 { return (.bad, "Meget sub – kan blive voldsomt og mudret på et stort anlæg") }
        if subShare > -7 { return (.warn, "Kraftig sub – mærkes tydeligt på anlægget") }
        if subShare < -16 { return (.warn, "Lidt sub – kan føles tynd på et stort anlæg") }
        return (.good, "Sund mængde sub")
    }

    var peakVerdict: (Verdict, String) {
        if subPeak > -1 { return (.bad, "Sub'en alene rammer loftet – risiko for forvrængning og pumpende limiter") }
        if subPeak > -4 { return (.warn, "Sub'en står tæt på loftet – lidt plads til resten af lyden") }
        return (.good, "God plads over bunden")
    }

    var punchVerdict: (Verdict, String) {
        if punch < 6 { return (.warn, "Fladt kick – hårdt komprimeret, mister slag på anlægget") }
        if punch > 18 { return (.warn, "Meget spidst kick – kan klikke/slå hårdt") }
        return (.good, "Kicket har et tydeligt slag")
    }

    var stereoVerdict: (Verdict, String) {
        if stereoSub > -8 { return (.bad, "Bred (stereo) bas – kan forsvinde eller blive tynd på et mono-klubanlæg") }
        if stereoSub > -16 { return (.warn, "Lidt stereo i bunden") }
        return (.good, "Bunden er mono – som den skal være")
    }

    var tailVerdict: (Verdict, String) {
        if tail > 0.9 { return (.bad, "Bunden hænger hele slaget – kick og bas flyder sammen og kan buldre") }
        if tail > 0.6 { return (.warn, "Lang hale på kick/bas") }
        if tail <= 0 { return (.good, "–") }
        return (.good, "Kicket slipper i tide – luft mellem slagene")
    }
}

// MARK: - Lager (beregnes én gang pr. sang)

final class LowEndStore: ObservableObject {
    static let shared = LowEndStore()
    @Published private(set) var data: [UUID: LowEndData] = [:]
    @Published private(set) var working: Set<UUID> = []
    @Published private(set) var failed: [UUID: String] = [:]
    private var order: [UUID] = []

    private static let refKey = "lowend.reference"

    /// Dine andre sanges målinger (før EQ) – så en sang kan sammenlignes med det du plejer at spille.
    static var reference: [String: LowEndMetrics] {
        get {
            guard let d = UserDefaults.standard.data(forKey: refKey),
                  let r = try? JSONDecoder().decode([String: LowEndMetrics].self, from: d) else { return [:] }
            return r
        }
        set { if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: refKey) } }
    }

    func remember(_ id: UUID, _ m: LowEndMetrics) {
        var r = Self.reference
        guard r[id.uuidString] != m else { return }
        r[id.uuidString] = m
        Self.reference = r
    }

    func load(_ t: LibTrack) {
        guard data[t.id] == nil, !working.contains(t.id) else { return }
        working.insert(t.id)
        failed[t.id] = nil
        let id = t.id, url = t.url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LowEndData.analyze(url: url) }
            DispatchQueue.main.async {
                self.working.remove(id)
                switch result {
                case .success(let d):
                    self.data[id] = d
                    self.order.append(id)
                    // Kun de seneste få i hukommelsen
                    while self.order.count > 6 { self.data[self.order.removeFirst()] = nil }
                case .failure(let e):
                    self.failed[id] = e.localizedDescription
                }
            }
        }
    }
}

// MARK: - Visning

struct LowEndPanel: View {
    @ObservedObject private var player = PlayerModel.shared
    @ObservedObject private var store = LowEndStore.shared
    let track: LibTrack

    var body: some View {
        Group {
            if let d = store.data[track.id] {
                content(d)
            } else if let err = store.failed[track.id] {
                Text("Kunne ikke læse lyden: \(err)").font(.system(size: 12)).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Måler bas og kick …").font(.system(size: 12)).foregroundColor(.mist.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .onAppear { store.load(track) }
        .onChange(of: track.id) { _, _ in store.load(track) }
    }

    // EQ'en (hele sangen + områder) som volumen pr. bånd for et 10 ms-vindue
    func gainFunction() -> ((Int) -> (lo: Double, mi: Double, hi: Double))? {
        let regions = track.eqRegions ?? []
        let eq = player.eq
        if eq.isFlat && regions.allSatisfy({ abs($0.low) < 0.05 && abs($0.mid) < 0.05 && abs($0.high) < 0.05 }) { return nil }
        func a(_ db: Double) -> Double { Double(IsolatorEQ.amp(Float(db))) }
        let base = (lo: a(eq.low), mi: a(eq.mid), hi: a(eq.high))
        let regs = regions.map { (start: $0.start, end: $0.end, g: (lo: a($0.low), mi: a($0.mid), hi: a($0.high))) }
        return { i in
            let t = Double(i) / LowEndData.rate
            if let r = regs.first(where: { t >= $0.start && t < $0.end }) { return r.g }
            return base
        }
    }

    /// De kraftige dele: drops (dine egne eller appens), ellers de 35 % kraftigste vinduer.
    func loudMask(_ d: LowEndData) -> [Bool] {
        let drops = player.sections.filter { $0.kind == .drop }
        if !drops.isEmpty {
            var m = [Bool](repeating: false, count: d.count)
            for s in drops {
                let a = max(0, Int(s.start * LowEndData.rate)), b = min(d.count, Int(s.end * LowEndData.rate))
                if a < b { for i in a..<b { m[i] = true } }
            }
            return m
        }
        let full = (0..<d.count).map { d.lowRMS[$0] * d.lowRMS[$0] + d.midRMS[$0] * d.midRMS[$0] + d.highRMS[$0] * d.highRMS[$0] }
        let sorted = full.sorted()
        guard !sorted.isEmpty else { return [] }
        let cut = sorted[Int(Double(sorted.count) * 0.65)]
        return full.map { $0 >= cut }
    }

    @ViewBuilder
    func content(_ d: LowEndData) -> some View {
        let gains = gainFunction()
        let loud = loudMask(d)
        let beat: Double? = (track.bpm ?? 0) > 0 ? 60 / (track.bpm ?? 120) : nil
        let fb = (track.firstBeatMs ?? 0) / 1000
        let before = LowEndMetrics.measure(d, loud: loud, beatSec: beat, firstBeat: fb, gains: nil)
        let after = gains == nil ? nil : LowEndMetrics.measure(d, loud: loud, beatSec: beat, firstBeat: fb, gains: gains)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                LowEndOverview(data: d, gains: gains)
                    .frame(height: 74)
                HStack(spacing: 6) {
                    legend(Color(red: 0.95, green: 0.2, blue: 0.35), "Sub < 60 Hz")
                    legend(Color(red: 1, green: 0.55, blue: 0.1), "Kick/bas 60–220 Hz")
                    if gains != nil { legend(Color.white.opacity(0.35), "Før din EQ") }
                    Spacer()
                    Text("Rød zone = over −3 dBFS").font(.system(size: 10)).foregroundColor(.mist.opacity(0.45))
                }
                KickShape(data: d, gains: gains, beat: beat, firstBeat: fb)
                    .frame(height: 92)
            }
            VStack(spacing: 8) {
                // Skru her og se det med det samme (samme EQ som EQ-fanen, for hele sangen)
                HStack(spacing: 14) {
                    Knob(title: "Lows", value: $player.eq.low)
                    Knob(title: "Mids", value: $player.eq.mid)
                    Knob(title: "High", value: $player.eq.high)
                    if !player.eq.isFlat {
                        Button("Nulstil") { player.eq = EQSettings() }
                            .buttonStyle(.ghost)
                    }
                }
                metrics(before: before, after: after)
            }
            .frame(width: 330)
        }
        .onAppear { store.remember(track.id, before) }
    }

    func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 6)
            Text(s).font(.system(size: 10, weight: .medium)).foregroundColor(.mist.opacity(0.6))
        }
    }

    func metrics(before: LowEndMetrics, after: LowEndMetrics?) -> some View {
        let m = after ?? before
        let others = LowEndStore.reference.filter { $0.key != track.id.uuidString }.map(\.value)
        func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        let refSub = others.count >= 5 ? median(others.map(\.subShare)) : nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(after == nil ? "Bunden" : "Bunden – efter din EQ").font(.system(size: 12, weight: .semibold)).foregroundColor(.mist)
                Spacer()
                Text("Vejledende").font(.system(size: 10)).foregroundColor(.mist.opacity(0.4))
            }
            row("Sub-andel", value: m.subShare, was: after.map { _ in before.subShare }, unit: "dB", m.subVerdict,
                extra: refSub.map { String(format: "dine sange: %.1f", $0) })
            row("Sub-top", value: m.subPeak, was: after.map { _ in before.subPeak }, unit: "dBFS", m.peakVerdict)
            row("Kick-slag", value: m.punch, was: after.map { _ in before.punch }, unit: "dB", m.punchVerdict)
            row("Stereo i bunden", value: m.stereoSub, was: after.map { _ in before.stereoSub }, unit: "dB", m.stereoVerdict)
            row("Hale", value: m.tail * 100, was: after.map { _ in before.tail * 100 }, unit: "% af slaget", m.tailVerdict)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    func row(_ title: String, value: Double, was: Double?, unit: String, _ verdict: (LowEndMetrics.Verdict, String),
             extra: String? = nil) -> some View {
        let color: Color = verdict.0 == .good ? Color(red: 0.3, green: 0.85, blue: 0.4)
            : (verdict.0 == .warn ? Color(red: 1, green: 0.7, blue: 0.2) : Color(red: 0.95, green: 0.3, blue: 0.25))
        return HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.mist)
                    Spacer(minLength: 4)
                    if let was, abs(was - value) >= 0.1 {
                        Text(String(format: "%.1f →", was)).font(.system(size: 10)).monospacedDigit().foregroundColor(.mist.opacity(0.4))
                    }
                    Text(value <= -119 ? "–" : String(format: "%.1f %@", value, unit))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(color)
                        .contentTransition(.numericText(value: value))
                }
                Text(verdict.1 + (extra.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundColor(.mist.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.snappy, value: value)
    }
}

/// Hele sangen: sub og kick/bas som kurver (dBFS), med rød zone øverst og afspilningshovedet.
struct LowEndOverview: View {
    @ObservedObject private var player = PlayerModel.shared
    let data: LowEndData
    let gains: ((Int) -> (lo: Double, mi: Double, hi: Double))?

    static let floorDB = -42.0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            Canvas { ctx, size in
                let W = Double(size.width), H = Double(size.height)
                func y(_ v: Double) -> Double {
                    let db = v > 1e-9 ? 20 * log10(v) : -120
                    return H * (1 - max(0, min(1, (db - Self.floorDB) / -Self.floorDB)))
                }
                // Zoner: rød over −3 dBFS, linje ved −6
                ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: y(0.708))), with: .color(Color.red.opacity(0.12)))
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(0.501))); line.addLine(to: CGPoint(x: W, y: y(0.501)))
                ctx.stroke(line, with: .color(Color.white.opacity(0.15)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let n = data.count
                guard n > 0 else { return }
                let cols = max(1, Int(W))
                func curve(_ arr: [Float], gain: Bool) -> Path {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: H))
                    for c in 0..<cols {
                        let a = c * n / cols, b = max(a + 1, (c + 1) * n / cols)
                        var mx = 0.0
                        for i in a..<min(n, b) {
                            let gl = gain ? (gains?(i).lo ?? 1) : 1
                            mx = max(mx, Double(arr[i]) * gl)
                        }
                        p.addLine(to: CGPoint(x: Double(c), y: y(mx)))
                    }
                    p.addLine(to: CGPoint(x: W, y: H))
                    p.closeSubpath()
                    return p
                }
                let kick = Color(red: 1, green: 0.55, blue: 0.1)
                let sub = Color(red: 0.95, green: 0.2, blue: 0.35)
                if gains != nil {
                    // Før EQ: kun omrids
                    ctx.stroke(curve(data.kickPeak, gain: false), with: .color(Color.white.opacity(0.3)), lineWidth: 1)
                    ctx.stroke(curve(data.subPeak, gain: false), with: .color(Color.white.opacity(0.22)), lineWidth: 1)
                }
                ctx.fill(curve(data.kickPeak, gain: true), with: .color(kick.opacity(0.55)))
                ctx.fill(curve(data.subPeak, gain: true), with: .color(sub.opacity(0.75)))
                for (db, label) in [(0.0, "0"), (-6.0, "−6"), (-18.0, "−18"), (-30.0, "−30")] {
                    let yy = y(pow(10, db / 20))
                    ctx.draw(Text(label).font(.system(size: 8)).foregroundColor(.white.opacity(0.35)),
                             at: CGPoint(x: 3, y: min(H - 6, max(6, yy))), anchor: .leading)
                }
            }
            // Afspilningshovedet
            let dur = max(0.001, data.duration)
            Rectangle().fill(Color.white).frame(width: 1.5, height: h)
                .offset(x: w * CGFloat(player.position / dur))
                .allowsHitTesting(false)
        }
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(GeometryReader { g in
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    player.seek(seconds: Double(max(0, min(1, v.location.x / max(1, g.size.width)))) * data.duration)
                })
        })
        .help("Sub (rød) og kick/bas (orange) gennem hele sangen – højden er toppen i dBFS. Klik for at hoppe.")
    }
}

/// Kick-formen omkring afspilningshovedet: bunden (under 220 Hz) som bølge over to takter, med slagene markeret.
/// Her kan man se om kicket slår kort og rent, eller hænger og flyder sammen med bassen.
struct KickShape: View {
    @ObservedObject private var player = PlayerModel.shared
    let data: LowEndData
    let gains: ((Int) -> (lo: Double, mi: Double, hi: Double))?
    let beat: Double?
    let firstBeat: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !player.playing)) { _ in
            Canvas { ctx, size in draw(ctx, size, pos: player.livePosition()) }
        }
        .background(Color.black.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topLeading) {
            Text("Kick-form (bunden under 220 Hz, 2 takter)")
                .font(.system(size: 9, weight: .semibold)).foregroundColor(.mist.opacity(0.5))
                .padding(4)
        }
        .help("Bunden som bølge omkring afspilningshovedet. Korte, adskilte slag = rent kick. En bølge der aldrig falder ned mellem slagene = buldrer.")
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize, pos: Double) {
        let W = Double(size.width), H = Double(size.height), mid = H / 2
        let span = (beat ?? 0.5) * 8          // to takter
        let t0 = pos - span / 2
        let rate = LowEndData.waveRate
        let n = data.lowMin.count
        // Loft (0 dBFS) og −6 dBFS
        for (lvl, a) in [(1.0, 0.25), (0.5, 0.12)] {
            for s in [-1.0, 1.0] {
                var p = Path()
                let yy = mid - s * lvl * (H / 2 - 4)
                p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: W, y: yy))
                ctx.stroke(p, with: .color(Color.white.opacity(a)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        let cols = max(1, Int(W))
        func path(gain: Bool) -> Path {
            var p = Path()
            for c in 0..<cols {
                let ta = t0 + Double(c) / Double(cols) * span
                let tb = t0 + Double(c + 1) / Double(cols) * span
                let a = Int(ta * rate), b = max(a + 1, Int(tb * rate))
                guard a >= 0, a < n else { continue }
                var lo: Float = 0, hi: Float = 0
                for i in a..<min(n, b) { lo = min(lo, data.lowMin[i]); hi = max(hi, data.lowMax[i]) }
                let g = gain ? (gains?(Int(ta * LowEndData.rate)).lo ?? 1) : 1
                let y0 = mid - Double(hi) * g * (H / 2 - 4), y1 = mid - Double(lo) * g * (H / 2 - 4)
                p.addRect(CGRect(x: Double(c), y: y0, width: 1, height: max(0.5, y1 - y0)))
            }
            return p
        }
        if gains != nil { ctx.fill(path(gain: false), with: .color(Color.white.opacity(0.14))) }
        ctx.fill(path(gain: true), with: .color(Color(red: 1, green: 0.5, blue: 0.15)))
        // Slagene
        if let beat {
            var k = Int(floor((t0 - firstBeat) / beat))
            while true {
                let tb = firstBeat + Double(k) * beat
                if tb > t0 + span { break }
                let x = (tb - t0) / span * W
                let bar = BeatGrid.mod(k, BeatGrid.beatsPerBar) == 0
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: H)), with: .color(Color.white.opacity(bar ? 0.35 : 0.12)))
                k += 1
            }
        }
        // Afspilningshovedet i midten
        ctx.fill(Path(CGRect(x: W / 2 - 0.75, y: 0, width: 1.5, height: H)), with: .color(.white))
    }
}

extension PlayerModel {
    /// EQ'en som volumen pr. bånd (bas, mellem, diskant) på et tidspunkt – nil når alt står fladt.
    /// Bruges til at vise EQ'en i waveformen, så man kan se hvad man fjerner.
    func eqVisual(_ t: LibTrack) -> ((Double) -> (Double, Double, Double))? {
        let regions = t.eqRegions ?? []
        let e = eq
        if e.isFlat && regions.allSatisfy({ abs($0.low) < 0.05 && abs($0.mid) < 0.05 && abs($0.high) < 0.05 }) { return nil }
        func a(_ db: Double) -> Double { Double(IsolatorEQ.amp(Float(db))) }
        let base = (a(e.low), a(e.mid), a(e.high))
        let regs = regions.map { r in (r.start, r.end, (a(r.low), a(r.mid), a(r.high))) }
        return { time in
            for r in regs where time >= r.0 && time < r.1 { return r.2 }
            return base
        }
    }
}
