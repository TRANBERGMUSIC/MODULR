// MODULR – afspiller-panelet: detaljewaveform med zoom, beatgrid (takt/slag/fraser), markører,
// grid-værktøjer, EQ og niveaumåler. Plus "Fiks tracks"-panelet med før/efter som i Platinum Notes.

import SwiftUI
import AppKit

enum PlayerMode: Hashable { case play, grid, eq, cues }

// MARK: - Panelet

struct PlayerPanel: View {
    @ObservedObject private var player = PlayerModel.shared
    @ObservedObject private var library = LibraryStore.shared
    let compact: Bool
    @State private var mode: PlayerMode = .play
    @State private var zoom: Double = 16          // sekunder synligt i detaljevisningen

    init(compact: Bool = false) {
        self.compact = compact
    }

    var body: some View {
        let t: LibTrack? = player.liveTrack
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                header(t)
                if let t {
                    if compact {
                        OverviewWaveform(track: t, zoom: nil).frame(height: 26)
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 6) {
                                DetailWaveform(track: t, zoom: $zoom, gridMode: mode == .grid)
                                    .frame(height: 96)
                                OverviewWaveform(track: t, zoom: zoom).frame(height: 28)
                            }
                            LevelMeter()
                                .frame(width: 58, height: 130)
                        }
                        switch mode {
                        case .grid: GridTools(track: t)
                        case .eq: EQPanel(track: t)
                        case .cues: CueTools(track: t)
                        case .play: EmptyView()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func header(_ t: LibTrack?) -> some View {
        HStack(spacing: 12) {
            Cover(track: t, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(t?.title ?? "Dobbeltklik på en sang for at afspille den")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.mist).lineLimit(1)
                Text(t.map { $0.artist.isEmpty ? "Ukendt kunstner" : $0.artist } ?? "Vælg en sang for at se waveform, grid, EQ og niveau")
                    .font(.system(size: 12)).foregroundColor(.mist.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let t {
                if let k = t.key { KeyPill(key: k) }
                Text(t.bpmText + " BPM").font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(.mist.opacity(0.8))
                    .fixedSize()
                if !compact {
                    ModSegmented(selection: $mode, options: [(PlayerMode.play, "Afspil"), (PlayerMode.grid, "Grid"),
                                                             (PlayerMode.cues, "Markører"), (PlayerMode.eq, "EQ")])
                        .frame(width: 270)
                }
            }
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.void)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.ember))
            }
            .buttonStyle(.plain)
            .disabled(t == nil)
        }
    }
}

// MARK: - Detaljewaveform (zoom, grid, markører)

