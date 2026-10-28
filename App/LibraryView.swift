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

/// macOS skjuler rækkerne man trækker ud af en tabel – og viser dem ikke altid igen, når de ikke er flyttet
/// (de er jo kun KOPIERET til en playliste). Så tæller listen "200 sange", men tabellen ser tom ud.
/// Når et træk fra en tabel slutter, tegnes tabellen derfor forfra.
final class TableDragWatch: ObservableObject {
    static let shared = TableDragWatch()
    @Published var epoch = 0
    private var timer: Timer?

    /// Kaldes når et træk starter (fra trækkets indhold, som først laves når man begynder at trække).
    func started() {
        guard timer == nil else { return }
        DispatchQueue.main.async { [self] in
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate()
                self.timer = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.epoch += 1 }
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }
}

final class LibraryUIState: ObservableObject {
    @Published var selection: LibSelection = .smart(.all)
    @Published var keyFilter: Set<MusicalKey> = []
    @Published var search = ""
    @Published var tableSelection: Set<UUID> = []
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
    private let player = PlayerModel.shared

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebar()
                .frame(width: 248)
            Rectangle().fill(Color.hairline).frame(width: 1)
            VStack(spacing: 8) {
                let fixing: Bool = ui.selection == .smart(.upgrade)
                PlayerPanel(compact: fixing)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                if fixing {
                    ProcessPanel()
                        .padding(.horizontal, 16)
                }
                switch ui.selection {
                case .usb(let drive, let node):
                    UsbPlaylistView(driveID: drive, nodeID: node)
                case .usbPending(let drive, let key):
                    UsbPendingView(driveID: drive, key: key)
                default:
                    TrackListView()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
        }
        .environmentObject(ui)
        .environmentObject(player)
    }
}

// MARK: - Navnedialog

struct NamePrompt: Identifiable {
    let id = UUID()
    var title: String
    var text: String
    var icon: String = "music.note.list"
    var button: String = "Opret"
    var action: (String) -> Void
}

/// Dialog til nye playlister/mapper i MODULRs eget look.
struct NameSheet: View {
    let prompt: NamePrompt
    let close: () -> Void
    @State private var text: String = ""
    @FocusState private var focused: Bool

    init(prompt: NamePrompt, close: @escaping () -> Void) {
        self.prompt = prompt
        self.close = close
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ember.opacity(0.15))
                    Image(systemName: prompt.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.emberGradient)
                }
                .frame(width: 38, height: 38)
                Text(prompt.title).font(.system(size: 17, weight: .semibold)).foregroundColor(Color.mist)
            }
            TextField("Navn", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundColor(Color.mist)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(focused ? Color.ember : Color.hairline, lineWidth: focused ? 1.5 : 1))
                .focused($focused)
                .onSubmit(submit)
            HStack(spacing: 10) {
                Spacer()
                Button("Annullér", action: close)
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                Button(prompt.button, action: submit)
                    .buttonStyle(.ember)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 380)
        .background(Color.graphite)
        .preferredColorScheme(.dark)
        .onAppear {
            text = prompt.text
            focused = true
        }
    }

    func submit() {
        guard !trimmed.isEmpty else { return }
        prompt.action(trimmed)
        close()
    }
}

// MARK: - Sidebar

struct LibrarySidebar: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var ui: LibraryUIState

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

                sectionHeader("Bibliotek")
                VStack(spacing: 2) {
                    ForEach(SmartList.allCases) { s in
                        let count = library.index.tracks.filter(s.matches).count
                        FileDropRow { urls in library.importDropped(urls) } content: {
                            SideRow(icon: s.icon, title: s.rawValue, count: count, active: ui.selection == .smart(s)) {
                                ui.selection = .smart(s)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)

                HStack {
                    sectionHeader("Playlister")
                    Spacer()
                    ModMenuButton(items: {
                        [
                            .action("Ny playliste", icon: "music.note.list") { prompt("Ny playliste", "Ny playliste") { _ = library.createNode(name: $0, parent: nil, folder: false) } },
                            .action("Ny mappe", icon: "folder.fill.badge.plus") { prompt("Ny mappe", "Ny mappe") { _ = library.createNode(name: $0, parent: nil, folder: true) } },
                        ]
                    }) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundStyle(Color.emberGradient)
                    }
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
    }

    func prompt(_ title: String, _ text: String, _ action: @escaping (String) -> Void) {
        let icon: String = title.lowercased().contains("mappe") ? "folder.fill" : (title == "Omdøb" ? "pencil" : "music.note.list")
        let button: String = title == "Omdøb" ? "Gem" : "Opret"
        Dialogs.shared.name(NamePrompt(title: title, text: text, icon: icon, button: button, action: action))
    }

    func sectionHeader(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.mist.opacity(0.55))
            .padding(.horizontal, 18)
            .padding(.top, 6)
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
            library.importDropped(p.urls, into: target)
        }
    }
}

/// En sidebar-række der tager imod filer fra Finder og lyser op, mens man trækker hen over den.
struct FileDropRow<Content: View>: View {
    let onFiles: ([URL]) -> Void
    @ViewBuilder let content: Content
    @State private var targeted = false

    init(onFiles: @escaping ([URL]) -> Void, @ViewBuilder content: () -> Content) {
        self.onFiles = onFiles
        self.content = content()
    }

    var body: some View {
        content
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(targeted ? Color.ember : Color.clear, lineWidth: 1.5))
            .animation(Motion.hover, value: targeted)
            .fileDrop(targeted: $targeted, files: onFiles)
    }
}

