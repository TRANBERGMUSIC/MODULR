// MODULR – Artwork: læg et billede ind i WAV/AIFF/MP3, så det vises i rekordbox og på CDJ'en.
// Pioneer: artwork skal være indlejret, kun JPEG, maks. 800×800. MODULR konverterer automatisk.

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ArtworkImage {
    static let maxSide = 800

    /// Laver et CDJ-venligt JPEG: maks. 800×800, uden gennemsigtighed, høj kvalitet.
    static func cdjJPEG(from url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return jpeg(src, maxSide: maxSide)
    }

    static func cdjJPEG(data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(src, maxSide: maxSide)
    }

    /// Et billede du sender (screenshot, foto, et cover i forkert format) gøres til et kvadratisk cover:
    /// ensfarvede kanter rundt om (fx baggrunden i et screenshot) skæres væk, og resten beskæres i midten
    /// til et kvadrat. Er billedet allerede kvadratisk, røres det ikke (så et cover med hvid kant forbliver helt).
    /// Returnerer et JPEG (maks. 1400 px) og om noget blev ændret.
    static func fitSquare(data: Data) -> (data: Data, changed: Bool)? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let W = img.width, H = img.height
        guard W > 8, H > 8 else { return nil }
        let ratio = Double(max(W, H)) / Double(min(W, H))
        if ratio <= 1.03 { return libraryJPEG(data: data).map { ($0, false) } }

        // Analysér en lille kopi (højst 400 px) for ensfarvede kanter
        let scale = min(1.0, 400.0 / Double(max(W, H)))
        let w = max(8, Int(Double(W) * scale)), h = max(8, Int(Double(H) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        // Række 0 i bufferen er den øverste i billedet
        let px = Array(UnsafeBufferPointer(start: base.bindMemory(to: UInt8.self, capacity: rowBytes * h), count: rowBytes * h))
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = y * rowBytes + x * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
            let dr: Int = abs(a.0 - b.0)
            let dg: Int = abs(a.1 - b.1)
            let db: Int = abs(a.2 - b.2)
            return dr + dg + db < 36
        }
        /// En linje er "kant", hvis næsten alle punkter ligner kantfarven.
        func uniformRow(_ y: Int, _ c: (Int, Int, Int), _ x0: Int, _ x1: Int) -> Bool {
            var bad = 0
            for x in stride(from: x0, to: x1, by: 2) where !close(pixel(x, y), c) { bad += 1 }
            return bad <= max(1, (x1 - x0) / 2 / 50)
        }
        func uniformCol(_ x: Int, _ c: (Int, Int, Int), _ y0: Int, _ y1: Int) -> Bool {
            var bad = 0
            for y in stride(from: y0, to: y1, by: 2) where !close(pixel(x, y), c) { bad += 1 }
            return bad <= max(1, (y1 - y0) / 2 / 50)
        }
        var top = 0, bottom = h - 1, left = 0, right = w - 1
        let topC = pixel(w / 2, 0), botC = pixel(w / 2, h - 1), leftC = pixel(0, h / 2), rightC = pixel(w - 1, h / 2)
        while top < h * 2 / 5 && uniformRow(top, topC, left, right) { top += 1 }
        while bottom > h * 3 / 5 && uniformRow(bottom, botC, left, right) { bottom -= 1 }
        while left < w * 2 / 5 && uniformCol(left, leftC, top, bottom) { left += 1 }
        while right > w * 3 / 5 && uniformCol(right, rightC, top, bottom) { right -= 1 }

        // Tilbage til fuld opløsning, og beskær midten til et kvadrat
        let fx = Double(W) / Double(w), fy = Double(H) / Double(h)
        var r = CGRect(x: Double(left) * fx, y: Double(top) * fy,
                       width: Double(right - left + 1) * fx, height: Double(bottom - top + 1) * fy)
        let side = min(r.width, r.height)
        r = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side).integral
        r = r.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard r.width >= 32, let crop = img.cropping(to: r) else { return nil }
        let outSide = min(1400, Int(r.width))
        guard let out = CGContext(data: nil, width: outSide, height: outSide, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        out.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: outSide, height: outSide))
        out.interpolationQuality = .high
        out.draw(crop, in: CGRect(x: 0, y: 0, width: outSide, height: outSide))
        guard let final = out.makeImage() else { return nil }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, final, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (d as Data, true)
    }

    /// Bibliotekets kopi gemmes i højere opløsning (maks. 1400), så den kan bruges igen senere.
    static func libraryJPEG(data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(src, maxSide: 1400)
    }

    /// Kvadratisk JPEG (beskåret i midten) i en bestemt størrelse – fx 80 og 240 px til CDJ'en.
    static func squareJPEG(data: Data, side: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let s = min(img.width, img.height)
        guard let crop = img.cropping(to: CGRect(x: (img.width - s) / 2, y: (img.height - s) / 2, width: s, height: s)),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let out = ctx.makeImage() else { return nil }
        let d = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(d, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? d as Data : nil
    }

    static func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func jpeg(_ src: CGImageSource, maxSide: Int) -> Data? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        // Flad gennemsigtighed ud på sort (JPEG har ingen alfa)
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Indlejret artwork i en fil (til forhåndsvisning).
    static func embedded(in url: URL) -> NSImage? {
        guard let tag = try? AudioTagger.readTag(of: url), let parsed = ID3.parse(tag),
              let apic = parsed.frames.first(where: { $0.id == "APIC" }),
              let data = ID3.pictureData(apic) else { return nil }
        return NSImage(data: data)
    }
}