struct DetailWaveform: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack
    @Binding var zoom: Double
    let gridMode: Bool
    @State private var dragStart: Double?
    @State private var wasPlaying = false
    @State private var gridShift: Double = 0
    @State private var zoomBase: Double?

    static let zoomSteps: [Double] = [2, 4, 8, 16, 32, 64]

    var firstBeat: Double { (track.firstBeatMs ?? 0) / 1000 + gridShift }

    var body: some View {
        GeometryReader { geo in
            let w: Double = Double(geo.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                hud
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.45)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(gridMode ? Color.ember.opacity(0.7) : Color.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(drag(width: w))
            .simultaneousGesture(MagnificationGesture()
                .onChanged { s in
                    if zoomBase == nil { zoomBase = zoom }
                    zoom = max(2, min(64, (zoomBase ?? zoom) / Double(s)))
                }
                .onEnded { _ in zoomBase = nil })
        }
    }

    var hud: some View {
        let pos = BeatGrid.position(at: player.position, bpm: track.bpm ?? 0, firstBeat: firstBeat)
        let hasGrid: Bool = (track.bpm ?? 0) > 0
        return HStack(alignment: .top) {
            if hasGrid {
                HStack(spacing: 8) {
                    Text("Takt \(pos.bar).\(pos.beat)")
                        .font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundColor(.mist)
                    Text(pos.barsToPhrase == 8 && pos.beat == 1 ? "Ny frase" : "Frase om \(pos.barsToPhrase) takter")
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.7))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
            }
            Spacer()
            HStack(spacing: 2) {
                zoomButton("minus.magnifyingglass", out: true)
                Text(String(format: "%.0f s", zoom))
                    .font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.7)).frame(width: 34)
                zoomButton("plus.magnifyingglass", out: false)
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
        }
        .padding(6)
    }

    func zoomButton(_ icon: String, out: Bool) -> some View {
        Button {
            let steps = DetailWaveform.zoomSteps
            if out {
                zoom = steps.first(where: { $0 > zoom + 0.01 }) ?? steps.last!
            } else {
                zoom = steps.last(where: { $0 < zoom - 0.01 }) ?? steps.first!
            }
        } label: {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(.mist.opacity(0.85))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(out ? "Zoom ud" : "Zoom ind (eller knib på pegefeltet)")
    }

    func drag(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let secsPerPx = zoom / max(1, width)
                if gridMode {
                    // Skub griddet: træk til højre = slagene flyttes til højre
                    gridShift = Double(v.translation.width) * secsPerPx
                } else {
                    if dragStart == nil {
                        dragStart = player.position
                        wasPlaying = player.playing
                        if wasPlaying { player.pause() }
                    }
                    player.seek(seconds: (dragStart ?? 0) - Double(v.translation.width) * secsPerPx)
                }
            }
            .onEnded { _ in
                if gridMode {
                    if abs(gridShift) > 0.0005 {
                        LibraryStore.shared.setGrid(track.id, bpm: track.bpm ?? 0, firstBeatMs: firstBeat * 1000)
                    }
                    gridShift = 0
                } else {
                    if wasPlaying { player.play() }
                    dragStart = nil
                }
            }
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let w = Double(size.width), h = Double(size.height)
        let bands = player.bands
        let cols = bands.count / 3
        let rate = MusicAnalyzer.waveformRate
        let secsPerPx = zoom / max(1, w)
        let t0 = player.position - zoom / 2
        let mid = h / 2

        // Waveform (spejlet om midten, som rekordbox' detaljevisning)
        if cols > 0 {
            var x = 0.0
            while x < w {
                let ta = t0 + x * secsPerPx
                let tb = ta + secsPerPx * 2
                if tb > 0, ta < player.duration {
                    let a = Int(ta * rate), b = max(a + 1, Int(tb * rate))
                    if let c = WaveColor.column(bands, a, b) {
                        let bh = c.height * (h * 0.46)
                        let color = Color(red: c.r, green: c.g, blue: c.b)
                        ctx.fill(Path(CGRect(x: x, y: mid - bh, width: 2, height: bh * 2)), with: .color(color))
                    }
                }
                x += 2
            }
        }

        // Beatgrid: slag, takter og 8-takters fraser
        if let bpm = track.bpm, bpm > 0 {
            let beat = 60 / bpm
            let fb = firstBeat
            var k = Int(floor((t0 - fb) / beat))
            let pxPerBeat = beat / secsPerPx
            while true {
                let tb = fb + Double(k) * beat
                if tb > t0 + zoom { break }
                if tb >= 0 && tb <= player.duration {
                    let x = (tb - t0) / secsPerPx
                    let inBar = BeatGrid.mod(k, BeatGrid.beatsPerBar)
                    let inPhrase = BeatGrid.mod(k, BeatGrid.beatsPerBar * BeatGrid.barsPerPhrase)
                    if inPhrase == 0 {
                        ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)), with: .color(Color.ember.opacity(0.95)))
                        let bar = Int(floor(Double(k) / Double(BeatGrid.beatsPerBar))) + 1
                        ctx.draw(Text("\(bar)").font(.system(size: 11, weight: .bold)).foregroundColor(Color.ember),
                                 at: CGPoint(x: x + 4, y: h - 9), anchor: .leading)
                    } else if inBar == 0 {
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)), with: .color(Color.white.opacity(0.55)))
                    } else if pxPerBeat > 6 {
                        ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: 8)), with: .color(Color.white.opacity(0.35)))
                        ctx.fill(Path(CGRect(x: x - 0.5, y: h - 8, width: 1, height: 8)), with: .color(Color.white.opacity(0.35)))
                    }
                }
                k += 1
            }
        }

        // Dine markører
        for (i, cue) in (track.cues ?? []).enumerated() where cue >= t0 && cue <= t0 + zoom {
            let x = (cue - t0) / secsPerPx
            let amber = Color(red: 1, green: 0.82, blue: 0.4)
            ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: h)), with: .color(amber))
            var tri = Path()
            tri.move(to: CGPoint(x: x - 6, y: 0))
            tri.addLine(to: CGPoint(x: x + 6, y: 0))
            tri.addLine(to: CGPoint(x: x, y: 8))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(amber))
            ctx.draw(Text("M\(i + 1)").font(.system(size: 11, weight: .bold)).foregroundColor(amber),
                     at: CGPoint(x: x + 5, y: 16), anchor: .leading)
        }

        // Afspilningshoved i midten
        ctx.fill(Path(CGRect(x: w / 2 - 1, y: 0, width: 2, height: h)), with: .color(.white))
    }
}

