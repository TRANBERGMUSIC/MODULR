// MODULR – Bibliotek: Camelot-hjul, playlister og USB til venstre, afspiller øverst og
// sangtabel med RGB-waveform, cover, BPM, toneart, energi, længde og kvalitet.

import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Valg i sidebaren

enum LibSelection: Hashable {
    case smart(SmartList)
    case node(UUID)
    case usb(String, Int?)          // drev-id, playliste-id på USB'en (nil = hele USB'en)
    case usbPending(String, String) // drev-id, ny playlistes nøgle
}

final class LibraryUIState: ObservableObject {
    @Published var selection: LibSelection = .smart(.all)
    @Published var keyFilter: Set<MusicalKey> = []
    @Published var search = ""
    @Published var tableSelection: Set<UUID> = []
}

// MARK: - Afspiller

final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var track: LibTrack?
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ t: LibTrack, autoplay: Bool = true) {
        stop()
        track = t
        guard let p = try? AVAudioPlayer(contentsOf: t.url) else { return }
        p.delegate = self
        p.prepareToPlay()
        player = p
        duration = p.duration
        position = 0
        if autoplay { play() }
    }

    func play() {
        guard let p = player else { return }
        p.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.position = p.currentTime
        }
    }

    func pause() {
        player?.pause()
        playing = false
        timer?.invalidate()
    }

    func toggle() { playing ? pause() : play() }

    func seek(_ fraction: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, fraction * p.duration))
        position = p.currentTime
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        playing = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.playing = false
            self.timer?.invalidate()
        }
    }
}

// MARK: - Sortering i tabellen

extension LibTrack {
    var sortBPM: Double { bpm ?? 0 }
    var sortKey: Int {
        guard let k = key else { return 99 }
        let ab: Int = k.minor ? 0 : 1
        return k.camelotNumber * 2 + ab
    }
    var sortEnergy: Int { energy ?? 0 }
    var sortDuration: Double { duration ?? 0 }
    var sortQuality: Int { tierKbps ?? 0 }
    var sortAdded: Double { addedAt.timeIntervalSince1970 }
}

// MARK: - Skærmen

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var usb: UsbStore
    @StateObject private var ui = LibraryUIState()
    @StateObject private var player = PlayerModel()

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar()
                .frame(width: 280)
            Rectangle().fill(Color.hairline).frame(width: 1)
            VStack(spacing: 0) {
                PlayerPanel()
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                switch ui.selection {
                case .usb(let drive, let node):
                    UsbPlaylistView(driveID: drive, nodeID: node)
                case .usbPending(let drive, let key):
                    UsbPendingView(driveID: drive, key: key)
                default:
                    TrackListView()
                }
            }
        }
        .environmentObject(ui)
        .environmentObject(player)
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var ui: LibraryUIState
    @State private var naming: NamePrompt?

    struct NamePrompt: Identifiable {
        let id = UUID()
        var title: String
        var text: String
        var action: (String) -> Void
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CamelotWheel(selected: $ui.keyFilter)
                    .frame(height: 220)
                    .padding(.horizontal, 12)
                if !ui.keyFilter.isEmpty {
                    HStack {
                        Text("Filter: " + ui.keyFilter.map(\.camelot).sorted().joined(separator: ", "))
                            .font(.system(size: 11)).foregroundColor(.mist.opacity(0.6))
                        Spacer()
                        Button("Nulstil") { ui.keyFilter = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.ember)
                    }
                    .padding(.horizontal, 16)
                }

                Button {
                    addTracks()
                } label: {
                    Label("Tilføj sange", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.ember)
                .padding(.horizontal, 14)

                sectionHeader("BIBLIOTEK")
                VStack(spacing: 2) {
                    ForEach(SmartList.allCases) { s in
                        let count = library.index.tracks.filter(s.matches).count
                        SideRow(icon: s.icon, title: s.rawValue, count: count, active: ui.selection == .smart(s)) {
                            ui.selection = .smart(s)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            library.importFiles(urls)
                            return true
                        }
                    }
                }
                .padding(.horizontal, 8)

                HStack {
                    sectionHeader("PLAYLISTER")
                    Spacer()
                    Menu {
                        Button("Ny playliste") { prompt("Ny playliste", "Ny playliste") { _ = library.createNode(name: $0, parent: nil, folder: false) } }
                        Button("Ny mappe") { prompt("Ny mappe", "Ny mappe") { _ = library.createNode(name: $0, parent: nil, folder: true) } }
                    } label: {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.emberGradient)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(.trailing, 14)
                }
                VStack(spacing: 2) {
                    NodeTree(parent: nil, depth: 0, prompt: prompt)
                }
                .padding(.horizontal, 8)
                .dropDestination(for: String.self) { items, _ in
                    // Træk en playliste/mappe ud på roden
                    for s in items where s.hasPrefix("node:") {
                        if let id = UUID(uuidString: String(s.dropFirst(5))) { library.move(id, under: nil) }
                    }
                    return true
                }

                HStack {
                    sectionHeader("USB")
                    Spacer()
                    Button { usb.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundColor(.mist.opacity(0.5)).padding(.trailing, 16)
                }
                if usb.drives.isEmpty {
                    Text("Sæt et USB-stik i, som er sat op med rekordbox.")
                        .font(.system(size: 11)).foregroundColor(.mist.opacity(0.4))
                        .padding(.horizontal, 18)
                }
                ForEach(usb.drives) { d in
                    UsbTree(drive: d, prompt: prompt)
                        .padding(.horizontal, 8)
                }
                Spacer(minLength: 20)
            }
            .padding(.top, 14)
        }
        .background(Color.graphite.opacity(0.6))
        .alert(naming?.title ?? "", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Navn", text: Binding(get: { naming?.text ?? "" }, set: { naming?.text = $0 }))
            Button("Opret") {
                if let n = naming, !n.text.trimmingCharacters(in: .whitespaces).isEmpty { n.action(n.text.trimmingCharacters(in: .whitespaces)) }
                naming = nil
            }
            Button("Annullér", role: .cancel) { naming = nil }
        }
    }

    func prompt(_ title: String, _ text: String, _ action: @escaping (String) -> Void) {
        naming = NamePrompt(title: title, text: text, action: action)
    }

    func sectionHeader(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .bold))
            .tracking(2)
            .foregroundColor(.mist.opacity(0.35))
            .padding(.horizontal, 18)
            .padding(.top, 4)
    }

    func addTracks() {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.prompt = "Tilføj"
        if p.runModal() == .OK {
            var target: UUID?
            if case .node(let id) = ui.selection, library.index.nodes.first(where: { $0.id == id })?.isFolder == false { target = id }
            library.importFiles(p.urls, into: target)
        }
    }
}

