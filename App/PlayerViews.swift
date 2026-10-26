// MODULR – afspiller-panelet: detaljewaveform med zoom, beatgrid (takt/slag/fraser), markører,
// grid-redigering som i rekordbox, EQ med knapper og niveaumåler. Plus "Fiks tracks"-panelet.

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
                        DetailWaveform(track: t, zoom: $zoom, gridMode: mode == .grid)
                            .frame(height: 104)
                        OverviewWaveform(track: t, zoom: zoom).frame(height: 30)
                        switch mode {
                        case .grid: GridEditBar(track: t)
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
            Cover(track: t, size: 44, fallbackURL: player.externalArt)
            VStack(alignment: .leading, spacing: 2) {
                Text(t?.title ?? "Dobbeltklik på en sang for at afspille den")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.mist).lineLimit(1)
                Text(t.map { $0.artist.isEmpty ? "Ukendt kunstner" : $0.artist } ?? "Vælg en sang for at se waveform, grid, EQ og niveau")
                    .font(.system(size: 12)).foregroundColor(.mist.opacity(0.6)).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let t {
                if let k = t.key { KeyPill(key: k) }
                Text(t.bpmText).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
                    .fixedSize()
                LevelMeter()
                    .frame(width: 120, height: 14)
                if !compact {
                    ModSegmented(selection: $mode, options: [(PlayerMode.play, "Afspil"), (PlayerMode.grid, "Grid"),
                                                             (PlayerMode.cues, "Cues"), (PlayerMode.eq, "EQ")])
                        .frame(width: 236)
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
    @State private var hover = false

    static let zoomSteps: [Double] = [2, 4, 8, 16, 32, 64]

    var firstBeat: Double { (track.firstBeatMs ?? 0) / 1000 + gridShift }

    var body: some View {
        GeometryReader { geo in
            let w: Double = Double(geo.size.width)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                hud
            }
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(gridMode ? Color.ember.opacity(0.7) : Color.hairline, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(pos.bar).\(pos.beat)")
                        .font(.system(size: 15, weight: .bold)).monospacedDigit()
                        .foregroundColor(Color(red: 0.35, green: 0.6, blue: 1))
                    Text("Bars").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(red: 0.35, green: 0.6, blue: 1))
                    Text(pos.barsToPhrase == 8 && pos.beat == 1 ? "· ny frase" : "· frase om \(pos.barsToPhrase)")
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.6))
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
            }
            Spacer()
            if hover {
                HStack(spacing: 2) {
                    zoomButton("minus.magnifyingglass", out: true)
                    Text(String(format: "%.0f s", zoom))
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.7)).frame(width: 34)
                    zoomButton("plus.magnifyingglass", out: false)
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.7)))
                .transition(.opacity)
            }
        }
        .padding(4)
        .animation(.easeOut(duration: 0.12), value: hover)
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
                        GridHistory.shared.push(track)
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
        let rate = MusicAnalyzer.waveformRate
        let secsPerPx = zoom / max(1, w)
        let t0 = player.position - zoom / 2
        let mid = h / 2
        let gridTop = 10.0, gridBottom = h - 10

        // 1) Beatgrid bag waveformen: grå slag, takter med små trekanter, orange fraser med taktnummer
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
                        ctx.fill(Path(CGRect(x: x - 0.75, y: gridTop, width: 1.5, height: gridBottom - gridTop)),
                                 with: .color(Color.ember.opacity(0.9)))
                        let bar = Int(floor(Double(k) / Double(BeatGrid.beatsPerBar))) + 1
                        ctx.draw(Text("\(bar)").font(.system(size: 11, weight: .bold)).foregroundColor(Color.ember),
                                 at: CGPoint(x: x + 4, y: h - 6), anchor: .leading)
                    } else if inBar == 0 || pxPerBeat > 5 {
                        let a: Double = inBar == 0 ? 0.42 : 0.18
                        ctx.fill(Path(CGRect(x: x - 0.5, y: gridTop, width: 1, height: gridBottom - gridTop)),
                                 with: .color(Color.white.opacity(a)))
                    }
                    if inBar == 0 {
                        // Små trekanter øverst og nederst som i rekordbox (røde på takt 1 i en frase)
                        let c: Color = inPhrase == 0 ? Color.ember : Color(red: 0.9, green: 0.2, blue: 0.2)
                        var top = Path()
                        top.move(to: CGPoint(x: x - 4, y: gridTop - 6))
                        top.addLine(to: CGPoint(x: x + 4, y: gridTop - 6))
                        top.addLine(to: CGPoint(x: x, y: gridTop))
                        top.closeSubpath()
                        ctx.fill(top, with: .color(c))
                        var bottom = Path()
                        bottom.move(to: CGPoint(x: x - 4, y: gridBottom + 6))
                        bottom.addLine(to: CGPoint(x: x + 4, y: gridBottom + 6))
                        bottom.addLine(to: CGPoint(x: x, y: gridBottom))
                        bottom.closeSubpath()
                        ctx.fill(bottom, with: .color(c))
                    } else if pxPerBeat > 5 {
                        ctx.fill(Path(CGRect(x: x - 2, y: gridTop - 3, width: 4, height: 3)), with: .color(Color.white.opacity(0.35)))
                        ctx.fill(Path(CGRect(x: x - 2, y: gridBottom, width: 4, height: 3)), with: .color(Color.white.opacity(0.35)))
                    }
                }
                k += 1
            }
        }

        // 2) Waveformen: én pixel ad gangen, blødt interpoleret mellem analysens kolonner, mættede farver
        if bands.count >= 3 {
            let halfH = (gridBottom - gridTop) / 2 - 2
            var x = 0.0
            while x < w {
                let t = t0 + (x + 0.5) * secsPerPx
                if t >= 0 && t <= player.duration {
                    let col = t * rate
                    var lo: Double, mi: Double, hi: Double
                    if secsPerPx * rate > 1.5 {
                        // Zoomet ud: største værdi i pixlens kolonner (så toppe ikke forsvinder)
                        let a = Int(col - secsPerPx * rate / 2), b = Int(col + secsPerPx * rate / 2) + 1
                        lo = 0; mi = 0; hi = 0
                        let cols = bands.count / 3
                        for c in max(0, a)..<min(cols, max(a + 1, b)) {
                            lo = max(lo, Double(bands[c * 3]))
                            mi = max(mi, Double(bands[c * 3 + 1]))
                            hi = max(hi, Double(bands[c * 3 + 2]))
                        }
                    } else {
                        lo = WaveColor.sample(bands, at: col, band: 0)
                        mi = WaveColor.sample(bands, at: col, band: 1)
                        hi = WaveColor.sample(bands, at: col, band: 2)
                    }
                    let top = max(lo, max(mi, hi))
                    if top > 0, let c = WaveColor.rgb(lo, mi, hi, floor: 0.08) {
                        let bh = top / 255 * halfH
                        let played: Bool = t <= player.position
                        let dim: Double = played ? 0.85 : 1
                        ctx.fill(Path(CGRect(x: x, y: mid - bh, width: 1, height: bh * 2)),
                                 with: .color(Color(red: c.r * dim, green: c.g * dim, blue: c.b * dim)))
                    }
                }
                x += 1
            }
        } else {
            ctx.draw(Text(PlayerModel.shared.analyzingWave ? "Analyserer waveform …" : "Ingen waveform")
                        .font(.system(size: 12)).foregroundColor(.mist.opacity(0.5)),
                     at: CGPoint(x: w / 2, y: mid))
        }

        // 3) Dine markører (cues)
        for (i, cue) in (track.cues ?? []).enumerated() where cue >= t0 && cue <= t0 + zoom {
            let x = (cue - t0) / secsPerPx
            let amber = Color(red: 1, green: 0.62, blue: 0.2)
            ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: h)), with: .color(amber))
            var tri = Path()
            tri.move(to: CGPoint(x: x - 6, y: h))
            tri.addLine(to: CGPoint(x: x + 6, y: h))
            tri.addLine(to: CGPoint(x: x, y: h - 9))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(amber))
            let letter = String(UnicodeScalar(UInt8(65 + i % 26)))
            ctx.draw(Text(letter).font(.system(size: 11, weight: .bold)).foregroundColor(amber),
                     at: CGPoint(x: x + 5, y: 22), anchor: .leading)
        }

        // 4) Afspilningshoved i midten
        ctx.fill(Path(CGRect(x: w / 2 - 1, y: 0, width: 2, height: h)), with: .color(.white))
    }
}