// MARK: - Overblik (hele sangen, klik/træk for at spole)

struct OverviewWaveform: View {
    @ObservedObject private var player = PlayerModel.shared
    @ObservedObject private var library = LibraryStore.shared
    let track: LibTrack
    let zoom: Double?

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let dur: Double = max(0.001, player.duration)
            let frac: CGFloat = CGFloat(player.position / dur)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35))
                if let img = WaveformCache.shared.image(for: track, width: 1200, height: 60, store: library) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium).opacity(0.5)
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * frac)) }
                }
                if let zoom {
                    let zw: CGFloat = max(4, w * CGFloat(zoom / dur))
                    RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1)
                        .frame(width: zw)
                        .offset(x: w * frac - zw / 2)
                }
                ForEach(Array((track.cues ?? []).enumerated()), id: \.offset) { item in
                    Rectangle().fill(Color(red: 1, green: 0.82, blue: 0.4)).frame(width: 2)
                        .offset(x: w * CGFloat(item.element / dur) - 1)
                }
                Rectangle().fill(Color.white).frame(width: 2).offset(x: w * frac - 1)
                HStack {
                    Text(timeText(player.position))
                    Spacer()
                    Text("-" + timeText(max(0, player.duration - player.position)))
                }
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(.mist.opacity(0.8))
                .padding(.horizontal, 6)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                player.seek(Double(max(0, min(1, v.location.x / max(1, w)))))
            })
        }
    }

    func timeText(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Niveaumåler

struct LevelMeter: View {
    @ObservedObject private var player = PlayerModel.shared
    static let minDB = -48.0
    static let maxDB = 3.0

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                bar(player.levelL)
                bar(player.levelR)
                scale
            }
            Text(player.holdDB > -79 ? String(format: "%.1f", player.holdDB) : "–")
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundColor(player.holdDB > -1 ? Color(red: 1, green: 0.4, blue: 0.36) : .mist.opacity(0.8))
            Button { player.resetClip() } label: {
                Text("CLIP")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(player.clipped ? .white : .mist.opacity(0.4))
                    .frame(width: 44, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(player.clipped ? Color(red: 0.9, green: 0.2, blue: 0.18) : Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("Lyser rødt hvis sangen har ramt 0 dBFS (klipper). Klik for at nulstille.")
        }
        .help("Sangens niveau efter EQ (dBFS). Rødt felt = over −1 dBFS.")
    }

    static func frac(_ db: Double) -> Double { max(0, min(1, (db - minDB) / (maxDB - minDB))) }

    func bar(_ db: Double) -> some View {
        let hold: Double = player.holdDB
        return Canvas { ctx, size in
            let h = Double(size.height), w = Double(size.width)
            let green = Color(red: 0.36, green: 0.85, blue: 0.45)
            let yellowC = Color(red: 1, green: 0.8, blue: 0.3)
            let redC = Color(red: 1, green: 0.27, blue: 0.22)
            let red = LevelMeter.frac(-1) * h
            let yellow = LevelMeter.frac(-9) * h
            let level = LevelMeter.frac(db) * h
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(Color.white.opacity(0.06)))
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h - red)), with: .color(redC.opacity(0.2)))
            let g = min(level, yellow)
            if g > 0 { ctx.fill(Path(CGRect(x: 0, y: h - g, width: w, height: g)), with: .color(green)) }
            if level > yellow {
                let top = min(level, red)
                ctx.fill(Path(CGRect(x: 0, y: h - top, width: w, height: top - yellow)), with: .color(yellowC))
            }
            if level > red {
                ctx.fill(Path(CGRect(x: 0, y: h - level, width: w, height: level - red)), with: .color(redC))
            }
            if hold > LevelMeter.minDB {
                let y = h - LevelMeter.frac(hold) * h
                ctx.fill(Path(CGRect(x: 0, y: y - 1, width: w, height: 2)), with: .color(.white))
            }
        }
        .frame(width: 9)
    }

    var scale: some View {
        GeometryReader { g in
            let h: Double = Double(g.size.height)
            ForEach([0.0, -6.0, -12.0, -24.0], id: \.self) { db in
                Text(db == 0 ? "0" : String(Int(db)))
                    .font(.system(size: 10)).monospacedDigit().foregroundColor(.mist.opacity(0.55))
                    .position(x: 10, y: h - LevelMeter.frac(db) * h)
            }
        }
        .frame(width: 20)
    }
}