struct SideRow: View {
    let icon: String
    let title: String
    var count: Int?
    let active: Bool
    var italic = false
    let action: () -> Void
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(active ? AnyShapeStyle(Color.emberGradient) : AnyShapeStyle(Color.mist.opacity(0.55)))
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .italic(italic)
                    .foregroundColor(active ? .mist : .mist.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color.ember.opacity(0.14) : Color.white.opacity(hover ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Mapper og playlister (rekursivt).
struct NodeTree: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var ui: LibraryUIState
    let parent: UUID?
    let depth: Int
    let prompt: (String, String, @escaping (String) -> Void) -> Void

    var body: some View {
        ForEach(library.index.children(of: parent)) { n in
            NodeRow(node: n, depth: depth, prompt: prompt)
        }
    }
}

struct NodeRow: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var ui: LibraryUIState
    let node: LibNode
    let depth: Int
    let prompt: (String, String, @escaping (String) -> Void) -> Void
    @State private var open = true
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                if node.isFolder {
                    Button { open.toggle() } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.mist.opacity(0.5)).frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14)
                }
                SideRow(icon: node.isFolder ? "folder.fill" : "music.note.list", title: node.name,
                        count: node.isFolder ? nil : node.trackIDs.count, active: ui.selection == .node(node.id)) {
                    ui.selection = .node(node.id)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .background(RoundedRectangle(cornerRadius: 8).stroke(targeted ? Color.ember : Color.clear, lineWidth: 1.5))
            .draggable("node:\(node.id.uuidString)")
            .dropDestination(for: String.self) { items, _ in
                for s in items {
                    if s.hasPrefix("node:"), let id = UUID(uuidString: String(s.dropFirst(5))), node.isFolder {
                        library.move(id, under: node.id)
                    } else if s.hasPrefix("tracks:"), !node.isFolder {
                        let ids = s.dropFirst(7).split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                        library.add(ids, to: node.id)
                    }
                }
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                if node.isFolder {
                    Button("Ny playliste i mappen") { prompt("Ny playliste", "Ny playliste") { _ = library.createNode(name: $0, parent: node.id, folder: false) } }
                    Button("Ny mappe i mappen") { prompt("Ny mappe", "Ny mappe") { _ = library.createNode(name: $0, parent: node.id, folder: true) } }
                    Divider()
                }
                Button("Omdøb…") { prompt("Omdøb", node.name) { library.rename(node.id, to: $0) } }
                if node.parent != nil { Button("Flyt ud på øverste niveau") { library.move(node.id, under: nil) } }
                Divider()
                Button("Slet", role: .destructive) {
                    if ui.selection == .node(node.id) { ui.selection = .smart(.all) }
                    library.deleteNode(node.id)
                }
            }
            if node.isFolder && open {
                NodeTree(parent: node.id, depth: depth + 1, prompt: prompt)
            }
        }
    }
}

// MARK: - Camelot-hjul

