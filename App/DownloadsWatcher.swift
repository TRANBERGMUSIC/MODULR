// MODULR – holder øje med Overførsler, mens du gennemfører en gate i din egen browser.
// Når en ny lydfil/zip er færdighentet, kopieres den til MODULR (din fil i Overførsler røres ikke)
// og sendes til verifikation. Kildeadressen læses fra macOS' "Hentet fra"-oplysning.

import Foundation

final class DownloadsWatcher {
    static let exts: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "alac", "zip"]
    static let partial: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    private let onFile: (URL, URL?) -> Void
    private let onTimeout: () -> Void
    private var timer: Timer?
    private let started = Date()
    private var known: Set<String> = []
    private var sizes: [String: Int] = [:]
    private let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    init(onFile: @escaping (URL, URL?) -> Void, onTimeout: @escaping () -> Void) {
        self.onFile = onFile
        self.onTimeout = onTimeout
    }

    func start() {
        known = Set(list().map(\.path))
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func list() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    private func tick() {
        if Date().timeIntervalSince(started) > 20 * 60 {
            stop()
            onTimeout()
            return
        }
        for f in list() where !known.contains(f.path) {
            let ext = f.pathExtension.lowercased()
            if Self.partial.contains(ext) { continue }
            guard Self.exts.contains(ext) else { continue }
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Færdig når størrelsen har været den samme i to tjek i træk
            if size > 0, sizes[f.path] == size {
                stop()
                let source = Self.whereFrom(f)
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MODULR-dl-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent(f.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: f, to: copy)
                    onFile(copy, source)
                } catch {
                    onTimeout()
                }
                return
            }
            sizes[f.path] = size
        }
    }

    /// macOS gemmer hvor en fil er hentet fra (kMDItemWhereFroms). Første adresse er selve filen.
    static func whereFrom(_ url: URL) -> URL? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let len = getxattr(url.path, name, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var data = Data(count: len)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, len, 0, 0) }
        guard read > 0,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
              let first = list.first else { return nil }
        return URL(string: first)
    }
}
