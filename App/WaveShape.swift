// MODULR – waveformen som én blød form (som rekordbox): højder interpoleres og udglattes, formen
// tegnes kantudglattet, og farverne glider over i hinanden i stedet for at stå i pixel-striber.

import SwiftUI
import CoreGraphics

struct WaveSample {
    var height: Double      // 0–1
    var r: Double
    var g: Double
    var b: Double
}

enum WaveShape {
    /// Et punkt pr. pixel fra `t0` med `spp` sekunder imellem.
    static func profile(_ bands: [UInt8], from t0: Double, secondsPerPoint spp: Double, count n: Int,
                        duration: Double, floor f: Double) -> [WaveSample] {
        let rate = MusicAnalyzer.waveformRate
        let cols = bands.count / 3
        var out = [WaveSample](repeating: WaveSample(height: 0, r: 0, g: 0, b: 0), count: max(0, n))
        guard cols > 0, n > 0 else { return out }
        let span = spp * rate
        for i in 0..<n {
            let t = t0 + Double(i) * spp
            guard t >= 0, t <= duration else { continue }
            let col = t * rate
            var lo = 0.0, mi = 0.0, hi = 0.0
            if span > 1.5 {
                // Zoomet ud: største værdi i punktets kolonner, så toppe ikke forsvinder
                let a = max(0, Int(col - span / 2))
                let b = min(cols, max(a + 1, Int(col + span / 2) + 1))
                if a < cols {
                    for c in a..<b {
                        lo = max(lo, Double(bands[c * 3]))
                        mi = max(mi, Double(bands[c * 3 + 1]))
                        hi = max(hi, Double(bands[c * 3 + 2]))
                    }
                }
            } else {
                lo = WaveColor.sample(bands, at: col, band: 0)
                mi = WaveColor.sample(bands, at: col, band: 1)
                hi = WaveColor.sample(bands, at: col, band: 2)
            }
            let top = max(lo, max(mi, hi))
            guard top > 0, let c = WaveColor.rgb(lo, mi, hi, floor: f) else { continue }
            out[i] = WaveSample(height: top / 255, r: c.r, g: c.g, b: c.b)
        }
        // Blød kurve: 1-2-1-udglatning af højderne
        if n > 2 {
            var sm = out
            for i in 1..<(n - 1) {
                sm[i].height = (out[i - 1].height + 2 * out[i].height + out[i + 1].height) / 4
            }
            out = sm
        }
        return out
    }