struct CamelotWheel: View {
    @Binding var selected: Set<MusicalKey>
    @EnvironmentObject var player: PlayerModel

    static func color(_ k: MusicalKey, alpha: Double = 1) -> Color {
        let hue: Double = k.hue / 360
        let sat: Double = k.minor ? 0.42 : 0.55
        let bri: Double = k.minor ? 0.98 : 0.92
        return Color(hue: hue, saturation: sat, brightness: bri, opacity: alpha)
    }

    static let allKeys: [MusicalKey] = (1...12).flatMap { n in
        [MusicalKey(camelotNumber: n, minor: false)!, MusicalKey(camelotNumber: n, minor: true)!]
    }

    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(Self.allKeys, id: \.self) { k in
                    WheelSegment(key: k, center: center, size: size, selected: $selected,
                                 current: player.track?.key,
                                 compatible: player.track?.key?.compatible ?? [])
                }
                WheelCenter(key: player.track?.key, center: center, size: size)
            }
        }
    }
}

struct WheelSegment: View {
    let key: MusicalKey
    let center: CGPoint
    let size: CGFloat
    @Binding var selected: Set<MusicalKey>
    let current: MusicalKey?
    let compatible: [MusicalKey]

    var body: some View {
        let n: Int = key.camelotNumber
        let start = Angle(degrees: Double(n - 1) * 30 - 105)
        let end = Angle(degrees: Double(n) * 30 - 105)
        let rInner: CGFloat = size * 0.19
        let rMid: CGFloat = size * 0.34
        let rOuter: CGFloat = size / 2
        let r0: CGFloat = key.minor ? rInner : rMid
        let r1: CGFloat = (key.minor ? rMid : rOuter) - 1.5
        let isSel: Bool = selected.contains(key)
        let isCur: Bool = current == key
        let fade: Bool = !selected.isEmpty && !isSel
        let alpha: Double = fade ? 0.28 : (compatible.contains(key) ? 1.0 : 0.85)
        let strokeColor: Color = isCur ? Color.white : (isSel ? Color.void : Color.clear)
        let lineWidth: CGFloat = isCur ? 2.5 : 1.5
        let mid: Double = (start.radians + end.radians) / 2
        let rl: CGFloat = (r0 + r1) / 2
        let px: CGFloat = center.x + CGFloat(cos(mid)) * rl
        let py: CGFloat = center.y + CGFloat(sin(mid)) * rl
        let shape = RingSegment(center: center, r0: r0, r1: r1, start: start, end: end)
        let fontSize: CGFloat = key.minor ? 9 : 10
        let textAlpha: Double = fade ? 0.4 : 0.85
        return ZStack {
            shape.fill(CamelotWheel.color(key, alpha: alpha))
            shape.stroke(strokeColor, lineWidth: lineWidth)
            Text(key.camelot)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(Color.void.opacity(textAlpha))
                .position(x: px, y: py)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
        .onTapGesture {
            if isSel { selected.remove(key) } else { selected.insert(key) }
        }
    }
}

struct WheelCenter: View {
    let key: MusicalKey?
    let center: CGPoint
    let size: CGFloat

    var body: some View {
        let d: CGFloat = size * 0.38 - 4
        return ZStack {
            Circle().fill(Color.void).frame(width: d, height: d).position(center)
            if let k = key {
                VStack(spacing: 0) {
                    Text(k.camelot).font(.system(size: 18, weight: .bold)).foregroundColor(CamelotWheel.color(k))
                    Text(k.classic).font(.system(size: 10)).foregroundColor(Color.mist.opacity(0.6))
                }
                .position(center)
            } else {
                Image(systemName: "dial.medium").foregroundColor(Color.mist.opacity(0.3)).position(center)
            }
        }
    }
}

struct RingSegment: Shape {
    let center: CGPoint
    let r0: CGFloat
    let r1: CGFloat
    let start: Angle
    let end: Angle

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: center, radius: r1, startAngle: start + .degrees(0.8), endAngle: end - .degrees(0.8), clockwise: false)
        p.addArc(center: center, radius: r0, startAngle: end - .degrees(0.8), endAngle: start + .degrees(0.8), clockwise: true)
        p.closeSubpath()
        return p
    }
}

// MARK: - Afspiller-panel