struct SideRow: View {
    let icon: String
    let title: String
    var count: Int?
    let active: Bool
    var italic = false
    /// Noget trækkes hen over rækken lige nu – den lyser op, så man kan se hvor sangene lander.
    var dropTarget = false
    var dropLabel = "Læg i"
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: dropTarget ? "plus.circle.fill" : icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(active || dropTarget ? AnyShapeStyle(Color.emberGradient) : AnyShapeStyle(Color.mist.opacity(0.55)))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.system(size: 13, weight: active || dropTarget ? .semibold : .regular))
                    .italic(italic)
                    .foregroundColor(active || dropTarget ? .mist : .mist.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if dropTarget {
                    Text(dropLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.void)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.ember))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if let count {
                    Text("\(count)").font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.4))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dropTarget ? Color.ember.opacity(0.26) : (active ? Color.ember.opacity(0.14) : Color.white.opacity(hover ? 0.05 : 0))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.ember.opacity(dropTarget ? 1 : 0), lineWidth: 1.5))
            .scaleEffect(dropTarget ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .animation(Motion.snappy, value: active)
        .animation(Motion.snappy, value: dropTarget)
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
    @State private var hover = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                if node.isFolder {
                    Button { open.toggle() } label: {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.mist.opacity(0.5)).frame(width: 18, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 18)
                }
                SideRow(icon: node.isFolder ? "folder.fill" : "music.note.list", title: node.name,
                        count: node.isFolder ? nil : node.trackIDs.count, active: ui.selection == .node(node.id),
                        dropTarget: targeted, dropLabel: node.isFolder ? "Ind i mappen" : "Læg i") {
                    ui.selection = .node(node.id)
                }
                if node.isFolder {
                    RowPlus(visible: hover || ui.selection == .node(node.id)) {
                        [
                            .action("Ny playliste i \(node.name)", icon: "music.note.list") { open = true; prompt("Ny playliste", "Ny playliste") { _ = library.createNode(name: $0, parent: node.id, folder: false) } },
                            .action("Ny mappe i \(node.name)", icon: "folder.fill.badge.plus") { open = true; prompt("Ny mappe", "Ny mappe") { _ = library.createNode(name: $0, parent: node.id, folder: true) } },
                        ]
                    }
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .onHover { hover = $0 }
            .draggable("node:\(node.id.uuidString)")
            .fileDrop(targeted: $targeted, strings: { items in
                for s in items {
                    if s.hasPrefix("node:"), let id = UUID(uuidString: String(s.dropFirst(5))), node.isFolder {
                        library.move(id, under: node.id)
                    }
                }
                let ids = DropSupport.trackIDs(items)
                if !ids.isEmpty, !node.isFolder {
                    library.add(ids, to: node.id)
                    let new = ids.filter { !node.trackIDs.contains($0) }.count
                    library.lastMessage = new > 0 ? "\(new) sang\(new == 1 ? "" : "e") lagt i \(node.name)" + (new < ids.count ? " (\(ids.count - new) lå der i forvejen)" : "")
                                                  : "Sangene ligger allerede i \(node.name)"
                }
                let usbFiles = items.filter { $0.hasPrefix("usbtracks:") }.flatMap { UsbDragItem.files($0) }
                if !usbFiles.isEmpty, !node.isFolder { library.importFromUsb(usbFiles, into: node.id) }
            }, files: { urls in
                // Filer fra skrivebordet, Downloads osv.: ind i playlisten (på en mappe: bare ind i biblioteket)
                library.importDropped(urls, into: node.isFolder ? nil : node.id)
            })
            .modMenu(title: node.name, subtitle: node.isFolder ? "Mappe" : "\(node.trackIDs.count) sange") { nodeMenu() }
            .onChange(of: targeted) { _, on in
                // Hold et træk over en lukket mappe et øjeblik → den folder sig ud (som i Finder)
                guard on, node.isFolder, !open else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if targeted { withAnimation(Motion.snappy) { open = true } }
                }
            }
            if node.isFolder && open {
                NodeTree(parent: node.id, depth: depth + 1, prompt: prompt)
            }
        }
    }

    func nodeMenu() -> [MMItem] {
        var items = [MMItem]()
        if node.isFolder {
            items.append(.action("Ny playliste i mappen", icon: "music.note.list") { prompt("Ny playliste", "Ny playliste") { _ = library.createNode(name: $0, parent: node.id, folder: false) } })
            items.append(.action("Ny mappe i mappen", icon: "folder.fill.badge.plus") { prompt("Ny mappe", "Ny mappe") { _ = library.createNode(name: $0, parent: node.id, folder: true) } })
            items.append(.divider)
        }
        items.append(.action("Omdøb…", icon: "pencil") { prompt("Omdøb", node.name) { library.rename(node.id, to: $0) } })
        if node.parent != nil {
            items.append(.action("Flyt ud på øverste niveau", icon: "arrow.up.left") { library.move(node.id, under: nil) })
        }
        items.append(.divider)
        let id = node.id
        let name = node.name
        let folder = node.isFolder
        items.append(.action("Slet", icon: "trash", destructive: true) {
            Dialogs.shared.confirm("Slet \(folder ? "mappen" : "playlisten") \"\(name)\"?",
                                   message: folder ? "Mappen og playlisterne i den slettes. Sangene bliver i biblioteket." : "Sangene bliver i biblioteket.",
                                   icon: "trash.fill", button: "Slet", destructive: true) {
                if ui.selection == .node(id) { ui.selection = .smart(.all) }
                library.deleteNode(id)
            }
        })
        return items
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

struct Cover: View {
    private let library = LibraryStore.shared
    let track: LibTrack?
    let size: CGFloat
    var fallbackURL: URL? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size > 50 ? 10 : 5, style: .continuous).fill(Color.white.opacity(0.06))
            if let t = track, let img = CoverCache.image(t, library: library) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
            } else if let u = fallbackURL, let img = CoverCache.file(u) {
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

    /// Billede direkte fra en fil (fx cover på en rekordbox-USB).
    static func file(_ u: URL) -> NSImage? {
        if let img = cache.object(forKey: u.path as NSString) { return img }
        guard let img = NSImage(contentsOf: u) else { return nil }
        cache.setObject(img, forKey: u.path as NSString)
        return img
    }

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
    @ObservedObject private var dragWatch = TableDragWatch.shared
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var settings: FBSettings
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var ui: LibraryUIState
    private let player = PlayerModel.shared
    static let defaultSort: [KeyPathComparator<LibTrack>] = [KeyPathComparator(\LibTrack.sortAdded, order: .reverse)]
    @State private var sortOrder: [KeyPathComparator<LibTrack>] = TrackListView.defaultSort
    @State private var targeted = false

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
                Text(title).font(.system(size: 18, weight: .semibold)).foregroundColor(.mist).lineLimit(1)
                Text("\(rows.count) sange").font(.system(size: 12)).monospacedDigit().foregroundColor(.mist.opacity(0.6))
                if !library.analyzing.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Analyserer \(library.analyzing.count) …").font(.system(size: 11)).foregroundColor(.mist.opacity(0.5))
                }
                if !library.fixing.isEmpty {
                    ProgressView().controlSize(.small)
                    Text("Retter lydstyrke på \(library.fixing.count) …").font(.system(size: 11)).foregroundColor(Color.ember.opacity(0.85))
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundColor(.mist.opacity(0.4))
                    TextField("Søg", text: $ui.search).textFieldStyle(.plain).frame(minWidth: 90, maxWidth: 180)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if ui.selection == .smart(.badQuality) {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundColor(.mist.opacity(0.6))
                    Text("Højreklik → \"Udskift fil med bedre version…\" eller \"Find bedre version gratis…\". Cover og data flyttes med, den nye fil analyseres, og er den god nok, forsvinder sangen herfra – den bliver i sine playlister hele tiden.")
                        .font(.system(size: 12)).foregroundColor(.mist.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.bottom, 6)
            }
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
                    TableColumn("Preview") { (t: LibTrack) in WaveCell(track: t) }
                        .width(min: 110, ideal: 200, max: 420)
                    TableColumn("") { (t: LibTrack) in Cover(track: t, size: 26) }
                        .width(30)
                    TableColumn("Kunstner", value: \LibTrack.artist) { (t: LibTrack) in ArtistCell(track: t) }
                        .width(min: 70, ideal: 110)
                    TableColumn("Titel", value: \LibTrack.title) { (t: LibTrack) in TitleCell(track: t) }
                        .width(min: 110, ideal: 180)
                    TableColumn("Key", value: \LibTrack.sortKey) { (t: LibTrack) in KeyCell(track: t) }
                        .width(78)
                    TableColumn("BPM", value: \LibTrack.sortBPM) { (t: LibTrack) in BPMCell(track: t) }
                        .width(40)
                    TableColumn("Energi", value: \LibTrack.sortEnergy) { (t: LibTrack) in EnergyBar(value: t.energy) }
                        .width(52)
                    TableColumn("Længde", value: \LibTrack.sortDuration) { (t: LibTrack) in DurationCell(track: t) }
                        .width(46)
                    TableColumn("Kvalitet · LUFS", value: \LibTrack.sortQuality) { (t: LibTrack) in QualityCell(track: t) }
                        .width(min: 120, ideal: 150)
                } rows: {
                    ForEach(rows) { t in
                        TableRow(t)
                            .draggable(dragPayload(for: t))
                            .dropDestination(for: URL.self) { urls in
                                // Et billede på en sang = sangens artwork (på alle valgte, hvis sangen er valgt)
                                let ids: [UUID] = ui.tableSelection.contains(t.id) ? Array(ui.tableSelection) : [t.id]
                                let rest = library.takeArtworkImages(urls.filter(\.isFileURL), for: ids)
                                if !rest.isEmpty { library.importDropped(rest, into: currentPlaylist) }
                            }
                    }
                }
                .id(dragWatch.epoch)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .onChange(of: rows.map(\.id), initial: true) { _, _ in
                    // Afspilleren fortsætter med næste sang i den viste liste
                    PlayerModel.shared.offerQueue(rows, art: [:])
                }
                .onReceive(PlayerModel.shared.$advancedTo) { id in
                    if let id { ui.tableSelection = [id] }
                }
                .onChange(of: ui.tableSelection) { _, sel in
                    // Én valgt sang vises i afspilleren (uden at afspille), så du kan zoome og rette griddet
                    guard sel.count == 1, let id = sel.first, PlayerModel.shared.track?.id != id,
                          !PlayerModel.shared.playing, let t = library.index.track(id) else { return }
                    PlayerModel.shared.load(t, autoplay: false)
                }
                .background(RightClickArea { row, e in
                    guard let r = row, r < rows.count else { return false }
                    let id = rows[r].id
                    if !ui.tableSelection.contains(id) { ui.tableSelection = [id] }
                    let ids = ui.tableSelection.contains(id) ? ui.tableSelection : [id]
                    let t = rows[r]
                    let sub: String = ids.count > 1 ? "\(ids.count) sange valgt" : (t.artist.isEmpty ? t.fileName : t.artist)
                    ModMenu.shared.show(trackMenu(ids), at: NSEvent.mouseLocation, event: e,
                                        title: ids.count > 1 ? "\(ids.count) sange" : t.title, subtitle: sub)
                    return true
                })
                .contextMenu(forSelectionType: UUID.self) { _ in
                    EmptyView()
                } primaryAction: { ids in
                    if let id = ids.first, let t = library.index.track(id) {
                        player.listQueue = rows
                        player.listArt = [:]
                        player.load(t)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .fileDrop(targeted: $targeted) { urls in library.importDropped(urls, into: currentPlaylist) }
                .overlay {
                    if targeted {
                        DropHint(text: dropHintText).padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
                .animation(Motion.hover, value: targeted)
            }
        }
        .fileDrop(targeted: $targeted) { urls in library.importDropped(urls, into: currentPlaylist) }
    }

    var dropHintText: String {
        if let pl = currentPlaylist, let n = library.index.nodes.first(where: { $0.id == pl }) {
            return "Slip for at tilføje til \(n.name)"
        }
        return "Slip for at tilføje til biblioteket"
    }

    func dragPayload(for t: LibTrack) -> String {
        TableDragWatch.shared.started()
        let ids = ui.tableSelection.contains(t.id) ? Array(ui.tableSelection) : [t.id]
        return "tracks:" + ids.map(\.uuidString).joined(separator: ",")
    }

    func trackMenu(_ ids: Set<UUID>) -> [MMItem] {
        let list = Array(ids)
        guard let id = list.first, let t = library.index.track(id) else { return [] }
        var items = [MMItem]()
        items.append(.action("Afspil", icon: "play.fill") { player.load(t) })
        items.append(.divider)
        let playlists: [MMItem] = library.index.nodes.filter { !$0.isFolder }.map { (n: LibNode) -> MMItem in
            MMItem.action(n.name, icon: "music.note.list") { library.add(list, to: n.id) }
        }
        items.append(.submenu("Tilføj til playliste", icon: "text.badge.plus", playlists))
        if let pl = currentPlaylist {
            items.append(.action("Fjern fra playlisten", icon: "minus.circle") { library.removeFromPlaylist(list, playlist: pl) })
        }
        if !usb.drives.isEmpty {
            let drives: [MMItem] = usb.drives.map { (d: UsbDrive) -> MMItem in
                var sub = [MMItem]()
                sub.append(.action("Ny playliste…", icon: "plus") {
                    Dialogs.shared.name(NamePrompt(title: "Ny playliste på \(d.name)", text: title, icon: "externaldrive.fill") { name in
                        let key = usb.newPlaylist(d, name: name, parent: .root, tracks: list)
                        ui.selection = .usbPending(d.id, key)
                    })
                })
                let existing = (usb.contents[d.id]?.nodes ?? []).filter { !$0.folder }
                if !existing.isEmpty { sub.append(.divider) }
                for n in existing {
                    sub.append(.action(n.name, icon: "music.note.list") { usb.add(list, to: d, existing: n.id); ui.selection = .usb(d.id, n.id) })
                }
                return .submenu(d.name, icon: "externaldrive.fill", sub)
            }
            items.append(.submenu("Send til USB", icon: "square.and.arrow.up", drives))
        }
        items.append(.divider)
        if list.count == 1 {
            items.append(.action("Udskift fil med bedre version…", icon: "arrow.triangle.2.circlepath") { pickReplacement(id) })
            items.append(.action("Find bedre version gratis…", icon: "sparkle.magnifyingglass") {
                app.findBetterRequest = t.url
                app.tool = .findBetter
            })
        }
        // Artwork: tag coveret fra en (gammel) sang og læg det på en anden (fx en WAV uden cover)
        var art = [MMItem]()
        if list.count == 1 {
            art.append(.action("Kopiér artwork", icon: "doc.on.doc") {
                library.copyArtwork(id)
            })
        }
        let paste = library.pastableArtwork
        art.append(.action(paste.map { "Indsæt artwork fra \($0.name)" } ?? "Indsæt artwork", icon: "doc.on.clipboard", enabled: paste != nil) {
            library.pasteArtwork(to: list)
        })
        art.append(.action("Hent artwork fra en anden fil…", icon: "photo.badge.arrow.down") { library.pickArtworkFile(for: list) })
        items.append(.submenu("Artwork", icon: "photo", art))
        items.append(.action("Analysér igen", icon: "waveform.path.ecg") { library.reanalyze(list) })
        items.append(.action("Ret lydstyrke til \(Int(LoudnessPrefs.target)) LUFS", icon: "dial.medium") { library.fixLoudness(list, force: true) })
        if list.contains(where: { library.index.track($0)?.originalBackup != nil }) {
            items.append(.action("Gendan original (før lydstyrke)", icon: "clock.arrow.circlepath") { library.restoreOriginal(list) })
        }
        items.append(.action("Vis i Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting(list.compactMap { library.index.track($0)?.url })
        })
        items.append(.divider)
        let what: String = list.count == 1 ? "\"\(t.title)\"" : "\(list.count) sange"
        items.append(.action("Fjern fra biblioteket", icon: "trash", destructive: true) {
            Dialogs.shared.confirm("Fjern \(what) fra biblioteket?",
                                   message: "Filerne bliver liggende på din Mac – de forsvinder kun fra MODULR og dine playlister.",
                                   icon: "trash.fill", button: "Fjern", destructive: true) {
                library.remove(list)
            }
        })
        return items
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
                        Dialogs.shared.confirm("Er det den rigtige sang?", message: text + ". Skal filen alligevel erstatte den gamle?",
                                               icon: "exclamationmark.triangle.fill", button: "Udskift alligevel") {
                            replace(id, with: url, force: true)
                        }
                    } else {
                        library.lastMessage = "⛔️ \(text) – intet er ændret."
                    }
                }
            }
        }
    }
}