struct ArtworkRow: Identifiable {
    let id = UUID()
    let url: URL
    var hasArtwork: Bool
    var status: String?
    var ok: Bool?
}

final class ArtworkModel: ObservableObject {
    @Published var rows: [ArtworkRow] = []
    @Published var imageURL: URL?
    @Published var jpeg: Data?
    @Published var preview: NSImage?
    @Published var busy = false
    @Published var imageInfo: String?

    static let audioExts: Set<String> = ["wav", "aif", "aiff", "mp3"]

    func addFiles(_ urls: [URL]) {
        var known = Set(rows.map(\.url.path))
        for u in urls {
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            let files: [URL]
            if isDir.boolValue {
                let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                var list = [URL]()
                while let f = en?.nextObject() as? URL { list.append(f) }
                files = list
            } else {
                files = [u]
            }
            for f in files where Self.audioExts.contains(f.pathExtension.lowercased()) && known.insert(f.path).inserted {
                rows.append(ArtworkRow(url: f, hasArtwork: ArtworkImage.embedded(in: f) != nil))
            }
        }
    }

    /// Sangen coveret er hentet fra (gemmes i Artwork-biblioteket under dens navn, når du lægger det på).
    var sourceSong: SongInfo?
    var sourceRaw: Data?

    func setImage(_ url: URL) {
        // En lydfil: hent kun dens cover
        if ArtworkLibrary.audioExts.contains(url.pathExtension.lowercased()) {
            Task {
                let raw = await ArtworkLibrary.extract(from: url)
                await MainActor.run {
                    guard let raw, let data = ArtworkImage.cdjJPEG(data: raw), let img = NSImage(data: data) else {
                        imageInfo = "\"\(url.lastPathComponent)\" har intet artwork"
                        return
                    }
                    imageURL = url
                    jpeg = data
                    preview = img
                    sourceRaw = raw
                    sourceSong = ArtworkLibrary.song(for: url)
                    let px = img.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
                    imageInfo = "Hentet fra \(url.lastPathComponent) · \(px) – klar til CDJ"
                }
            }
            return
        }
        sourceSong = nil
        sourceRaw = nil
        // Screenshot/foto i forkert format → kvadratisk cover (kanter væk, beskåret i midten)
        let raw = try? Data(contentsOf: url)
        let fitted = raw.flatMap { ArtworkImage.fitSquare(data: $0) }
        guard let data = (fitted?.data ?? raw).flatMap({ ArtworkImage.cdjJPEG(data: $0) }), let img = NSImage(data: data) else {
            imageInfo = "Billedet kunne ikke læses"
            return
        }
        imageURL = url
        jpeg = data
        preview = img
        let px = img.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
        imageInfo = (fitted?.changed == true ? "Tilpasset til kvadrat · " : "") + "JPEG \(px) · \(data.count / 1024) KB – klar til CDJ"
    }