struct PlayerPanel: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        Panel(padding: 14) {
            HStack(spacing: 16) {
                Cover(track: player.track, size: 76)
                VStack(alignment: .leading, spacing: 8) {
                    if let t = player.track {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.mist).lineLimit(1)
                                Text(t.artist.isEmpty ? "Ukendt kunstner" : t.artist).font(.system(size: 12)).foregroundColor(.mist.opacity(0.55)).lineLimit(1)
                            }
                            Spacer()
                            if let k = t.key { KeyPill(key: k) }
                            Text(t.bpmText + " BPM").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(.mist.opacity(0.8))
                            QualityText(track: t)
                        }
                        BigWaveform(track: t)
                            .frame(height: 54)
                    } else {
                        Text("Dobbeltklik på en sang for at afspille den")
                            .font(.system(size: 15, weight: .semibold)).foregroundColor(.mist)
                        Text("Se waveform, BPM, toneart og kvalitet – og hør om filen er god nok til klubben.")
                            .font(.system(size: 12)).foregroundColor(.mist.opacity(0.5))
                    }
                }
                Button {
                    player.toggle()
                } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.void)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.emberGradient))
                        .shadow(color: Color.ember.opacity(0.4), radius: 10)
                }
                .buttonStyle(.plain)
                .disabled(player.track == nil)
            }
        }
    }
}

struct BigWaveform: View {
    @EnvironmentObject var player: PlayerModel
    @EnvironmentObject var library: LibraryStore
    let track: LibTrack

    var body: some View {
        GeometryReader { geo in
            let frac: CGFloat = player.duration > 0 ? CGFloat(player.position / player.duration) : 0
            let w: CGFloat = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                if let img = WaveformCache.shared.image(for: track, width: 1200, height: 80, store: library) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                        .opacity(0.45)
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                        .mask(alignment: .leading) { Rectangle().frame(width: w * frac) }
                } else {
                    Text(library.analyzing.contains(track.id) ? "Analyserer …" : "Ingen waveform endnu")
                        .font(.caption).foregroundColor(.mist.opacity(0.4)).frame(maxWidth: .infinity)
                }
                Rectangle().fill(Color.white).frame(width: 2).offset(x: w * frac - 1)
                HStack {
                    Text(timeText(player.position))
                    Spacer()
                    Text("-" + timeText(max(0, player.duration - player.position)))
                }
                .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundColor(.mist.opacity(0.7))
                .padding(.horizontal, 6).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in player.seek(Double(v.location.x / w)) })
        }
    }

    func timeText(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

struct Cover: View {
    @EnvironmentObject var library: LibraryStore
    let track: LibTrack?
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size > 50 ? 10 : 5, style: .continuous).fill(Color.white.opacity(0.06))
            if let t = track, let img = CoverCache.image(t, library: library) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.35)).foregroundColor(.mist.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 50 ? 10 : 5, style: .continuous))
    }
}

enum CoverCache {
    static let cache = NSCache<NSString, NSImage>()

    static func image(_ t: LibTrack, library: LibraryStore) -> NSImage? {
        guard let f = t.artFile, let u = library.artURL(t) else { return nil }
        if let img = cache.object(forKey: f as NSString) { return img }
        guard let img = NSImage(contentsOf: u) else { return nil }
        cache.setObject(img, forKey: f as NSString)
        return img
    }
}

struct KeyPill: View {
    let key: MusicalKey

    var body: some View {
        Text(key.camelot)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.void.opacity(0.85))
            .frame(minWidth: 40)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(CamelotWheel.color(key)))
    }
}

struct QualityText: View {
    let track: LibTrack

    var color: Color {
        switch track.qualityColor {
        case .red: return Color(red: 1, green: 0.32, blue: 0.3)
        case .yellow: return Color(red: 1, green: 0.82, blue: 0.3)
        case .green: return Color(red: 0.35, green: 0.9, blue: 0.5)
        case nil: return .mist.opacity(0.4)
        }
    }

    var body: some View {
        Text(track.qualityText)
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .foregroundColor(color)
            .help(track.qualityLabel)
    }
}

// MARK: - Sangtabellen