// MARK: - Overblik (hele sangen, klik/træk for at spole)

struct OverviewWaveform: View {
    @ObservedObject private var player = PlayerModel.shared
    @ObservedObject private var library = LibraryStore.shared
    let track: LibTrack
    let zoom: Double?
    @State private var hover = false

    var body: some View {
        GeometryReader { geo in
            let w: CGFloat = geo.size.width
            let dur: Double = max(0.001, player.duration)
            let frac: CGFloat = CGFloat(player.position / dur)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35))
                if let img = player.overviewImage(width: 1200, height: 60) {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).opacity(0.45)
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * frac)) }
                }
                if let zoom, hover {
                    let zw: CGFloat = max(4, w * CGFloat(zoom / dur))
                    RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1)
                        .frame(width: zw)
                        .offset(x: w * frac - zw / 2)
                }
                ForEach(Array((track.cues ?? []).enumerated()), id: \.offset) { item in
                    let x: CGFloat = w * CGFloat(item.element / dur)
                    Text(String(UnicodeScalar(UInt8(65 + item.offset % 26))))
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.void)
                        .frame(width: 11, height: 11)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: 1, green: 0.62, blue: 0.2)))
                        .offset(x: x - 5.5, y: 0)
                }
                Rectangle().fill(Color.white).frame(width: 2).offset(x: w * frac - 1)
                if hover {
                    HStack {
                        Text(timeText(player.position))
                        Spacer()
                        Text("-" + timeText(max(0, player.duration - player.position)))
                    }
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
                    .padding(.horizontal, 6)
                    .shadow(color: .black, radius: 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                player.seek(Double(max(0, min(1, v.location.x / max(1, w)))))
            })
        }
    }

    func timeText(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Niveaumåler (som rekordbox: to tynde vandrette bjælker, grøn → orange)

struct LevelMeter: View {
    @ObservedObject private var player = PlayerModel.shared
    static let minDB = -36.0
    static let maxDB = 0.0

    static func frac(_ db: Double) -> Double { max(0, min(1, (db - minDB) / (maxDB - minDB))) }

    var body: some View {
        let l: Double = LevelMeter.frac(player.levelL)
        let r: Double = LevelMeter.frac(player.levelR)
        let hold: Double = LevelMeter.frac(player.holdDB)
        let clipped: Bool = player.clipped
        Canvas { ctx, size in
            let w = Double(size.width)
            let barH = 4.0
            let gap = 4.0
            let y0 = (Double(size.height) - barH * 2 - gap) / 2
            let gradient = Gradient(stops: [
                .init(color: Color(red: 0.25, green: 0.75, blue: 0.35), location: 0),
                .init(color: Color(red: 0.25, green: 0.75, blue: 0.35), location: 0.62),
                .init(color: Color(red: 0.95, green: 0.62, blue: 0.2), location: 0.9),
                .init(color: Color(red: 1, green: 0.25, blue: 0.2), location: 1)
            ])
            for (i, v) in [l, r].enumerated() {
                let y = y0 + Double(i) * (barH + gap)
                let track = Path(roundedRect: CGRect(x: 0, y: y, width: w, height: barH), cornerRadius: 1)
                ctx.fill(track, with: .color(Color.white.opacity(0.08)))
                if v > 0 {
                    let fill = Path(roundedRect: CGRect(x: 0, y: y, width: w * v, height: barH), cornerRadius: 1)
                    ctx.fill(fill, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: 0)))
                }
                if hold > 0 {
                    ctx.fill(Path(CGRect(x: w * hold - 1, y: y, width: 2, height: barH)), with: .color(Color.white.opacity(0.85)))
                }
            }
            if clipped {
                ctx.fill(Path(roundedRect: CGRect(x: w - 4, y: y0 - 1, width: 4, height: barH * 2 + gap + 2), cornerRadius: 1),
                         with: .color(Color(red: 1, green: 0.2, blue: 0.18)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player.resetClip() }
        .help(String(format: "Niveau efter EQ: top %.1f dBFS. Orange = tæt på 0, rød kant = klippet (klik for at nulstille).",
                     player.holdDB))
    }
}

// MARK: - Grid-redigering (som rekordbox' GRID EDIT)

/// Fortryd/gentag for grid-ændringer.
final class GridHistory {
    static let shared = GridHistory()
    private var undoStack: [UUID: [(Double, Double)]] = [:]
    private var redoStack: [UUID: [(Double, Double)]] = [:]

    func push(_ t: LibTrack) {
        undoStack[t.id, default: []].append((t.bpm ?? 0, t.firstBeatMs ?? 0))
        redoStack[t.id] = []
    }

    func canUndo(_ id: UUID) -> Bool { !(undoStack[id] ?? []).isEmpty }
    func canRedo(_ id: UUID) -> Bool { !(redoStack[id] ?? []).isEmpty }

    func undo(_ t: LibTrack) {
        guard let last = undoStack[t.id]?.popLast() else { return }
        redoStack[t.id, default: []].append((t.bpm ?? 0, t.firstBeatMs ?? 0))
        LibraryStore.shared.setGrid(t.id, bpm: last.0, firstBeatMs: last.1)
    }

    func redo(_ t: LibTrack) {
        guard let next = redoStack[t.id]?.popLast() else { return }
        undoStack[t.id, default: []].append((t.bpm ?? 0, t.firstBeatMs ?? 0))
        LibraryStore.shared.setGrid(t.id, bpm: next.0, firstBeatMs: next.1)
    }
}

struct GridEditBar: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack
    @State private var taps: [Date] = []

    var bpm: Double { track.bpm ?? 0 }
    var fbMs: Double { track.firstBeatMs ?? 0 }

    var body: some View {
        HStack(spacing: 6) {
            Text("GRID EDIT")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.mist.opacity(0.8))
                .frame(width: 64, alignment: .leading)
            Text(String(format: "%.2f", bpm))
                .font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
                .frame(width: 70, height: 30)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.6)))
            Group {
                gridButton(text: "TAP", help: "Tap tempoet i takt med musikken") { tap() }
                gridButton(icon: "chevron.left", bars: true, help: "Skub griddet til venstre (5 ms)") { shift(-5) }
                gridButton(icon: "chevron.right", bars: true, trailing: true, help: "Skub griddet til højre (5 ms)") { shift(5) }
                gridButton(text: "◂|||▸", help: "Større afstand mellem slagene (BPM −0,01)") { setBPM(bpm - 0.01) }
                gridButton(text: "▸|||◂", help: "Mindre afstand mellem slagene (BPM +0,01)") { setBPM(bpm + 0.01) }
            }
            Group {
                gridButton(text: "|||×2", help: "Dobbelt BPM") { setBPM(bpm * 2) }
                gridButton(text: "|||×½", help: "Halv BPM") { setBPM(bpm / 2) }
                gridButton(icon: "arrow.uturn.backward", help: "Fortryd") { GridHistory.shared.undo(track) }
                    .disabled(!GridHistory.shared.canUndo(track.id))
                gridButton(icon: "arrow.uturn.forward", help: "Gentag") { GridHistory.shared.redo(track) }
                    .disabled(!GridHistory.shared.canRedo(track.id))
                gridButton(icon: "1.square", help: "Takt 1 her: sæt takt 1 ved afspilningshovedet") { downbeatHere() }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    func gridButton(icon: String? = nil, text: String? = nil, bars: Bool = false, trailing: Bool = false,
                    help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 1) {
                if bars && trailing { Text("|||").font(.system(size: 11, weight: .bold)) }
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .bold)) }
                if let text { Text(text).font(.system(size: 11, weight: .bold)).monospacedDigit() }
                if bars && !trailing { Text("|||").font(.system(size: 11, weight: .bold)) }
            }
            .foregroundColor(.mist.opacity(0.9))
            .frame(minWidth: 34, minHeight: 30)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    func downbeatHere() {
        GridHistory.shared.push(track)
        let fb = BeatGrid.downbeat(at: player.position, bpm: bpm)
        LibraryStore.shared.setGrid(track.id, bpm: bpm, firstBeatMs: fb * 1000)
    }

    func shift(_ ms: Double) {
        GridHistory.shared.push(track)
        LibraryStore.shared.setGrid(track.id, bpm: bpm, firstBeatMs: fbMs + ms)
    }

    func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 { taps = [] }
        taps.append(now)
        if taps.count > 8 { taps.removeFirst(taps.count - 8) }
        guard taps.count >= 4 else { return }
        let span = taps.last!.timeIntervalSince(taps.first!)
        let v = 60 / (span / Double(taps.count - 1))
        setBPM(v)
    }

    func setBPM(_ v: Double) {
        guard v > 20, v < 400 else { return }
        GridHistory.shared.push(track)
        // Hold slaget ved afspilningshovedet fast, så griddet ikke glider væk der hvor du lytter
        let oldBeat = 60 / max(bpm, 1)
        let newBeat = 60 / v
        let fb = fbMs / 1000
        let k = Double(BeatGrid.beatIndex(at: player.position, bpm: bpm, firstBeat: fb))
        let anchor = fb + k * oldBeat
        let newFB = anchor - k * newBeat
        LibraryStore.shared.setGrid(track.id, bpm: (v * 100).rounded() / 100, firstBeatMs: newFB * 1000)
    }
}