    func apply() {
        guard let jpeg else { return }
        busy = true
        let targets = rows
        let source = sourceSong, raw = sourceRaw ?? jpeg, from = imageURL?.lastPathComponent ?? "billede"
        DispatchQueue.global(qos: .userInitiated).async {
            // Husk coveret under kildens og filernes navne – så bedre versioner senere får det automatisk
            if let source { ArtworkLibrary.shared.add(raw, song: source, source: "Fra fil: \(from)") }
            for r in targets {
                if let song = ArtworkLibrary.song(for: r.url) {
                    ArtworkLibrary.shared.add(raw, song: song, source: "Manuelt: \(from)", file: r.url)
                }
            }
            var updated = targets
            for i in updated.indices {
                do {
                    try AudioTagger.setFrames([ID3.pictureFrame(jpeg: jpeg)], on: updated[i].url)
                    updated[i].ok = true
                    updated[i].hasArtwork = true
                    updated[i].status = "Artwork tilføjet"
                } catch {
                    updated[i].ok = false
                    updated[i].status = error.localizedDescription
                }
            }
            let result = updated
            DispatchQueue.main.async {
                self.rows = result
                self.busy = false
            }
        }
    }
}

struct ManualArtworkView: View {
    @EnvironmentObject var model: ArtworkModel
    @State private var filesTargeted = false
    @State private var imageTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            // Filer
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Button("Tilføj filer eller mapper…") { pickFiles() }
                        .buttonStyle(.ember)
                    Spacer()
                    if !model.rows.isEmpty { Button("Ryd") { model.rows = [] } }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                if model.rows.isEmpty {
                    DropZone(icon: "waveform.circle", title: "Træk WAV-, AIFF- eller MP3-filer herind",
                             subtitle: "Vælg derefter et billede til højre – det lægges på alle filerne som CDJ-venligt JPEG.",
                             targeted: filesTargeted)
                } else {
                    List(model.rows) { r in
                        HStack {
                            Text(r.ok == true ? "✅" : (r.ok == false ? "⛔️" : (r.hasArtwork ? "🖼" : "▫️")))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.url.lastPathComponent).lineLimit(1)
                                Text(r.status ?? (r.hasArtwork ? "Har artwork – bliver udskiftet" : "Intet artwork"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.hairline, lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                    }
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $filesTargeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.addFiles([url]) } }
                    }
                }
                return true
            }

            Divider()

            // Billede
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(imageTargeted ? Color.ember.opacity(0.15) : Color.white.opacity(0.04))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(imageTargeted ? Color.ember : Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1.2, dash: [7, 6]))
                    if let img = model.preview {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(8)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.system(size: 40))
                                .foregroundColor(.ember)
                            Text("Træk et billede – eller en sang med cover – herind").multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(width: 280, height: 280)
                .onDrop(of: [UTType.fileURL], isTargeted: $imageTargeted) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.setImage(url) } }
                    }
                    return true
                }
                Button("Vælg billede eller sang…") { pickImage() }
                if let info = model.imageInfo {
                    Text(info).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.busy ? "Skriver…" : "Tilføj artwork til \(model.rows.count) fil\(model.rows.count == 1 ? "" : "er")") {
                    model.apply()
                }
                .buttonStyle(.ember)
                .disabled(model.jpeg == nil || model.rows.isEmpty || model.busy)
                Text("Billedet gemmes som JPEG (maks. 800×800), som Pioneer kræver. I rekordbox: højreklik på sporene → \"Reload Tag\" før du eksporterer til USB.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 280)
                Spacer()
            }
            .padding(20)
            .frame(width: 330)
            .background(Color.white.opacity(0.02))
        }
    }

    func pickFiles() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { model.addFiles(p.urls) }
    }

    func pickImage() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.allowedContentTypes = [.image, .audio]
        if p.runModal() == .OK, let u = p.url { model.setImage(u) }
    }
}