// MARK: - Celler (små, enkle visninger så tabellen er let for oversætteren)

/// Lille waveform i tabellen: klik eller træk for at afspille fra dét sted (som i rekordbox).
struct WaveCell: View {
    let track: LibTrack
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                MiniWave(track: track)
                MiniPlayhead(id: track.id, width: g.size.width)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let player = PlayerModel.shared
                let f = Double(max(0, min(1, v.location.x / max(1, g.size.width))))
                if player.track?.id != track.id {
                    player.load(LibraryStore.shared.index.track(track.id) ?? track, autoplay: true)
                } else if !player.playing {
                    player.play()
                }
                player.seek(f)
            })
        }
        .frame(height: 24)
        .overlay(alignment: .topLeading) { HotCueTags(track: track) }
    }
}

/// Hot cues A–H som små farvede bogstaver oven på tabellens preview (som rekordbox).
struct HotCueTags: View {
    let track: LibTrack
    var body: some View {
        GeometryReader { g in
            let dur: Double = max(0.001, track.duration ?? 0)
            ForEach(HotCue.letters.filter { track.hotCues?[$0] != nil }, id: \.self) { letter in
                let at: Double = track.hotCues?[letter] ?? 0
                let c = HotCue.rgb[letter] ?? (1, 1, 1)
                Text(letter)
                    .font(.system(size: 8, weight: .heavy)).foregroundColor(.black)
                    .frame(width: 10, height: 10)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: c.0, green: c.1, blue: c.2)))
                    .offset(x: min(g.size.width - 10, max(0, g.size.width * CGFloat(at / dur) - 5)), y: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

struct MiniPlayhead: View {
    @ObservedObject private var player = PlayerModel.shared
    let id: UUID
    let width: CGFloat

    var body: some View {
        if player.track?.id == id, player.duration > 0 {
            let x: CGFloat = width * CGFloat(player.position / player.duration)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.35)).frame(width: max(0, x))
                Rectangle().fill(Color.white).frame(width: 1.5).offset(x: x - 0.75)
            }
            .allowsHitTesting(false)
        }
    }
}

