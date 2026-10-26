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

    /// Bibliotekets kopi gemmes i højere opløsning (maks. 1400), så den kan bruges igen senere.
    static func libraryJPEG(data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(src, maxSide: 1400)
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

    func setImage(_ url: URL) {
        guard let data = ArtworkImage.cdjJPEG(from: url), let img = NSImage(data: data) else {
            imageInfo = "Billedet kunne ikke læses"
            return
        }
        imageURL = url
        jpeg = data
        preview = img
        let px = img.representations.first.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? ""
        imageInfo = "JPEG \(px) · \(data.count / 1024) KB – klar til CDJ"
    }

    func apply() {
        guard let jpeg else { return }
        busy = true
        let targets = rows
        DispatchQueue.global(qos: .userInitiated).async {
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
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    if !model.rows.isEmpty { Button("Ryd") { model.rows = [] } }
                }
                .padding(10)
                .background(Color.graphite)
                Divider()
                if model.rows.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.ember)
                        Text("Træk WAV-, AIFF- eller MP3-filer herind")
                            .font(.title3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(filesTargeted ? Color.ember.opacity(0.12) : Color.void)
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
                    RoundedRectangle(cornerRadius: 10)
                        .fill(imageTargeted ? Color.ember.opacity(0.15) : Color.graphite)
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
                            Text("Træk et billede herind")
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
                Button("Vælg billede…") { pickImage() }
                if let info = model.imageInfo {
                    Text(info).font(.caption).foregroundStyle(.secondary)
                }
                Button(model.busy ? "Skriver…" : "Tilføj artwork til \(model.rows.count) fil\(model.rows.count == 1 ? "" : "er")") {
                    model.apply()
                }
                .buttonStyle(.borderedProminent)
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
            .background(Color.void)
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
        p.allowedContentTypes = [.image]
        if p.runModal() == .OK, let u = p.url { model.setImage(u) }
    }
}