struct TrackListView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var settings: FBSettings
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var ui: LibraryUIState
    @EnvironmentObject var player: PlayerModel
    static let defaultSort: [KeyPathComparator<LibTrack>] = [KeyPathComparator(\LibTrack.sortAdded, order: .reverse)]
    @State private var sortOrder: [KeyPathComparator<LibTrack>] = TrackListView.defaultSort
    @State private var targeted = false
    @State private var confirmForce: (UUID, URL, String)?
    @State private var newUsbPlaylist: (UsbDrive, [UUID])?
    @State private var newUsbName = ""

    var title: String {
        switch ui.selection {
        case .smart(let s): return s.rawValue
        case .node(let id): return library.index.nodes.first { $0.id == id }?.name ?? "Playliste"
        default: return ""
        }
    }

    var currentPlaylist: UUID? {
        if case .node(let id) = ui.selection, library.index.nodes.first(where: { $0.id == id })?.isFolder == false { return id }
        return nil
    }

    var rows: [LibTrack] {
        var list: [LibTrack]
        switch ui.selection {
        case .smart(let s): list = library.index.tracks.filter(s.matches)
        case .node(let id):
            if let n = library.index.nodes.first(where: { $0.id == id }) { list = library.index.tracks(in: n) } else { list = [] }
        default: list = []
        }
        if !ui.keyFilter.isEmpty { list = list.filter { $0.key.map(ui.keyFilter.contains) ?? false } }
        let q = ui.search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q) || $0.album.localizedCaseInsensitiveContains(q) }
        }
        // Playlister vises i deres egen rækkefølge, indtil man sorterer
        let unsorted: Bool = sortOrder == TrackListView.defaultSort
        if currentPlaylist != nil && unsorted { return list }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(title.uppercased()).font(.system(size: 13, weight: .bold)).tracking(1.5).foregroundColor(.mist)
                Text("(\(rows.count) sange)").font(.system(size: 12)).foregroundColor(.mist.opacity(0.45))
                if !library.analyzing.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Analyserer \(library.analyzing.count) …").font(.system(size: 11)).foregroundColor(.mist.opacity(0.5))
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.mist.opacity(0.4))
                    TextField("Søg", text: $ui.search).textFieldStyle(.plain).frame(width: 180)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let m = library.lastMessage {
                HStack {
                    Text(m).font(.system(size: 12)).foregroundColor(.mist.opacity(0.75))
                    Spacer()
                    Button { library.lastMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundColor(.mist.opacity(0.4))
                }
                .padding(.horizontal, 20).padding(.bottom, 6)
            }

            if library.index.tracks.isEmpty {
                DropZone(icon: "square.stack.3d.down.right", title: "Træk din musik herind",
                         subtitle: "Alle sange du sætter ind i MODULR havner i biblioteket: BPM, toneart, energi, RGB-waveform og den reelle kvalitet bliver analyseret automatisk.",
                         targeted: targeted)
            } else {
                Table(of: LibTrack.self, selection: $ui.tableSelection, sortOrder: $sortOrder) {
                    TableColumn("") { t in
                        MiniWave(track: t).frame(width: 96, height: 26)
                    }
                    .width(104)
                    TableColumn("") { t in Cover(track: t, size: 28) }.width(34)
                    TableColumn("Kunstner", value: \.artist) { t in
                        Text(t.artist.isEmpty ? "Ukendt" : t.artist).foregroundColor(t.artist.isEmpty ? .mist.opacity(0.4) : .mist.opacity(0.85)).lineLimit(1)
                    }
                    .width(min: 110, ideal: 170)
                    TableColumn("Titel", value: \.title) { t in
                        HStack(spacing: 5) {
                            if library.analyzing.contains(t.id) { ProgressView().controlSize(.mini) }
                            if library.working.contains(t.id) { Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.ember) }
                            Text(t.title).foregroundColor(.mist).lineLimit(1)
                        }
                        .help(t.path)
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("Key", value: \.sortKey) { t in
                        if let k = t.key { KeyPill(key: k) } else { Text("–").foregroundColor(.mist.opacity(0.3)) }
                    }
                    .width(56)
                    TableColumn("BPM", value: \.sortBPM) { t in Text(t.bpmText).monospacedDigit().foregroundColor(.mist) }.width(48)
                    TableColumn("Toneart", value: \.sortKey) { t in Text(t.key?.classic ?? "–").foregroundColor(.mist.opacity(0.7)) }.width(58)
                    TableColumn("Energi", value: \.sortEnergy) { t in EnergyBar(value: t.energy) }.width(70)
                    Group {
                        TableColumn("Længde", value: \.sortDuration) { t in Text(t.durationText).monospacedDigit().foregroundColor(.mist.opacity(0.7)) }.width(56)
                        TableColumn("Kvalitet", value: \.sortQuality) { t in QualityText(track: t) }.width(min: 80, ideal: 104)
                        TableColumn("Format") { t in Text(t.codec).font(.system(size: 11)).foregroundColor(.mist.opacity(0.5)) }.width(50)
                    }
                } rows: {
                    ForEach(rows) { t in
                        TableRow(t)
                            .draggable(dragPayload(for: t))
                    }
                }
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    contextMenu(ids)
                } primaryAction: { ids in
                    if let id = ids.first, let t = library.index.track(id) { player.load(t) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.importFiles(urls, into: currentPlaylist)
            return true
        } isTargeted: { targeted = $0 }
        .alert("Er det den rigtige sang?", isPresented: Binding(get: { confirmForce != nil }, set: { if !$0 { confirmForce = nil } })) {
            Button("Udskift alligevel") {
                if let c = confirmForce { replace(c.0, with: c.1, force: true) }
                confirmForce = nil
            }
            Button("Annullér", role: .cancel) { confirmForce = nil }
        } message: { Text(confirmForce?.2 ?? "") }
        .alert("Ny playliste på USB", isPresented: Binding(get: { newUsbPlaylist != nil }, set: { if !$0 { newUsbPlaylist = nil } })) {
            TextField("Navn", text: $newUsbName)
            Button("Opret") {
                if let v = newUsbPlaylist, !newUsbName.isEmpty {
                    let key = usb.newPlaylist(v.0, name: newUsbName, parent: .root, tracks: v.1)
                    ui.selection = .usbPending(v.0.id, key)
                }
                newUsbPlaylist = nil
            }
            Button("Annullér", role: .cancel) { newUsbPlaylist = nil }
        }
    }

    func dragPayload(for t: LibTrack) -> String {
        let ids = ui.tableSelection.contains(t.id) ? Array(ui.tableSelection) : [t.id]
        return "tracks:" + ids.map(\.uuidString).joined(separator: ",")
    }

    @ViewBuilder
    func contextMenu(_ ids: Set<UUID>) -> some View {
        let list = Array(ids)
        if let id = list.first, let t = library.index.track(id) {
            Button("Afspil") { player.load(t) }
            Divider()
            Menu("Tilføj til playliste") {
                ForEach(library.index.nodes.filter { !$0.isFolder }) { n in
                    Button(n.name) { library.add(list, to: n.id) }
                }
            }
            if let pl = currentPlaylist { Button("Fjern fra playlisten") { library.removeFromPlaylist(list, playlist: pl) } }
            if !usb.drives.isEmpty {
                Menu("Send til USB") {
                    ForEach(usb.drives) { d in
                        Menu(d.name) {
                            Button("Ny playliste…") { newUsbName = title; newUsbPlaylist = (d, list) }
                            Divider()
                            ForEach((usb.contents[d.id]?.nodes ?? []).filter { !$0.folder }) { n in
                                Button(n.name) { usb.add(list, to: d, existing: n.id); ui.selection = .usb(d.id, n.id) }
                            }
                        }
                    }
                }
            }
            Divider()
            if list.count == 1 {
                Button("Udskift fil med bedre version…") { pickReplacement(id) }
                Button("Find bedre version gratis…") {
                    app.findBetterRequest = t.url
                    app.tool = .findBetter
                }
            }
            Button("Analysér igen") { library.reanalyze(list) }
            Button("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting(list.compactMap { library.index.track($0)?.url }) }
            Divider()
            Button("Fjern fra biblioteket", role: .destructive) { library.remove(list) }
        }
    }

    func pickReplacement(_ id: UUID) {
        guard let t = library.index.track(id) else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = "Vælg den bedre version af \(t.title) – data og cover bevares"
        if p.runModal() == .OK, let u = p.url { replace(id, with: u, force: false) }
    }

    func replace(_ id: UUID, with url: URL, force: Bool) {
        let rule = settings.rule
        Task {
            do {
                let r = try await library.replaceFile(id, with: url, rule: rule, force: force)
                await MainActor.run { library.lastMessage = "✅ " + r }
            } catch {
                let text = error.localizedDescription
                await MainActor.run {
                    if text.contains("match") || text.contains("version") {
                        confirmForce = (id, url, text + ". Skal filen alligevel erstatte den gamle?")
                    } else {
                        library.lastMessage = "⛔️ \(text) – intet er ændret."
                    }
                }
            }
        }
    }
}

struct MiniWave: View {
    @EnvironmentObject var library: LibraryStore
    let track: LibTrack

    var body: some View {
        if track.hasWave, let img = WaveformCache.shared.image(for: track, width: 120, height: 30, store: library) {
            Image(decorative: img, scale: 1).resizable().interpolation(.medium)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.04))
        }
    }
}