struct ArtistCell: View {
    let track: LibTrack
    var body: some View {
        let unknown: Bool = track.artist.isEmpty
        let text: String = unknown ? "Ukendt" : track.artist
        let alpha: Double = unknown ? 0.4 : 0.85
        return Text(text).foregroundColor(Color.mist.opacity(alpha)).lineLimit(1)
    }
}

struct TitleCell: View {
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var now = NowPlayingKey.shared
    let track: LibTrack
    var body: some View {
        HStack(spacing: 5) {
            if now.id == track.id {
                // Den sang der er i afspilleren – bølger mens den spiller (som i Apple Music)
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.ember)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: now.playing)
                    .transition(.scale.combined(with: .opacity))
            }
            if library.analyzing.contains(track.id) { ProgressView().controlSize(.mini) }
            if library.working.contains(track.id) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(Color.ember)
            }
            Text(track.title).foregroundColor(now.id == track.id ? Color.ember : Color.mist).lineLimit(1)
        }
        .animation(Motion.snappy, value: now.id == track.id)
        .help(track.path)
    }
}

struct KeyCell: View {
    @ObservedObject private var now = NowPlayingKey.shared
    let track: LibTrack
    var body: some View {
        if let k = track.key {
            let match: Bool = KeyMatch.fits(k, now.key)
            HStack(spacing: 6) {
                KeyPill(key: k)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(KeyMatch.green, lineWidth: match ? 2 : 0).padding(-2))
                Text(k.classic).font(.system(size: 12)).foregroundColor(match ? KeyMatch.green : Color.mist.opacity(0.6)).lineLimit(1)
            }
            .help(match ? "Passer harmonisk med sangen der spiller" : "")
        } else {
            Text("–").foregroundColor(Color.mist.opacity(0.4))
        }
    }
}

struct BPMCell: View {
    let track: LibTrack
    var body: some View {
        Text(track.bpmText).monospacedDigit().foregroundColor(Color.mist)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct ClassicKeyCell: View {
    let track: LibTrack
    var body: some View {
        let text: String = track.key?.classic ?? "–"
        return Text(text).foregroundColor(Color.mist.opacity(0.7))
    }
}

struct DurationCell: View {
    let track: LibTrack
    var body: some View {
        Text(track.durationText).monospacedDigit().foregroundColor(Color.mist.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct QualityCell: View {
    let track: LibTrack
    var body: some View {
        HStack(spacing: 6) {
            QualityText(track: track)
            Text(track.codec).font(.system(size: 11)).foregroundColor(Color.mist.opacity(0.5))
            LufsBadge(track: track)
        }
    }
}

/// Lydstyrken: grøn = klar til klubben, orange = rettes, hvirvel = rettes nu.
struct LufsBadge: View {
    @ObservedObject private var library = LibraryStore.shared
    let track: LibTrack

    var body: some View {
        if library.fixing.contains(track.id) {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Text("Retter").font(.system(size: 11, weight: .semibold)).foregroundColor(Color.ember)
            }
        } else if let l = track.lufs {
            let target: Double = LoudnessPrefs.target
            let ok: Bool = abs(l - target) <= 1.0 || track.loudnessFixedAt != nil
            let color: Color = ok ? Color(red: 0.35, green: 0.9, blue: 0.5) : Color(red: 1, green: 0.62, blue: 0.25)
            let fixed: Bool = track.loudnessFixedAt != nil
            HStack(spacing: 2) {
                if fixed { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                Text(String(format: "%.0f", l))
            }
            .font(.system(size: 11, weight: .bold)).monospacedDigit()
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .help(LufsBadge.helpText(track, target: target))
        }
    }

    static func helpText(_ t: LibTrack, target: Double) -> String {
        var parts = [t.lufsText]
        if let p = t.peakDB { parts.append(String(format: "top %.1f dBFS", p)) }
        parts.append(String(format: "mål %.0f LUFS", target))
        if let n = t.loudnessNote { parts.append(n) }
        if !t.canFixLoudness { parts.append("\(t.codec) rettes ikke automatisk – kun WAV, AIFF og MP3") }
        return parts.joined(separator: " · ")
    }
}

struct MiniWave: View {
    private let library = LibraryStore.shared
    let track: LibTrack

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35))
            if track.hasWave, let img = WaveformCache.shared.image(for: track, width: 600, height: 44, store: library) {
                Image(decorative: img, scale: 2).resizable().interpolation(.medium)
            }
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
    @State private var hover = false
    @State private var dropKey: String?                   // ny playliste der trækkes hen over lige nu

    var body: some View {
        let c = usb.contents[drive.id]
        let pending = usb.pending[drive.id] ?? []
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundColor(.mist.opacity(0.5)).frame(width: 18, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                SideRow(icon: "externaldrive.fill", title: drive.name, count: c?.tracks?.count,
                        active: ui.selection == .usb(drive.id, nil)) { ui.selection = .usb(drive.id, nil) }
                RowPlus(visible: hover || ui.selection == .usb(drive.id, nil)) {
                    [
                        .action("Ny playliste på \(drive.name)", icon: "music.note.list") { open = true; prompt("Ny playliste på \(drive.name)", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .root) } },
                        .action("Ny mappe på \(drive.name)", icon: "folder.fill.badge.plus") { open = true; prompt("Ny mappe på \(drive.name)", "Ny mappe") { usb.newFolder(drive, name: $0, parent: .root) } },
                    ]
                }
                EjectButton(busy: usb.writing.contains(drive.id)) { usb.ejectSafely(drive) }
            }
            .onHover { hover = $0 }
            .modMenu(title: drive.name, subtitle: "rekordbox-USB") {
                [
                    .action("Ny playliste…", icon: "music.note.list") { prompt("Ny playliste på \(drive.name)", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .root) } },
                    .action("Ny mappe…", icon: "folder.fill.badge.plus") { prompt("Ny mappe på \(drive.name)", "Ny mappe") { usb.newFolder(drive, name: $0, parent: .root) } },
                    .divider,
                    .action("Læs igen", icon: "arrow.clockwise") { usb.load(drive) },
                    .action("Skub ud", icon: "eject.fill") { usb.ejectSafely(drive) },
                ]
            }
            if open {
                if usb.loading.contains(drive.id) { ProgressView().controlSize(.small).padding(4) }
                if let err = c?.error, c?.ok == false {
                    Text(err).font(.system(size: 10)).foregroundColor(.red.opacity(0.8)).padding(.horizontal, 16)
                }
                ForEach(pending.filter { $0.kind == .playlist && $0.parent == .root }) { p in
                    SideRow(icon: "music.note.list", title: p.name + "  •ny", count: p.tracks.count,
                            active: ui.selection == .usbPending(drive.id, p.key), italic: true, dropTarget: dropKey == p.key) {
                        ui.selection = .usbPending(drive.id, p.key)
                    }
                    .padding(.leading, 14)
                    .dropDestination(for: String.self) { items, _ in
                        usb.add(ids(items), to: drive, newKey: p.key)
                        return true
                    } isTargeted: { on in
                        if on { dropKey = p.key } else if dropKey == p.key { dropKey = nil }
                    }
                }
                ForEach(pending.filter { $0.kind == .folder && $0.parent == .root }) { f in
                    SideRow(icon: "folder.fill", title: f.name + "  •ny", count: nil, active: false, italic: true) {}
                        .padding(.leading, 14)
                        .modMenu(title: f.name) {
                            [.action("Ny playliste i mappen…", icon: "music.note.list") { prompt("Ny playliste", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .new(f.key)) } }]
                        }
                    ForEach(pending.filter { $0.kind == .playlist && $0.parent == .new(f.key) }) { p in
                        SideRow(icon: "music.note.list", title: p.name + "  •ny", count: p.tracks.count,
                                active: ui.selection == .usbPending(drive.id, p.key), italic: true, dropTarget: dropKey == p.key) {
                            ui.selection = .usbPending(drive.id, p.key)
                        }
                        .padding(.leading, 28)
                        .dropDestination(for: String.self) { items, _ in
                            usb.add(ids(items), to: drive, newKey: p.key)
                            return true
                        } isTargeted: { on in
                            if on { dropKey = p.key } else if dropKey == p.key { dropKey = nil }
                        }
                    }
                }
                // Eksisterende playlister under de nye (nye lægges øverst, som på CDJ'en)
                UsbNodeTree(drive: drive, parent: 0, depth: 1, prompt: prompt)
            }
        }
    }

    func ids(_ items: [String]) -> [UUID] {
        DropSupport.trackIDs(items)
    }
}

