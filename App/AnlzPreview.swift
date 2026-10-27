// MODULR – læser waveform-oversigten fra USB'ens analysefiler PRÆCIS som CDJ'en: stien regnes ud fra
// lydfilens sti (rekordbox' hash), og billedet tegnes af de bytes der ligger på stikket (PWV4 RGB,
// ellers PWAV blå). Så det du ser i MODULR er det spilleren får – og mangler der noget, kan du se det.

import Foundation
import CoreGraphics
import SwiftUI

enum AnlzReader {
    /// Samme formel som rekordbox/CDJ (CreateAnlzFileFolderPath) – se docs/REKORDBOX_USB.md.
    static func hashPath(_ filePath: String) -> String {
        var h: UInt32 = 0
        for cu in filePath.utf16 {
            let c = UInt32(cu)
            let t = h &* 0x5BC9 &+ c
            h = t &* 0x93B5 &+ c
        }
        let r = h % 200003
        var p: UInt32 = 0
        p |= (r >> 0) & 0x01
        p |= (r >> 1) & 0x02
        p |= (r >> 4) & 0x04
        p |= (r >> 4) & 0x08
        p |= (r >> 5) & 0x10
        p |= (r >> 8) & 0x20
        p |= (r >> 10) & 0x40
        return String(format: "/PIONEER/USBANLZ/P%03X/%08X/ANLZ0000.DAT", p, r)
    }

    private static func u32(_ d: Data, _ o: Int) -> Int {
        guard o + 4 <= d.count else { return 0 }
        let b = d.startIndex + o
        return Int(d[b]) << 24 | Int(d[b + 1]) << 16 | Int(d[b + 2]) << 8 | Int(d[b + 3])
    }

    /// Indholdet af et tag (efter dets header) i en ANLZ-fil.
    static func tag(_ d: Data, _ fourcc: String) -> Data? {
        guard d.count > 12, d.prefix(4) == Data("PMAI".utf8) else { return nil }
        var o = u32(d, 4)
        let want = Data(fourcc.utf8)
        while o + 12 <= d.count {
            let hl = u32(d, o + 4), tl = u32(d, o + 8)
            guard tl >= hl, tl > 0, o + tl <= d.count else { return nil }
            if d.subdata(in: (d.startIndex + o)..<(d.startIndex + o + 4)) == want {
                return d.subdata(in: (d.startIndex + o + hl)..<(d.startIndex + o + tl))
            }
            o += tl
        }
        return nil
    }

    enum Kind { case rgb, blue, none }

    struct Preview {
        let kind: Kind
        let path: String          // hvor CDJ'en kigger
        let columns: [(h: Double, r: Double, g: Double, b: Double)]
    }

    /// RGB-oversigten (PWV4 i .EXT) – ellers den blå (PWAV i .DAT).
    static func preview(root: URL, trackPath: String) -> Preview {
        let rel = hashPath(trackPath)
        let dat = root.appendingPathComponent(String(rel.dropFirst()))
        let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
        if let d = try? Data(contentsOf: ext), let body = tag(d, "PWV4"), body.count >= 6 {
            var cols = [(h: Double, r: Double, g: Double, b: Double)]()
            cols.reserveCapacity(body.count / 6)
            let base = body.startIndex
            for i in 0..<(body.count / 6) {
                let r = Double(body[base + i * 6 + 3]), g = Double(body[base + i * 6 + 4]), b = Double(body[base + i * 6 + 5])
                let top = max(r, max(g, b))
                cols.append(top > 0 ? (top / 127, r / top, g / top, b / top) : (0, 0, 0, 0))
            }
            return Preview(kind: .rgb, path: rel, columns: cols)
        }
        if let d = try? Data(contentsOf: dat), let body = tag(d, "PWAV"), !body.isEmpty {
            let cols = body.map { v -> (h: Double, r: Double, g: Double, b: Double) in
                let w = Double(v >> 5) / 7
                return (Double(v & 0x1F) / 31, 0.05 + 0.95 * w * 0.8, 0.43 + 0.57 * w * 0.8, 0.78 + 0.22 * w)
            }
            return Preview(kind: .blue, path: rel, columns: cols)
        }
        return Preview(kind: .none, path: rel, columns: [])
    }

