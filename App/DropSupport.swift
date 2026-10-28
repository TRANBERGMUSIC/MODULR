// MODULR – træk og slip: filer fra Finder (skrivebordet, Downloads, eksterne drev) og træk inde fra MODULR
// (sange, playlister, USB-sange) modtages af ét fælles sted, så det virker overalt – også oven på tabellen.

import SwiftUI
import UniformTypeIdentifiers

enum DropSupport {
    /// Interne træk i MODULR er tekst med et af disse præfikser.
    static let internalPrefixes = ["node:", "tracks:", "usbtracks:"]

    static let types: [UTType] = [.fileURL, .utf8PlainText, .plainText, .text]

    /// Sang-id'erne i et træk. Trækker man flere valgte sange, sender hver række HELE udvalget –
    /// 5 valgte = 5 × 5 id'er – så de skal tælles én gang (ellers kommer 25 sange med i stedet for 5).
    static func trackIDs(_ items: [String]) -> [UUID] {
        var seen = Set<UUID>()
        var out = [UUID]()
        for s in items where s.hasPrefix("tracks:") {
            for part in s.dropFirst(7).split(separator: ",") {
                if let id = UUID(uuidString: String(part)), seen.insert(id).inserted { out.append(id) }
            }
        }
        return out
    }

    /// Læser alle træk: interne tekster og fil-URL'er. Kaldes på hovedtråden når alt er læst.
    static func read(_ providers: [NSItemProvider], done: @escaping (_ strings: [String], _ files: [URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var strings = [String]()
        var files = [URL]()
        for p in providers {
            group.enter()
            if p.canLoadObject(ofClass: NSString.self), !p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // Kun tekst (et træk inde fra MODULR)
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    if let s = obj as? String, internalPrefixes.contains(where: { s.hasPrefix($0) }) {
                        lock.lock(); strings.append(s); lock.unlock()
                    }
                    group.leave()
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // En fil – men et USB-træk fra MODULR har også en tekst; den foretrækkes, så playlister bruger id'erne
                if p.canLoadObject(ofClass: NSString.self) {
                    _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                        if let s = obj as? String, internalPrefixes.contains(where: { s.hasPrefix($0) }) {
                            lock.lock(); strings.append(s); lock.unlock()
                            group.leave()
                        } else {
                            loadURL(p) { u in
                                if let u { lock.lock(); files.append(u); lock.unlock() }
                                group.leave()
                            }
                        }
                    }
                } else {
                    loadURL(p) { u in
                        if let u { lock.lock(); files.append(u); lock.unlock() }
                        group.leave()
                    }
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) { done(strings, files) }
    }

    private static func loadURL(_ p: NSItemProvider, _ done: @escaping (URL?) -> Void) {
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            done(url?.isFileURL == true ? url : nil)
        }
    }
}

/// Et område der tager imod filer fra Finder (og evt. interne træk) og lyser op mens man trækker hen over det.
struct FileDropArea: ViewModifier {
    @Binding var targeted: Bool
    let strings: (([String]) -> Void)?
    let files: ([URL]) -> Void

    func body(content: Content) -> some View {
        content.onDrop(of: DropSupport.types, isTargeted: $targeted) { providers in
            DropSupport.read(providers) { s, f in
                if !s.isEmpty { strings?(s) }
                if !f.isEmpty { files(f) }
            }
            return true
        }
    }
}

extension View {
    /// Tag imod filer fra Finder (skrivebordet, Downloads …) – og interne MODULR-træk, hvis `strings` er givet.
    func fileDrop(targeted: Binding<Bool>, strings: (([String]) -> Void)? = nil, files: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropArea(targeted: targeted, strings: strings, files: files))
    }
}

/// Vises oven på tabellen mens man trækker filer hen over den.
struct DropHint: View {
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ember.opacity(0.08))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.ember, style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            Label(text, systemImage: "square.and.arrow.down.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.mist)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.graphite))
                .symbolEffect(.bounce, value: text)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}