// MARK: - Grid-værktøjer

struct GridTools: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var bpm: Double { track.bpm ?? 0 }
    var fbMs: Double { track.firstBeatMs ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                tool("−0.1") { setBPM(bpm - 0.1) }
                tool("−0.01") { setBPM(bpm - 0.01) }
                Text(String(format: "%.2f BPM", bpm))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
                    .frame(width: 92)
                tool("+0.01") { setBPM(bpm + 0.01) }
                tool("+0.1") { setBPM(bpm + 0.1) }
                tool("½") { setBPM(bpm / 2) }
                tool("×2") { setBPM(bpm * 2) }
            }
            Divider().frame(height: 18)
            tool("◀ 5 ms") { LibraryStore.shared.setGrid(track.id, bpm: bpm, firstBeatMs: fbMs - 5) }
            tool("5 ms ▶") { LibraryStore.shared.setGrid(track.id, bpm: bpm, firstBeatMs: fbMs + 5) }
            Divider().frame(height: 18)
            Button("Takt 1 her") {
                let fb = BeatGrid.downbeat(at: player.position, bpm: bpm)
                LibraryStore.shared.setGrid(track.id, bpm: bpm, firstBeatMs: fb * 1000)
            }
            .buttonStyle(.ember)
            .help("Sæt takt 1 ved afspilningshovedet")
            Spacer(minLength: 0)
            Text("Træk i waveformen for at skubbe griddet")
                .font(.system(size: 11)).foregroundColor(.mist.opacity(0.55)).lineLimit(1)
        }
    }

    func setBPM(_ v: Double) {
        guard v > 0 else { return }
        // Hold slaget ved afspilningshovedet fast, så griddet ikke glider væk der hvor du lytter
        let oldBeat = 60 / max(bpm, 1)
        let newBeat = 60 / v
        let fb = fbMs / 1000
        let k = Double(BeatGrid.beatIndex(at: player.position, bpm: bpm, firstBeat: fb))
        let anchor = fb + k * oldBeat
        let newFB = anchor - k * newBeat
        LibraryStore.shared.setGrid(track.id, bpm: (v * 100).rounded() / 100, firstBeatMs: newFB * 1000)
    }

    func tool(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.ghost)
    }
}

// MARK: - Markører

struct CueTools: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var cues: [Double] { track.cues ?? [] }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                LibraryStore.shared.addCue(track.id, at: snapped(player.position))
            } label: { Label("Markør her", systemImage: "flag.fill") }
                .buttonStyle(.ember)
                .help("Sætter en markør på nærmeste slag – fx hvor du vil mixe ind eller ud")
            Button {
                if let c = cues.last(where: { $0 < player.position - 0.2 }) { player.seek(seconds: c) }
            } label: { Image(systemName: "backward.end.fill") }
                .buttonStyle(.ghost)
            Button {
                if let c = cues.first(where: { $0 > player.position + 0.2 }) { player.seek(seconds: c) }
            } label: { Image(systemName: "forward.end.fill") }
                .buttonStyle(.ghost)
            Button("Fjern nærmeste") {
                LibraryStore.shared.removeCue(track.id, near: player.position, tolerance: 4)
            }
            .buttonStyle(.ghost)
            .disabled(cues.isEmpty)
            Spacer(minLength: 0)
            if let next = cues.first(where: { $0 > player.position + 0.05 }), let bpm = track.bpm, bpm > 0 {
                let beats = Int(((next - player.position) / (60 / bpm)).rounded())
                Text("Næste markør om \(beats / 4) takter \(beats % 4) slag")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(Color(red: 1, green: 0.82, blue: 0.4))
            } else {
                Text("\(cues.count) markører").font(.system(size: 12)).foregroundColor(.mist.opacity(0.6))
            }
        }
    }

    /// Markører lægges på nærmeste slag, så de passer til griddet.
    func snapped(_ t: Double) -> Double {
        guard let bpm = track.bpm, bpm > 0 else { return t }
        let beat = 60 / bpm
        let fb = (track.firstBeatMs ?? 0) / 1000
        return max(0, fb + ((t - fb) / beat).rounded() * beat)
    }
}