struct EnergyBar: View {
    let value: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(value.map(String.init) ?? "–").monospacedDigit().foregroundColor(.mist).frame(width: 16, alignment: .trailing)
            if let v = value {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Color.emberGradient).frame(width: g.size.width * CGFloat(v) / 10)
                    }
                }
                .frame(height: 4)
            }
        }
    }
}

// MARK: - USB i sidebaren

struct UsbTree: View {
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var ui: LibraryUIState
    let drive: UsbDrive
    let prompt: (String, String, @escaping (String) -> Void) -> Void
    @State private var open = true

    var body: some View {
        let c = usb.contents[drive.id]
        let pending = usb.pending[drive.id] ?? []
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundColor(.mist.opacity(0.5)).frame(width: 14)
                }
                .buttonStyle(.plain)
                SideRow(icon: "externaldrive.fill", title: drive.name, count: c?.tracks?.count,
                        active: ui.selection == .usb(drive.id, nil)) { ui.selection = .usb(drive.id, nil) }
            }
            .contextMenu {
                Button("Ny playliste…") { prompt("Ny playliste på \(drive.name)", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .root) } }
                Button("Ny mappe…") { prompt("Ny mappe på \(drive.name)", "Ny mappe") { usb.newFolder(drive, name: $0, parent: .root) } }
                Divider()
                Button("Læs igen") { usb.load(drive) }
                Button("Skub ud") { usb.eject(drive) }
            }
            if open {
                if usb.loading.contains(drive.id) { ProgressView().controlSize(.small).padding(4) }
                if let err = c?.error, c?.ok == false {
                    Text(err).font(.system(size: 10)).foregroundColor(.red.opacity(0.8)).padding(.horizontal, 16)
                }
                UsbNodeTree(drive: drive, parent: 0, depth: 1, prompt: prompt)
                ForEach(pending.filter { $0.kind == .playlist && $0.parent == .root }) { p in
                    SideRow(icon: "music.note.list", title: p.name + "  •ny", count: p.tracks.count,
                            active: ui.selection == .usbPending(drive.id, p.key), italic: true) {
                        ui.selection = .usbPending(drive.id, p.key)
                    }
                    .padding(.leading, 14)
                    .dropDestination(for: String.self) { items, _ in
                        usb.add(ids(items), to: drive, newKey: p.key)
                        return true
                    }
                }
                ForEach(pending.filter { $0.kind == .folder && $0.parent == .root }) { f in
                    SideRow(icon: "folder.fill", title: f.name + "  •ny", count: nil, active: false, italic: true) {}
                        .padding(.leading, 14)
                        .contextMenu {
                            Button("Ny playliste i mappen…") { prompt("Ny playliste", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .new(f.key)) } }
                        }
                    ForEach(pending.filter { $0.kind == .playlist && $0.parent == .new(f.key) }) { p in
                        SideRow(icon: "music.note.list", title: p.name + "  •ny", count: p.tracks.count,
                                active: ui.selection == .usbPending(drive.id, p.key), italic: true) {
                            ui.selection = .usbPending(drive.id, p.key)
                        }
                        .padding(.leading, 28)
                        .dropDestination(for: String.self) { items, _ in
                            usb.add(ids(items), to: drive, newKey: p.key)
                            return true
                        }
                    }
                }
            }
        }
    }

    func ids(_ items: [String]) -> [UUID] {
        items.filter { $0.hasPrefix("tracks:") }.flatMap { $0.dropFirst(7).split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
    }
}