struct UsbNodeTree: View {
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var ui: LibraryUIState
    let drive: UsbDrive
    let parent: Int
    let depth: Int
    let prompt: (String, String, @escaping (String) -> Void) -> Void
    @State private var openFolders: Set<Int> = []        // mapper er lukkede, til du åbner dem
    @State private var hovered: Int?
    @State private var dropNode: Int?                     // rækken der trækkes hen over lige nu

    init(drive: UsbDrive, parent: Int, depth: Int, prompt: @escaping (String, String, @escaping (String) -> Void) -> Void) {
        self.drive = drive
        self.parent = parent
        self.depth = depth
        self.prompt = prompt
    }

    func usbFolderMenu(_ n: UsbNodeInfo) -> [MMItem] {
        guard n.folder else { return [] }
        var items = [MMItem]()
        items.append(.action("Ny playliste i mappen…", icon: "music.note.list") {
            prompt("Ny playliste", "Ny playliste") { _ = usb.newPlaylist(drive, name: $0, parent: .existing(n.id)) }
        })
        items.append(.action("Ny mappe i mappen…", icon: "folder.fill.badge.plus") {
            prompt("Ny mappe", "Ny mappe") { usb.newFolder(drive, name: $0, parent: .existing(n.id)) }
        })
        return items
    }

    /// Værn mod en beskadiget database, hvor en mappe peger på sig selv.
    func usbChildren() -> [UsbNodeInfo] {
        if depth > 24 { return [] }
        let all: [UsbNodeInfo] = usb.contents[drive.id]?.nodes ?? []
        let mine = all.filter { n in n.parent == parent && n.id != parent }
        // Samme rækkefølge som på CDJ'en (sorteringen fra USB'en – ikke mapper først)
        return mine.sorted { a, b in a.sort < b.sort }
    }

    var body: some View {
        // Værn mod en beskadiget database, hvor en mappe peger på sig selv
        let nodes: [UsbNodeInfo] = usbChildren()
        let pending = usb.pending[drive.id] ?? []
        ForEach(nodes) { n in
            let added = pending.first { $0.kind == .addTo(n.id) }?.tracks.count ?? 0
            HStack(spacing: 0) {
                if n.folder {
                    Button {
                        if openFolders.contains(n.id) { openFolders.remove(n.id) } else { openFolders.insert(n.id) }
                    } label: {
                        Image(systemName: openFolders.contains(n.id) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundColor(.mist.opacity(0.5)).frame(width: 18, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 18)
                }
                SideRow(icon: n.folder ? "folder" : "music.note.list", title: n.name + (added > 0 ? "  +\(added)" : ""),
                        count: n.folder ? nil : n.tracks.count, active: ui.selection == .usb(drive.id, n.id),
                        dropTarget: dropNode == n.id && !n.folder) {
                    if n.folder {
                        if openFolders.contains(n.id) { openFolders.remove(n.id) } else { openFolders.insert(n.id) }
                    }
                    ui.selection = .usb(drive.id, n.id)
                }
                if n.folder {
                    RowPlus(visible: hovered == n.id || ui.selection == .usb(drive.id, n.id)) {
                        openFolders.insert(n.id)
                        return usbFolderMenu(n)
                    }
                }
            }
            .padding(.leading, CGFloat(depth - 1) * 14)
            .onHover { inside in
                if inside { hovered = n.id } else if hovered == n.id { hovered = nil }
            }
            .dropDestination(for: String.self) { items, _ in
                guard !n.folder else { return false }
                let ids = DropSupport.trackIDs(items)
                if !ids.isEmpty { usb.add(ids, to: drive, existing: n.id) }
                // Sange fra USB'en selv → læg dem i denne playliste (som at trække i rekordbox)
                var usbIDs = [Int]()
                for s in items {
                    if let r = UsbDragItem.decode(s) {
                        if r.drive == drive.id { usbIDs += r.ids } else { usb.message = "Træk sange mellem to USB'er via biblioteket (træk dem først over i en playliste i MODULR)." }
                    }
                }
                if !usbIDs.isEmpty { usb.addExisting(drive, playlist: n.id, tracks: Array(Set(usbIDs))) }
                return true
            } isTargeted: { on in
                if on { dropNode = n.id } else if dropNode == n.id { dropNode = nil }
                // En lukket mappe folder sig ud, når man holder et træk over den
                if on, n.folder, !openFolders.contains(n.id) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if dropNode == n.id { _ = withAnimation(Motion.snappy) { openFolders.insert(n.id) } }
                    }
                }
            }
            .modMenu(title: n.name) { usbFolderMenu(n) }
            if n.folder && openFolders.contains(n.id) {
                UsbNodeTree(drive: drive, parent: n.id, depth: depth + 1, prompt: prompt)
                ForEach(pending.filter { $0.parent == .existing(n.id) }) { p in
                    SideRow(icon: p.kind == .folder ? "folder.fill" : "music.note.list", title: p.name + "  •ny",
                            count: p.kind == .folder ? nil : p.tracks.count, active: ui.selection == .usbPending(drive.id, p.key), italic: true) {
                        if p.kind != .folder { ui.selection = .usbPending(drive.id, p.key) }
                    }
                    .padding(.leading, CGFloat(depth + 1) * 14)
                    .dropDestination(for: String.self) { items, _ in
                        let ids = DropSupport.trackIDs(items)
                        usb.add(ids, to: drive, newKey: p.key)
                        return true
                    }
                }
            }
        }
    }
}

/// Lille + ved siden af en mappe: ny playliste eller mappe uden højreklik. Vises når musen er over rækken.
struct RowPlus: View {
    let visible: Bool
    let items: () -> [MMItem]
    @State private var hover = false

    init(visible: Bool, items: @escaping () -> [MMItem]) {
        self.visible = visible
        self.items = items
    }

    var body: some View {
        ModMenuButton(items: items) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(hover ? .ember : .mist.opacity(0.6))
                .frame(width: 22, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .onHover { hover = $0 }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .help("Ny playliste eller mappe")
    }
}

/// ⏏︎ ved siden af USB-navnet: skub sikkert ud.
struct EjectButton: View {
    let busy: Bool
    let action: () -> Void
    @State private var hover = false

    init(busy: Bool, action: @escaping () -> Void) {
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "eject.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(hover ? .ember : .mist.opacity(0.55))
                .frame(width: 22, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(busy)
        .opacity(busy ? 0.3 : 1)
        .help("Skub USB'en sikkert ud")
    }
}

// MARK: - USB i hovedområdet

struct UsbHeader: View {
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var library: LibraryStore
    let drive: UsbDrive
    let title: String
    @State private var showSettings = false