// MARK: - EQ

struct EQPanel: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var body: some View {
        HStack(spacing: 14) {
            knob("Bas", value: $player.eq.low)
            knob("Mellem", value: $player.eq.mid)
            knob("Diskant", value: $player.eq.high)
            Button("Nulstil") { player.eq = EQSettings() }
                .buttonStyle(.ghost)
                .disabled(player.eq.isFlat)
            Button("Gem i filen…") { save() }
                .buttonStyle(.ember)
                .disabled(player.eq.isFlat)
        }
    }

    func knob(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundColor(.mist.opacity(0.7)).frame(width: 50, alignment: .leading)
            Slider(value: value, in: -12...6, step: 0.5)
                .tint(Color.ember)
                .frame(minWidth: 70, maxWidth: 140)
            Text(String(format: "%+.1f", value.wrappedValue))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
                .frame(width: 36, alignment: .trailing)
        }
    }

    func save() {
        let eq = player.eq
        let wav: Bool = !["wav", "aif", "aiff"].contains(track.ext)
        let msg = "\(eq.summary). Filen rettes bagefter til \(Int(LoudnessPrefs.target)) LUFS med limiter, så den ikke klipper."
            + (wav ? " \(track.codec) kan ikke skrives uden tab, så den gemmes som 24-bit WAV." : "")
            + " Originalen ligger i Musik/MODULR/Originaler."
        Dialogs.shared.confirm("Læg EQ'en ind i filen?", message: msg, icon: "slider.vertical.3", button: "Gem i filen") {
            LibraryStore.shared.applyEQ(track.id, eq: eq)
            player.eq = EQSettings()
        }
    }
}

// MARK: - Fiks tracks: behandling som i Platinum Notes

struct ProcessPanel: View {
    @ObservedObject private var library = LibraryStore.shared
    @EnvironmentObject var ui: LibraryUIState
    @State private var selected: UUID?

    var focusID: UUID? {
        if ui.tableSelection.count == 1, let id = ui.tableSelection.first { return id }
        return selected ?? library.jobs.first?.id
    }