struct UsbNodeTree: View {
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var ui: LibraryUIState
    let drive: UsbDrive
    let parent: Int
    let depth: Int
    let prompt: (String, String, @escaping (String) -> Void) -> Void

    /// Værn mod en beskadiget database, hvor en mappe peger på sig selv.
    func usbChildren() -> [UsbNodeInfo] {
        if depth > 24 { return [] }
        let all: [UsbNodeInfo] = usb.contents[drive.id]?.nodes ?? []
        let mine = all.filter { n in n.parent == parent && n.id != parent }
        return mine.sorted { a, b in
            if a.folder != b.folder { return a.folder }
            return a.sort < b.sort
        }
    }

    var body: some View {
        // Værn mod en beskadiget database, hvor en mappe peger på sig selv
        let nodes: [UsbNodeInfo] = usbChildren()
        let pending = usb.pending[drive.id] ?? []
        ForEach(nodes) { n in
            let added = pending.first { $0.kind == .addTo(n.id) }?.tracks.count ?? 0
            SideRow(icon: n.folder ? "folder" : "music.note.list", title: n.name + (added > 0 ? "  +\(added)" : ""),
                    count: n.folder ? nil : n.tracks.count, active: ui.selection == .usb(drive.id, n.id)) {
                ui.selection = .usb(drive.id, n.id)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .dropDestination(for: String.self) { items, _ in
                guard !n.folder else { return false }
                let ids = items.filter { $0.hasPrefix("tracks:") }.flatMap { $0.dropFirst(7).split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
                usb.add(ids, to: drive, existing: n.id)
                return true
            }
            .contextMenu {
                if n.folder {
                    Button("Ny playliste i mappen…") { prompt("Ny playliste", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .existing(n.id)) } }
                    Button("Ny mappe i mappen…") { prompt("Ny mappe", "Ny mappe") { usb.newFolder(drive, name: $0, parent: .existing(n.id)) } }
                }
            }
            if n.folder {
                UsbNodeTree(drive: drive, parent: n.id, depth: depth + 1, prompt: prompt)
                ForEach(pending.filter { $0.parent == .existing(n.id) }) { p in
                    SideRow(icon: p.kind == .folder ? "folder.fill" : "music.note.list", title: p.name + "  •ny",
                            count: p.kind == .folder ? nil : p.tracks.count, active: ui.selection == .usbPending(drive.id, p.key), italic: true) {
                        if p.kind != .folder { ui.selection = .usbPending(drive.id, p.key) }
                    }
                    .padding(.leading, CGFloat(depth + 1) * 14)
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.filter { $0.hasPrefix("tracks:") }.flatMap { $0.dropFirst(7).split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
                        usb.add(ids, to: drive, newKey: p.key)
                        return true
                    }
                }
            }
        }
    }
}

// MARK: - USB i hovedområdet

struct UsbHeader: View {
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var library: LibraryStore
    let drive: UsbDrive
    let title: String