    /// Spejlet form om `mid` (detaljevisningen).
    static func path(_ p: [WaveSample], step: Double, mid: Double, halfHeight: Double) -> Path? {
        guard p.count > 1 else { return nil }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: mid - p[0].height * halfHeight))
        for i in 1..<p.count {
            path.addLine(to: CGPoint(x: Double(i) * step, y: mid - p[i].height * halfHeight))
        }
        for i in stride(from: p.count - 1, through: 0, by: -1) {
            path.addLine(to: CGPoint(x: Double(i) * step, y: mid + p[i].height * halfHeight))
        }
        path.closeSubpath()
        return path
    }

    /// Farver som vandret gradient: et stop for hver `every` punkter (vægtet efter højde).
    static func colorStops(_ p: [WaveSample], every: Int) -> [(location: Double, r: Double, g: Double, b: Double)] {
        var stops = [(location: Double, r: Double, g: Double, b: Double)]()
        let n = p.count
        guard n > 1 else { return stops }
        var i = 0
        while i < n {
            let j = min(n, i + max(1, every))
            var r = 0.0, g = 0.0, b = 0.0, ws = 0.0
            for k in i..<j {
                let wt = p[k].height
                r += p[k].r * wt
                g += p[k].g * wt
                b += p[k].b * wt
                ws += wt
            }
            if ws > 0 {
                let loc = (Double(i) + Double(j - i - 1) / 2) / Double(n - 1)
                stops.append((min(1, max(0, loc)), r / ws, g / ws, b / ws))
            }
            i = j
        }
        return stops
    }

    static func gradient(_ p: [WaveSample], every: Int, dimBefore: Double, dim: Double) -> Gradient {
        var stops = [Gradient.Stop]()
        for s in colorStops(p, every: every) {
            let f: Double = s.location < dimBefore ? dim : 1
            stops.append(Gradient.Stop(color: Color(red: s.r * f, green: s.g * f, blue: s.b * f), location: s.location))
        }
        if stops.isEmpty {
            stops = [Gradient.Stop(color: .clear, location: 0), Gradient.Stop(color: .clear, location: 1)]
        }
        return Gradient(stops: stops)
    }

    /// Hele sangen som rekordbox' preview: tegnet nedefra, én pixel-søjle ad gangen med den højeste top
    /// i søjlen (ingen udglatning – spidst og detaljeret) og mættede farver fra frekvensbåndene.
    static func preview(bands: [UInt8], peaks: [UInt8], width: Int, height: Int) -> CGImage? {
        let cols = bands.count / 3
        guard cols > 1, width > 1, height > 1 else { return nil }
        let duration = Double(cols) / MusicAnalyzer.waveformRate
        let pcount = peaks.count
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for x in 0..<width {
            let ta = Double(x) / Double(width) * duration
            let tb = Double(x + 1) / Double(width) * duration
            // Højde: største top i søjlen
            var amp = 0.0
            if pcount > 0 {
                let a = max(0, Int(ta * MusicAnalyzer.peakRate))
                let b = min(pcount, max(a + 1, Int(tb * MusicAnalyzer.peakRate)))
                if a < pcount { for k in a..<b { amp = max(amp, Double(peaks[k])) } }
            }
            // Farve: gennemsnit af båndene i søjlen
            let ca = max(0, Int(ta * MusicAnalyzer.waveformRate))
            let cb = min(cols, max(ca + 1, Int(tb * MusicAnalyzer.waveformRate)))
            var lo = 0.0, mi = 0.0, hi = 0.0, top = 0.0
            if ca < cols {
                for c in ca..<cb {
                    lo += Double(bands[c * 3]); mi += Double(bands[c * 3 + 1]); hi += Double(bands[c * 3 + 2])
                    top = max(top, Double(max(bands[c * 3], max(bands[c * 3 + 1], bands[c * 3 + 2]))))
                }
            }
            if pcount == 0 { amp = top }
            guard amp > 1, let c = WaveColor.rgb(lo, mi, hi, floor: 0.18, boost: true) else { continue }
            let h = max(1, Int((amp / 255 * Double(height)).rounded()))
            for yy in 0..<min(h, height) {
                // Lidt lysere top, mørkere bund – giver dybde som i rekordbox
                let shade = 0.78 + 0.22 * Double(yy) / Double(max(1, h))
                let i = ((height - 1 - yy) * width + x) * 4
                px[i] = UInt8(min(255, c.r * shade * 255))
                px[i + 1] = UInt8(min(255, c.g * shade * 255))
                px[i + 2] = UInt8(min(255, c.b * shade * 255))
                px[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Hele sangen som billede, tegnet nedefra (overblik og tabel) – kantudglattet med glidende farver.
    static func image(bands: [UInt8], width: Int, height: Int) -> CGImage? {
        let cols = bands.count / 3
        guard cols > 1, width > 1, height > 1 else { return nil }
        let duration = Double(cols) / MusicAnalyzer.waveformRate
        let prof = profile(bands, from: 0, secondsPerPoint: duration / Double(width), count: width,
                           duration: duration, floor: WaveColor.floor)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        let H = Double(height)
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: 0, y: 0))
        for i in 0..<width {
            shape.addLine(to: CGPoint(x: Double(i) + 0.5, y: prof[i].height * H))
        }
        shape.addLine(to: CGPoint(x: Double(width), y: 0))
        shape.closeSubpath()

        let stops = colorStops(prof, every: 2)
        guard stops.count >= 2 else { return nil }
        let colors = stops.map { CGColor(colorSpace: space, components: [CGFloat($0.r), CGFloat($0.g), CGFloat($0.b), 1])! } as CFArray
        let locations: [CGFloat] = stops.map { CGFloat($0.location) }
        guard let grad = CGGradient(colorsSpace: space, colors: colors, locations: locations) else { return nil }
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: Double(width), y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Lidt mørkere mod bunden giver dybde
        let shadeColors = [CGColor(gray: 0, alpha: 0.28), CGColor(gray: 0, alpha: 0)] as CFArray
        if let shade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: shadeColors, locations: [0, 1]) {
            ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