    /// Spejlet billede i MODULR-stil (top 0–1 i hver kolonne, max-pooling når der er flere kolonner end pixels).
    static func image(_ p: Preview, width: Int, height: Int) -> CGImage? {
        guard !p.columns.isEmpty, width > 1, height > 1 else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let n = p.columns.count
        let mid = Double(height) / 2
        for x in 0..<width {
            let a = x * n / width, b = max(a + 1, (x + 1) * n / width)
            var best = p.columns[min(a, n - 1)]
            for i in a..<min(b, n) where p.columns[i].h > best.h { best = p.columns[i] }
            let half = min(1, best.h) * mid * 0.95
            guard half >= 0.5 else { continue }
            let y0 = max(0, Int((mid - half).rounded())), y1 = min(height, Int((mid + half).rounded()))
            for y in y0..<y1 {
                let shade = 1 - 0.2 * abs(Double(y) + 0.5 - mid) / max(1, half)
                let i = (y * width + x) * 4
                px[i] = UInt8(min(255, best.r * shade * 255))
                px[i + 1] = UInt8(min(255, best.g * shade * 255))
                px[i + 2] = UInt8(min(255, best.b * shade * 255))
                px[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Cache: én læsning pr. sang (genlæses når filen ændres).
final class UsbWaveCache {
    static let shared = UsbWaveCache()
    private var cache: [String: (stamp: Date, kind: AnlzReader.Kind, image: CGImage?)] = [:]
    private let lock = NSLock()

    func get(root: URL, trackPath: String, width: Int, height: Int) -> (AnlzReader.Kind, CGImage?) {
        let rel = AnlzReader.hashPath(trackPath)
        let ext = root.appendingPathComponent(String(rel.dropFirst())).deletingPathExtension().appendingPathExtension("EXT")
        let dat = root.appendingPathComponent(String(rel.dropFirst()))
        let fm = FileManager.default
        let stamp = ((try? fm.attributesOfItem(atPath: ext.path))?[.modificationDate] as? Date)
            ?? ((try? fm.attributesOfItem(atPath: dat.path))?[.modificationDate] as? Date) ?? .distantPast
        let key = "\(root.path)|\(trackPath)|\(width)x\(height)"
        lock.lock()
        if let c = cache[key], c.stamp == stamp { lock.unlock(); return (c.kind, c.image) }
        lock.unlock()
        let p = AnlzReader.preview(root: root, trackPath: trackPath)
        let img = AnlzReader.image(p, width: width, height: height)
        lock.lock()
        cache[key] = (stamp, p.kind, img)
        lock.unlock()
        return (p.kind, img)
    }
}

/// Waveform-cellen i USB-listen – det CDJ'en vil vise.
struct UsbWaveCell: View {
    let track: UsbTrackInfo
    let root: URL
    @State private var image: CGImage?
    @State private var kind: AnlzReader.Kind?

    init(track: UsbTrackInfo, root: URL) {
        self.track = track
        self.root = root
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if let image {
                Image(decorative: image, scale: 2).resizable().interpolation(.high)
            } else if kind == AnlzReader.Kind.none {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    Text("Ingen analyse – CDJ'en analyserer selv").font(.system(size: 10)).lineLimit(1)
                }
                .foregroundColor(.amber.opacity(0.8))
            }
            if kind == .blue {
                Text("BLÅ").font(.system(size: 8, weight: .heavy)).foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.5)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .frame(height: 24)
        .help(kind == .rgb ? "RGB-waveform fra stikket – sådan ser den ud på CDJ'en"
              : kind == .blue ? "Kun den gamle blå waveform på stikket"
              : "CDJ'en finder ingen analysefiler til denne sang")
        .task(id: "\(root.path)|\(track.path)|\(UsbStore.shared.revision)") {
            let r = root, p = track.path
            let res = await Task.detached(priority: .utility) { UsbWaveCache.shared.get(root: r, trackPath: p, width: 400, height: 48) }.value
            image = res.1
            kind = res.0
        }
    }
}