    var body: some View {
        let jobs = library.jobs
        let done: Int = jobs.filter { $0.status == .done }.count
        let clips: Int = jobs.filter { $0.status == .done }.reduce(0) { $0 + ($1.clips ?? 0) }
        let waiting: Int = jobs.filter { $0.status == .waiting || $0.status == .working }.count
        Panel(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    stat("\(Int(LoudnessPrefs.target)) LUFS", "Mål")
                    Divider().frame(height: 30)
                    stat("\(done)", "Behandlet")
                    Divider().frame(height: 30)
                    stat(clips >= 1000 ? String(format: "%.1fK", Double(clips) / 1000) : "\(clips)", "Klippede toppe rettet")
                    Divider().frame(height: 30)
                    stat("\(waiting)", "I kø")
                    Spacer(minLength: 8)
                    Button {
                        library.fixAllLoudness()
                    } label: {
                        Label("Behandl alle", systemImage: "dial.medium")
                    }
                    .buttonStyle(.ember)
                }
                if !jobs.isEmpty {
                    jobList(jobs)
                }
                BeforeAfter(id: focusID)
                    .frame(height: 74)
            }
        }
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
            Text(label).font(.system(size: 11)).foregroundColor(.mist.opacity(0.6))
        }
        .padding(.horizontal, 14)
    }

    func jobList(_ jobs: [LibraryStore.ProcessJob]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sang").frame(maxWidth: .infinity, alignment: .leading)
                Text("Klip").frame(width: 56, alignment: .trailing)
                Text("Limiter").frame(width: 64, alignment: .trailing)
                Text("LUFS").frame(width: 110, alignment: .trailing)
                Text("Status").frame(width: 130, alignment: .leading).padding(.leading, 12)
            }
            .font(.system(size: 11)).foregroundColor(.mist.opacity(0.55))
            .padding(.horizontal, 8).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(jobs) { j in
                        jobRow(j)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(focusID == j.id ? Color.white.opacity(0.07) : Color.clear))
                            .contentShape(Rectangle())
                            .onTapGesture { selected = j.id; ui.tableSelection = [j.id] }
                    }
                }
            }
            .frame(maxHeight: 84)
        }
    }

    func jobRow(_ j: LibraryStore.ProcessJob) -> some View {
        HStack {
            Text(j.name).foregroundColor(.mist).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(j.clips.map(String.init) ?? "–").frame(width: 56, alignment: .trailing)
            Text(j.limitingDB.map { String(format: "%.1f dB", $0) } ?? "–").frame(width: 64, alignment: .trailing)
            Text(lufsText(j)).frame(width: 110, alignment: .trailing)
            statusText(j).frame(width: 130, alignment: .leading).padding(.leading, 12)
        }
        .font(.system(size: 12)).monospacedDigit().foregroundColor(.mist.opacity(0.8))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .help(j.note)
    }

    func lufsText(_ j: LibraryStore.ProcessJob) -> String {
        let b = j.before.map { String(format: "%.1f", $0) } ?? "–"
        guard let a = j.after else { return b }
        return b + " → " + String(format: "%.1f", a)
    }

    @ViewBuilder
    func statusText(_ j: LibraryStore.ProcessJob) -> some View {
        switch j.status {
        case .waiting: Text("Venter").foregroundColor(.mist.opacity(0.55))
        case .working:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Behandler").foregroundColor(Color.ember)
            }
        case .done: Text("Færdig").foregroundColor(Color(red: 0.36, green: 0.85, blue: 0.45))
        case .skipped: Text("Allerede klar").foregroundColor(.mist.opacity(0.7))
        case .failed: Text("Fejl").foregroundColor(Color(red: 1, green: 0.42, blue: 0.36))
        }
    }
}

/// Før/efter-waveform (top-kurve spejlet om midten). Hvid = klippede toppe.
struct BeforeAfter: View {
    @ObservedObject private var library = LibraryStore.shared
    let id: UUID?

    var body: some View {
        let env = id.map { library.envelopes($0) }
        let busy: Bool = id.map { library.fixing.contains($0) } ?? false
        HStack(spacing: 10) {
            box("Før", env?.before, color: Color.mist.opacity(0.55), note: "hvid = klippede toppe")
            box("Efter", env?.after, color: Color.ember.opacity(0.85), note: busy ? "behandler …" : nil)
        }
    }

    func box(_ title: String, _ e: LoudnessEnvelope?, color: Color, note: String?) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
            if let e, !e.peaks.isEmpty {
                Canvas { ctx, size in
                    let n = e.peaks.count
                    let w = Double(size.width), h = Double(size.height)
                    let mid = h / 2
                    let colW = w / Double(n)
                    for i in 0..<n {
                        let ph = Double(e.peaks[i]) / 255 * (h * 0.46)
                        let x = Double(i) * colW
                        ctx.fill(Path(CGRect(x: x, y: mid - ph, width: colW + 0.5, height: ph * 2)), with: .color(color))
                        if e.clips[i] {
                            ctx.fill(Path(CGRect(x: x, y: mid - ph, width: colW + 0.5, height: 4)), with: .color(.white))
                            ctx.fill(Path(CGRect(x: x, y: mid + ph - 4, width: colW + 0.5, height: 4)), with: .color(.white))
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text(title == "Før" ? "Vælg en behandlet sang for at se før og efter" : "")
                    .font(.system(size: 11)).foregroundColor(.mist.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(.void)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(title == "Før" ? Color.mist : Color.ember))
                Spacer()
                if let note { Text(note).font(.system(size: 11)).foregroundColor(.mist.opacity(0.7)) }
            }
            .padding(6)
        }
    }
}