// MARK: - Cues (markører)

struct CueTools: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var cues: [Double] { track.cues ?? [] }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                LibraryStore.shared.addCue(track.id, at: snapped(player.position))
            } label: { Label("Cue her", systemImage: "flag.fill") }
                .buttonStyle(.ember)
                .help("Sætter en cue på nærmeste slag – fx hvor du vil mixe ind eller ud")
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
                Text("Næste cue om \(beats / 4) takter \(beats % 4) slag")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundColor(Color(red: 1, green: 0.62, blue: 0.2))
            } else {
                Text("\(cues.count) cues").font(.system(size: 12)).foregroundColor(.mist.opacity(0.6))
            }
        }
    }

    func snapped(_ t: Double) -> Double {
        guard let bpm = track.bpm, bpm > 0 else { return t }
        let beat = 60 / bpm
        let fb = (track.firstBeatMs ?? 0) / 1000
        return max(0, fb + ((t - fb) / beat).rounded() * beat)
    }
}

// MARK: - EQ med drejeknapper

/// Drejeknap: træk op/ned for at skrue, dobbeltklik for 0 dB.
struct Knob: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -12...6
    @State private var start: Double?

    var body: some View {
        let span: Double = range.upperBound - range.lowerBound
        let f: Double = (value - range.lowerBound) / span
        let zeroF: Double = (0 - range.lowerBound) / span
        let startAngle: Double = 135
        let sweep: Double = 270
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color(white: 0.14))
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                // Bue fra 0 dB til værdien
                Circle()
                    .trim(from: min(zeroF, f) * 0.75, to: max(zeroF, f) * 0.75)
                    .stroke(Color.ember, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .padding(-4)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(startAngle))
                    .padding(-4)
                // Viser
                Capsule()
                    .fill(Color.mist)
                    .frame(width: 2.5, height: 11)
                    .offset(y: -10)
                    .rotationEffect(.degrees(startAngle + f * sweep - 270))
            }
            .frame(width: 38, height: 38)
            .padding(4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if start == nil { start = value }
                    let delta = -Double(g.translation.height) / 120 * span
                    let v = ((start ?? value) + delta) * 2
                    value = max(range.lowerBound, min(range.upperBound, v.rounded() / 2))
                }
                .onEnded { _ in start = nil })
            .onTapGesture(count: 2) { value = 0 }
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.mist.opacity(0.7))
            Text(String(format: "%+.1f dB", value)).font(.system(size: 11)).monospacedDigit().foregroundColor(.mist)
        }
        .help("Træk op/ned for at skrue. Dobbeltklik = 0 dB.")
    }
}

struct EQPanel: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var body: some View {
        HStack(spacing: 18) {
            Knob(title: "Bas", value: $player.eq.low)
            Knob(title: "Mellem", value: $player.eq.mid)
            Knob(title: "Diskant", value: $player.eq.high)
            VStack(alignment: .leading, spacing: 6) {
                Text("EQ'en høres med det samme. Gem lægger den ind i filen og retter lydstyrken bagefter.")
                    .font(.system(size: 11)).foregroundColor(.mist.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Nulstil") { player.eq = EQSettings() }
                        .buttonStyle(.ghost)
                        .disabled(player.eq.isFlat)
                    Button("Gem i filen…") { save() }
                        .buttonStyle(.ember)
                        .disabled(player.eq.isFlat)
                }
            }
            Spacer(minLength: 0)
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