    init(drive: UsbDrive, title: String) {
        self.drive = drive
        self.title = title
    }

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
                Button("My Settings") { showSettings = true }
                Button("Skub ud") { usb.ejectSafely(drive) }.disabled(usb.writing.contains(drive.id))
            }
            if let n = usb.contents[drive.id]?.misplaced, n > 0 {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.exclamationmark").foregroundColor(.amber)
                    Text("\(n) sang\(n == 1 ? "" : "e") fra en ældre MODULR har waveform-filerne et sted, CDJ'en ikke kigger – derfor blå waveform og lang indlæsning.")
                        .font(.system(size: 12)).foregroundColor(.mist.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Ret nu") { usb.repairAnalysis(drive) }
                        .buttonStyle(.ember)
                        .disabled(usb.editing.contains(drive.id) || usb.writing.contains(drive.id))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.amber.opacity(0.10)))
            }
            if let w = drive.formatWarning {
                Text("⚠︎ " + w).font(.system(size: 12)).foregroundColor(.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let st = usb.settings[drive.id], st.waveformColor == 1 {
                // Waveform-farven på CDJ'en styres af DEVSETTING.DAT på stikket – BLUE er standard
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.amber)
                    Text("Denne USB beder CDJ'en om at vise BLÅ waveform. Det er derfor den ikke er i RGB.")
                        .font(.system(size: 12)).foregroundColor(.mist.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Skift til RGB") { usb.writeSettings(drive, ["DEVSETTING.DAT": ["waveform_color": 3]], done: "Waveform-farven er sat til RGB – sæt USB'en i CDJ'en igen.") }
                        .buttonStyle(.ember)
                    Button("3-bånd") { usb.writeSettings(drive, ["DEVSETTING.DAT": ["waveform_color": 4]], done: "Waveform-farven er sat til 3Band – sæt USB'en i CDJ'en igen.") }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.amber.opacity(0.10)))
            }
            if usb.contents[drive.id]?.onelibrary == true {
                Text("Denne USB har også et OneLibrary (CDJ-3000X, XDJ-AZ, Opus Quad). MODULR skriver i Device Library, som CDJ-3000 læser. Til 3000X: sæt USB'en i rekordbox 7, højreklik på \"OneLibrary\" og vælg \"Convert from Device Library\".")
                    .font(.system(size: 11)).foregroundColor(.amber.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let m = usb.message {
                Text(m).font(.system(size: 12)).foregroundColor(.mist.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
                    .id(m)
                    .transition(.asymmetric(insertion: .push(from: .top), removal: .opacity))
            }
            Text("Træk sange fra biblioteket over på en playliste under USB i venstre side, eller højreklik på sange → Send til USB. Intet skrives, før du trykker \"Skriv til USB\" – og der tages altid backup af rekordbox-databasen først.")
                .font(.system(size: 11)).foregroundColor(.mist.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .animation(Motion.smooth, value: usb.message)
        .sheet(isPresented: $showSettings) {
            UsbSettingsView(drive: drive) { showSettings = false }
                .environmentObject(usb)
        }
    }
}

/// My Settings på USB'en – de samme valg som i rekordbox' "My Settings" og på CDJ'en.
struct UsbSettingsView: View {
    @EnvironmentObject var usb: UsbStore
    let drive: UsbDrive
    let close: () -> Void
    @State private var draft: [String: [String: Int]] = [:]
    @State private var tab = "DEVSETTING.DAT"

    init(drive: UsbDrive, close: @escaping () -> Void) {
        self.drive = drive
        self.close = close
    }

    static let tabs: [(String, String)] = [("DEVSETTING.DAT", "Visning"), ("MYSETTING.DAT", "CDJ"),
                                           ("MYSETTING2.DAT", "CDJ 2"), ("DJMMYSETTING.DAT", "Mixer")]
    static let tabInfo = ["DEVSETTING.DAT": "Hvordan CDJ'en tegner waveform og toneart, når stikket er sat i.",
                          "MYSETTING.DAT": "Spillerens My Settings – hentes når du loader stikket på CDJ'en.",
                          "MYSETTING2.DAT": "Flere spillerindstillinger (jog-skærm, waveform, beat jump).",
                          "DJMMYSETTING.DAT": "Mixerens indstillinger – hentes af DJM'en via PRO DJ LINK."]

    var body: some View {
        let st = usb.settings[drive.id]
        let changed = changes(st)
        VStack(spacing: 0) {
            header
            ModSegmented(selection: $tab, options: Self.tabs)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            Rectangle().fill(Color.hairline).frame(height: 1)
            if let st {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(Self.tabInfo[tab] ?? "")
                            .font(.system(size: 12)).foregroundColor(.mist.opacity(0.5))
                        notices(st)
                        if tab == "DEVSETTING.DAT", let wf = st.fields.first(where: { $0.file == tab && $0.name == "waveform_color" }) {
                            WaveformColorPicker(selection: binding(wf, st), changed: isChanged(wf, st))
                        }
                        card(st)
                    }
                    .padding(22)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Læser indstillingerne på stikket …").font(.system(size: 12)).foregroundColor(.mist.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(Color.hairline).frame(height: 1)
            footer(changed)
        }
        .frame(width: 600, height: 640)
        .background(Color.graphite)
        .onAppear { usb.loadSettings(drive) }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.ember)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.ember.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("My Settings").font(.system(size: 17, weight: .bold)).foregroundColor(.mist)
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive.fill").font(.system(size: 9))
                    Text(drive.name).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium)).foregroundColor(.mist.opacity(0.45))
            }
            Spacer()
            Button { close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundColor(.mist.opacity(0.6))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    func notices(_ st: UsbSettings) -> some View {
        if st.missing.contains(tab) {
            Label("Filen findes ikke på stikket. Gemmer du, laves den med rekordbox' standardværdier.", systemImage: "info.circle")
                .font(.system(size: 12)).foregroundColor(.mist.opacity(0.7))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.04)))
        }
        if let p = st.problems[tab] {
            Label(p, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundColor(.amber)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.amber.opacity(0.08)))
        }
    }

    func card(_ st: UsbSettings) -> some View {
        let fields = st.fields.filter { $0.file == tab && !($0.file == "DEVSETTING.DAT" && $0.name == "waveform_color") }
        return VStack(spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.element.id) { i, f in
                if i > 0 { Rectangle().fill(Color.hairline).frame(height: 1).padding(.leading, 16) }
                SettingRow(field: f, value: binding(f, st), changed: isChanged(f, st))
                    .disabled(st.problems[tab] != nil)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.hairline, lineWidth: 1))
    }

    func footer(_ changed: [String: [String: Int]]) -> some View {
        let n = changed.values.reduce(0) { $0 + $1.count }
        return HStack(spacing: 10) {
            if n > 0 {
                Circle().fill(Color.ember).frame(width: 6, height: 6)
                Text("\(n) ændring\(n == 1 ? "" : "er")").font(.system(size: 12, weight: .semibold)).foregroundColor(.mist.opacity(0.8))
                Button("Fortryd") { draft = [:] }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.mist.opacity(0.5))
            } else {
                Image(systemName: "lock.shield").font(.system(size: 11)).foregroundColor(.mist.opacity(0.35))
                Text("Backup af de gamle filer gemmes på stikket").font(.system(size: 11)).foregroundColor(.mist.opacity(0.35))
            }
            Spacer()
            Button("Gem på USB") {
                usb.writeSettings(drive, changed)
                close()
            }
            .buttonStyle(.ember)
            .disabled(n == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    func binding(_ f: UsbSettingField, _ st: UsbSettings) -> Binding<Int> {
        Binding(get: { draft[f.file]?[f.name] ?? st.value(f) ?? f.defaultValue },
                set: { draft[f.file, default: [:]][f.name] = $0 })
    }

    func isChanged(_ f: UsbSettingField, _ st: UsbSettings) -> Bool {
        guard let v = draft[f.file]?[f.name] else { return false }
        return v != st.value(f) || st.missing.contains(f.file)
    }

    /// Kun de felter du faktisk har ændret (og filer der mangler, hvis du har valgt noget i dem).
    func changes(_ st: UsbSettings?) -> [String: [String: Int]] {
        guard let st else { return [:] }
        var out = [String: [String: Int]]()
        for (file, vals) in draft {
            for (k, v) in vals {
                let cur = st.values[file]?[k]
                if cur != v || st.missing.contains(file) { out[file, default: [:]][k] = v }
            }
        }
        return out
    }
}

/// Én række: navn til venstre, værdien som en pille der åbner MODULRs egen menu.
struct SettingRow: View {
    let field: UsbSettingField
    @Binding var value: Int
    let changed: Bool
    @State private var hover = false

    init(field: UsbSettingField, value: Binding<Int>, changed: Bool) {
        self.field = field
        _value = value
        self.changed = changed
    }

    static func display(_ s: String) -> String { s.uppercased() }

    var body: some View {
        let current = field.options.first { $0.value == value }?.label ?? "—"
        HStack(spacing: 10) {
            Circle().fill(Color.ember).frame(width: 6, height: 6).opacity(changed ? 1 : 0)
            Text(field.label).font(.system(size: 13)).foregroundColor(.mist.opacity(0.9)).lineLimit(1)
            Spacer(minLength: 12)
            ModMenuButton(items: {
                field.options.map { o in
                    MMItem.action(Self.display(o.label), icon: o.value == value ? "checkmark" : nil) { value = o.value }
                }
            }) {
                HStack(spacing: 8) {
                    Text(Self.display(current))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundColor(changed ? .ember : .mist)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundColor(.mist.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .frame(width: 168, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hover ? 0.09 : 0.055)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(changed ? Color.ember.opacity(0.5) : Color.hairline, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .onHover { hover = $0 }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(height: 46)
    }
}

/// Waveform-farven som tre små forhåndsvisninger – som valget på CDJ'en.
struct WaveformColorPicker: View {
    @Binding var selection: Int
    let changed: Bool

    init(selection: Binding<Int>, changed: Bool) {
        _selection = selection
        self.changed = changed
    }

    static let choices: [(Int, String)] = [(1, "Blå"), (3, "RGB"), (4, "3-bånd")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("WAVEFORM-FARVE").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundColor(.mist.opacity(0.55))
                if changed { Circle().fill(Color.ember).frame(width: 6, height: 6) }
            }
            HStack(spacing: 10) {
                ForEach(Self.choices, id: \.0) { v, name in
                    let on = selection == v
                    Button { selection = v } label: {
                        VStack(spacing: 8) {
                            WaveSwatch(style: v)
                                .frame(height: 38)
                                .padding(.horizontal, 10)
                                .padding(.top, 10)
                            Text(name).font(.system(size: 12, weight: .semibold)).foregroundColor(on ? .mist : .mist.opacity(0.6))
                                .padding(.bottom, 9)
                        }
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.black.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(on ? Color.ember : Color.hairline, lineWidth: on ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Lille waveform-prøve i spillerens farver.
struct WaveSwatch: View {
    let style: Int

    var body: some View {
        Canvas { ctx, size in
            let n = 28
            let w = size.width / CGFloat(n)
            let mid = size.height / 2
            for i in 0..<n {
                let t = Double(i)
                let lo = 0.35 + 0.6 * abs(sin(t * 0.55))
                let mi = 0.25 + 0.5 * abs(sin(t * 0.9 + 1))
                let hi = 0.15 + 0.4 * abs(sin(t * 1.7 + 2))
                let x = CGFloat(i) * w + w * 0.15
                let bw = w * 0.7
                var bars: [(Double, Color)] = []
                switch style {
                case 3:
                    let top = max(lo, mi, hi)
                    bars = [(top, Color(red: 0.25 + 0.75 * lo / top, green: 0.2 + 0.8 * mi / top, blue: 0.3 + 0.7 * hi / top))]
                case 4:
                    bars = [(lo, Color(red: 0.10, green: 0.24, blue: 0.72)), (mi * 0.8, Color(red: 0.94, green: 0.63, blue: 0.13)), (hi * 0.6, .white)]
                default:
                    bars = [(max(lo, mi), Color(red: 0.05, green: 0.43, blue: 0.78)), (hi * 0.7, Color(red: 0.55, green: 0.78, blue: 1))]
                }
                for (h, c) in bars {
                    let hh = CGFloat(h) * mid
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - hh, width: bw, height: hh * 2), cornerRadius: bw / 2), with: .color(c))
                }
            }
        }
    }
}

struct UsbPlaylistView: View {
    @ObservedObject private var dragWatch = TableDragWatch.shared
    @EnvironmentObject var usb: UsbStore
    @EnvironmentObject var library: LibraryStore
    let driveID: String
    let nodeID: Int?
    @State private var selection: Set<Int> = []

    init(driveID: String, nodeID: Int?) {
        self.driveID = driveID
        self.nodeID = nodeID
    }

    var body: some View {
        if let d = usb.drives.first(where: { $0.id == driveID }) {
            let c = usb.contents[d.id]
            let node = c?.nodes?.first { $0.id == nodeID }
            let all = c?.tracks ?? []
            let list: [UsbTrackInfo] = node.map { n in n.tracks.compactMap { id in all.first { $0.id == id } } } ?? all
            let pendingIDs = nodeID.flatMap { id in usb.pending[d.id]?.first { $0.kind == .addTo(id) }?.tracks } ?? []
            VStack(spacing: 0) {
                UsbHeader(drive: d, title: node?.name ?? d.name)
                Table(of: UsbTrackInfo.self, selection: $selection) {
                    TableColumn("#") { (t: UsbTrackInfo) in UsbIndexCell(index: (list.firstIndex(of: t) ?? 0) + 1) }
                        .width(30)
                    TableColumn("Waveform på CDJ") { (t: UsbTrackInfo) in UsbWaveCell(track: t, root: d.url) }
                        .width(min: 110, ideal: 200, max: 420)
                    TableColumn("") { (t: UsbTrackInfo) in UsbCoverCell(track: t, root: d.url) }
                        .width(30)
                    TableColumn("Kunstner") { (t: UsbTrackInfo) in UsbTextCell(text: t.artist, alpha: 0.85) }
                    TableColumn("Titel") { (t: UsbTrackInfo) in UsbTextCell(text: t.title, alpha: 1) }
                    TableColumn("Key") { (t: UsbTrackInfo) in UsbKeyCell(key: t.key) }
                        .width(56)
                    TableColumn("BPM") { (t: UsbTrackInfo) in UsbTextCell(text: UsbTrackInfo.bpmText(t.bpm), alpha: 1) }
                        .width(48)
                    TableColumn("Længde") { (t: UsbTrackInfo) in UsbTextCell(text: UsbTrackInfo.timeText(t.duration), alpha: 0.8) }
                        .width(56)
                } rows: {
                    ForEach(list) { t in
                        TableRow(t)
                            .draggable({ () -> UsbDragItem in
                                TableDragWatch.shared.started()
                                return UsbDragItem(text: dragText(t, drive: d), file: t.fileURL(root: d.url))
                            }())
                    }
                }
                .id(dragWatch.epoch)
                .scrollContentBackground(.hidden)
                .alternatingRowBackgrounds(.disabled)
                .background(RightClickArea { row, e in
                    guard let r = row, r < list.count else { return false }
                    let id = list[r].id
                    if !selection.contains(id) { selection = [id] }
                    let ids = list.filter { selection.contains($0.id) }.map(\.id)
                    let t = list[r]
                    ModMenu.shared.show(menu(ids, drive: d, list: list), at: NSEvent.mouseLocation, event: e,
                                        title: ids.count > 1 ? "\(ids.count) sange" : t.title,
                                        subtitle: ids.count > 1 ? d.name : t.artist)
                    return true
                })
                .onDeleteCommand {
                    let ids = list.filter { selection.contains($0.id) }.map(\.id)
                    guard !ids.isEmpty else { return }
                    if let pid = nodeID { usb.removeFromPlaylist(d, playlist: pid, tracks: ids) } else { confirmDelete(ids, drive: d, list: list) }
                }
                .contextMenu(forSelectionType: Int.self) { _ in
                    EmptyView()
                } primaryAction: { ids in
                    // Dobbeltklik: afspil fra USB'en (eller biblioteket, hvis sangen også ligger der)
                    if let id = ids.first, let t = list.first(where: { $0.id == id }) {
                        let items: [LibTrack] = list.map { $0.playable(root: d.url) }
                        var art = [UUID: URL]()
                        for (i, u) in list.enumerated() { if let a = u.artworkURL(root: d.url) { art[items[i].id] = a } }
                        PlayerModel.shared.listQueue = items
                        PlayerModel.shared.listArt = art
                        PlayerModel.shared.load(t.playable(root: d.url), autoplay: true, art: t.artworkURL(root: d.url))
                    }
                }
                .onChange(of: list.map(\.id), initial: true) { _, _ in
                    let items: [LibTrack] = list.map { $0.playable(root: d.url) }
                    var art = [UUID: URL]()
                    for (i, t) in list.enumerated() { if let u = t.artworkURL(root: d.url) { art[items[i].id] = u } }
                    PlayerModel.shared.offerQueue(items, art: art)
                }
                .onReceive(PlayerModel.shared.$advancedTo) { id in
                    guard let id else { return }
                    if let t = list.first(where: { $0.playable(root: d.url).id == id }) { selection = [t.id] }
                }
                .onChange(of: selection) { _, sel in
                    guard sel.count == 1, let id = sel.first, !PlayerModel.shared.playing,
                          let t = list.first(where: { $0.id == id }) else { return }
                    PlayerModel.shared.load(t.playable(root: d.url), autoplay: false, art: t.artworkURL(root: d.url))
                }
                .padding(.horizontal, 12)
                if !pendingIDs.isEmpty {
                    PendingTracks(ids: pendingIDs)
                }
            }
        } else {
            Text("USB'en er ikke sat i").foregroundColor(.mist.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Det der trækkes: "usbtracks:<id,id>@<drev>" (til playlister i MODULR) og selve filen (til Finder).
    func dragText(_ t: UsbTrackInfo, drive d: UsbDrive) -> String {
        let ids = selection.contains(t.id) ? Array(selection) : [t.id]
        return UsbDragItem.encode(ids: ids, drive: d.id)
    }

    func menu(_ ids: [Int], drive d: UsbDrive, list: [UsbTrackInfo]) -> [MMItem] {
        var items = [MMItem]()
        let files = list.filter { ids.contains($0.id) }.map { $0.fileURL(root: d.url) }
        let others = usb.playlistPaths(d).filter { $0.id != nodeID }
        items.append(.submenu("Læg i playliste", icon: "text.badge.plus", others.map { p in
            MMItem.action(p.path, icon: "music.note.list") { usb.addExisting(d, playlist: p.id, tracks: ids) }
        }))
        if let pid = nodeID {
            items.append(.submenu("Flyt til playliste", icon: "arrow.right.square", others.map { p in
                MMItem.action(p.path, icon: "music.note.list") { usb.move(d, from: pid, to: p.id, tracks: ids) }
            }))
            let order = list.map(\.id)
            items.append(.submenu("Rækkefølge", icon: "arrow.up.arrow.down", [
                .action("Øverst", icon: "arrow.up.to.line") { usb.reorder(d, playlist: pid, order: ids + order.filter { !ids.contains($0) }) },
                .action("Én op", icon: "arrow.up") { usb.reorder(d, playlist: pid, order: Self.shift(order, ids, by: -1)) },
                .action("Én ned", icon: "arrow.down") { usb.reorder(d, playlist: pid, order: Self.shift(order, ids, by: 1)) },
                .action("Nederst", icon: "arrow.down.to.line") { usb.reorder(d, playlist: pid, order: order.filter { !ids.contains($0) } + ids) },
            ]))
        }
        items.append(.divider)
        items.append(.action("Opdatér fra MODULR (waveform, grid og cues)", icon: "arrow.triangle.2.circlepath") {
            usb.refreshFromLibrary(d, tracks: ids, library: library)
        })
        items.append(.action("Importér til biblioteket", icon: "square.and.arrow.down") { library.importFromUsb(files) })
        items.append(.action("Kopiér til computeren…", icon: "folder") { Self.copyToComputer(files) })
        items.append(.action("Vis i Finder", icon: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting(files) })
        items.append(.divider)
        if let pid = nodeID {
            items.append(.action("Fjern fra playlisten", icon: "minus.circle") { usb.removeFromPlaylist(d, playlist: pid, tracks: ids) })
        }
        items.append(.action("Slet fra USB'en…", icon: "trash", destructive: true) { confirmDelete(ids, drive: d, list: list) })
        return items
    }

    func confirmDelete(_ ids: [Int], drive d: UsbDrive, list: [UsbTrackInfo]) {
        let name = ids.count == 1 ? "\"\(list.first { $0.id == ids[0] }?.title ?? "sangen")\"" : "\(ids.count) sange"
        Dialogs.shared.confirm("Slet \(name) fra \(d.name)?",
                               message: "Sangen fjernes fra alle playlister på USB'en, og filen slettes fra stikket. Dit bibliotek på computeren røres ikke.",
                               icon: "trash.fill", button: "Slet", destructive: true) {
            selection = []
            usb.deleteTracks(d, tracks: ids)
        }
    }

    /// Flyt de valgte ét trin op/ned, men behold deres indbyrdes rækkefølge.
    static func shift(_ order: [Int], _ ids: [Int], by step: Int) -> [Int] {
        var o = order
        let sel = Set(ids)
        let idxs = o.indices.filter { sel.contains(o[$0]) }
        for i in (step < 0 ? idxs : idxs.reversed()) {
            let j = i + step
            guard j >= 0, j < o.count, !sel.contains(o[j]) else { continue }
            o.swapAt(i, j)
        }
        return o
    }

    static func copyToComputer(_ files: [URL]) {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "Kopiér hertil"
        p.message = "Vælg hvor sangene skal ligge på computeren"
        guard p.runModal() == .OK, let dir = p.url else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            var n = 0
            for f in files {
                let dest = dir.appendingPathComponent(f.lastPathComponent)
                if !FileManager.default.fileExists(atPath: dest.path), (try? FileManager.default.copyItem(at: f, to: dest)) != nil { n += 1 }
            }
            let count = n
            DispatchQueue.main.async { UsbStore.shared.message = "\(count) sang\(count == 1 ? "" : "e") kopieret til \(dir.lastPathComponent)." }
        }
    }
}

/// Et træk fra USB-listen: tekst til MODULRs playlister og selve filen til Finder/skrivebordet.
struct UsbDragItem: Transferable {
    let text: String
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.text)
        ProxyRepresentation(exporting: \.file)
    }

    static func encode(ids: [Int], drive: String) -> String {
        "usbtracks:" + ids.map(String.init).joined(separator: ",") + "@" + drive
    }

    /// (drev-id, track-id'er) fra en trukket tekst.
    static func decode(_ s: String) -> (drive: String, ids: [Int])? {
        guard s.hasPrefix("usbtracks:") else { return nil }
        let body = s.dropFirst("usbtracks:".count)
        guard let at = body.firstIndex(of: "@") else { return nil }
        let ids = body[..<at].split(separator: ",").compactMap { Int($0) }
        return (String(body[body.index(after: at)...]), ids)
    }

    /// Filerne på USB'en for en trukket tekst.
    static func files(_ s: String) -> [URL] {
        guard let r = decode(s), let d = UsbStore.shared.drives.first(where: { $0.id == r.drive }) else { return [] }
        let tracks = UsbStore.shared.contents[r.drive]?.tracks ?? []
        return r.ids.compactMap { id in tracks.first { $0.id == id }?.fileURL(root: d.url) }
    }
}

struct UsbCoverCell: View {
    let track: UsbTrackInfo
    let root: URL
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06))
            if let u = track.artworkURL(root: root), let img = CoverCache.file(u) {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 10)).foregroundColor(.mist.opacity(0.3))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct UsbIndexCell: View {
    let index: Int
    var body: some View { Text(String(index)).foregroundColor(Color.mist.opacity(0.4)) }
}

struct UsbTextCell: View {
    let text: String
    let alpha: Double
    var body: some View { Text(text).monospacedDigit().foregroundColor(Color.mist.opacity(alpha)).lineLimit(1) }
}

/// Passer to tonearter harmonisk? (samme, ±1 på Camelot-hjulet eller dur/mol-parallel)
enum KeyMatch {
    static let green = Color(red: 0.3, green: 0.9, blue: 0.45)
    static func fits(_ k: MusicalKey, _ playing: MusicalKey?) -> Bool {
        guard let p = playing else { return false }
        return k == p || p.compatible.contains(k)
    }
}

struct UsbKeyCell: View {
    @ObservedObject private var now = NowPlayingKey.shared
    let key: String
    var body: some View {
        if let k = MusicalKey.parse(key) {
            KeyPill(key: k)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(KeyMatch.green, lineWidth: KeyMatch.fits(k, now.key) ? 2 : 0).padding(-2))
        } else {
            Text(key).foregroundColor(Color.mist.opacity(0.6))
        }
    }
}

extension UsbTrackInfo {
    static func bpmText(_ b: Double) -> String { b > 0 ? String(Int(b.rounded())) : "–" }
    static func timeText(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
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
    @ObservedObject private var library = LibraryStore.shared
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