    var body: some View {
        let pending = usb.pending[drive.id] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill").foregroundStyle(Color.emberGradient)
                Text(title.uppercased()).font(.system(size: 13, weight: .bold)).tracking(1.5).foregroundColor(.mist)
                Spacer()
                if usb.writing.contains(drive.id) { ProgressView().controlSize(.small) }
                if !pending.isEmpty {
                    Button("Fortryd") { usb.discard(drive) }
                    Button("Skriv til USB (\(pending.count) ændring\(pending.count == 1 ? "" : "er"))") { usb.commit(drive, library: library) }
                        .buttonStyle(.ember)
                        .disabled(usb.writing.contains(drive.id))
                }
                Button("Skub ud") { usb.eject(drive) }.disabled(usb.writing.contains(drive.id))
            }
            if usb.contents[drive.id]?.onelibrary == true {
                Text("Denne USB har også et OneLibrary (CDJ-3000X, XDJ-AZ, Opus Quad). MODULR skriver i Device Library, som CDJ-3000 læser. Til 3000X: sæt USB'en i rekordbox 7, højreklik på \"OneLibrary\" og vælg \"Convert from Device Library\".")
                    .font(.system(size: 11)).foregroundColor(.amber.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let m = usb.message {
                Text(m).font(.system(size: 12)).foregroundColor(.mist.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Træk sange fra biblioteket over på en playliste under USB i venstre side, eller højreklik på sange → Send til USB. Intet skrives, før du trykker \"Skriv til USB\" – og der tages altid backup af rekordbox-databasen først.")
                .font(.system(size: 11)).foregroundColor(.mist.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct UsbPlaylistView: View {
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var library: LibraryStore
    let driveID: String
    let nodeID: Int?

    var body: some View {
        if let d = usb.drives.first(where: { $0.id == driveID }) {
            let c = usb.contents[d.id]
            let node = c?.nodes?.first { $0.id == nodeID }
            let all = c?.tracks ?? []
            let list: [UsbTrackInfo] = node.map { n in n.tracks.compactMap { id in all.first { $0.id == id } } } ?? all
            let pendingIDs = nodeID.flatMap { id in usb.pending[d.id]?.first { $0.kind == .addTo(id) }?.tracks } ?? []
            VStack(spacing: 0) {
                UsbHeader(drive: d, title: node?.name ?? d.name)
                Table(list) {
                    TableColumn("#") { t in Text("\((list.firstIndex(of: t) ?? 0) + 1)").foregroundColor(.mist.opacity(0.4)) }.width(30)
                    TableColumn("Kunstner") { t in Text(t.artist).foregroundColor(.mist.opacity(0.85)) }
                    TableColumn("Titel") { t in Text(t.title).foregroundColor(.mist) }
                    TableColumn("Key") { t in
                        if let k = MusicalKey.parse(t.key) { KeyPill(key: k) } else { Text(t.key) }
                    }.width(56)
                    TableColumn("BPM") { t in Text(t.bpm > 0 ? String(format: "%.0f", t.bpm) : "–").monospacedDigit() }.width(48)
                    TableColumn("Længde") { t in Text(String(format: "%d:%02d", t.duration / 60, t.duration % 60)).monospacedDigit() }.width(56)
                }
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                if !pendingIDs.isEmpty {
                    PendingTracks(ids: pendingIDs)
                }
            }
        } else {
            Text("USB'en er ikke sat i").foregroundColor(.mist.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct UsbPendingView: View {
    @EnvironmentObject var usb: UsbStore
    let driveID: String
    let key: String

    var body: some View {
        if let d = usb.drives.first(where: { $0.id == driveID }), let p = usb.pending[d.id]?.first(where: { $0.key == key }) {
            VStack(spacing: 0) {
                UsbHeader(drive: d, title: p.name + " (ny)")
                PendingTracks(ids: p.tracks)
                Spacer()
            }
        } else {
            Text("Playlisten er skrevet til USB'en eller fortrudt").foregroundColor(.mist.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PendingTracks: View {
    @EnvironmentObject var library: LibraryStore
    let ids: [UUID]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VENTER PÅ AT BLIVE SKREVET (\(ids.count))").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(Color.emberGradient)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(ids, id: \.self) { id in
                        if let t = library.index.track(id) {
                            HStack(spacing: 10) {
                                Cover(track: t, size: 26)
                                Text(t.artist).foregroundColor(.mist.opacity(0.7)).frame(width: 160, alignment: .leading).lineLimit(1)
                                Text(t.title).foregroundColor(.mist).lineLimit(1)
                                Spacer()
                                if let k = t.key { KeyPill(key: k) }
                                Text(t.bpmText).monospacedDigit().frame(width: 40)
                                QualityText(track: t).frame(width: 100, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.ember.opacity(0.06)))
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }
}
