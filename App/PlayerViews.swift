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
                        HStack(alignment: .top, spacing: 10) {
                            VStack(spacing: 8) {
                                DetailWaveform(track: t, zoom: $zoom, gridMode: mode == .grid, showSuggestions: mode == .cues)
                                    .frame(height: 104)
                                VStack(spacing: 2) {
                                    OverviewWaveform(track: t, zoom: zoom).frame(height: 38)
                                    BarRuler(track: t).frame(height: 14)
                                    SectionStrip().frame(height: 14)
                                }
                            }
                            DJMMeter()
                                .frame(width: 52, height: 182)
                        }
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
                if !compact {
                    ModSegmented(selection: $mode, options: [(PlayerMode.play, "Afspil"), (PlayerMode.grid, "Grid"),
                                                             (PlayerMode.cues, "Cues"), (PlayerMode.eq, "EQ")])
                        .fixedSize()
                }
            }
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 12, weight: .bold)).foregroundColor(.mist.opacity(0.8))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(t == nil)
            .help("Forrige sang (eller starten af sangen)")
            CDJButtons()
                .disabled(t == nil)
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 12, weight: .bold)).foregroundColor(.mist.opacity(0.8))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(t == nil)
            .help("Næste sang")
        }
    }
}

// MARK: - CUE og PLAY som på en CDJ

/// Orange CUE og grøn PLAY/PAUSE. CUE reagerer på tryk og slip (hold = preview), som på en CDJ.
struct CDJButtons: View {
    @ObservedObject private var player = PlayerModel.shared
    @State private var cueDown = false
    @State private var blink = false
    static let cueOrange = Color(red: 1, green: 0.55, blue: 0.1)
    static let playGreen = Color(red: 0.25, green: 0.85, blue: 0.35)

    var body: some View {
        HStack(spacing: 8) {
            // CUE: lyser på cue-punktet, blinker når du står stille et andet sted
            let cueLit: Bool = player.atCue || player.cuePreviewing || cueDown
            let cueBlink: Bool = !player.playing && !player.atCue
            ZStack {
                Circle().fill(Color(white: 0.1))
                Circle().stroke(CDJButtons.cueOrange.opacity(cueLit || (cueBlink && blink) ? 1 : 0.35), lineWidth: 3)
                Text("CUE").font(.system(size: 11, weight: .heavy))
                    .foregroundColor(cueLit || (cueBlink && blink) ? CDJButtons.cueOrange : CDJButtons.cueOrange.opacity(0.5))
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !cueDown { cueDown = true; player.cueDown() }
                }
                .onEnded { _ in
                    cueDown = false
                    player.cueUp()
                })
            .help("CUE (tast C): under afspilning tilbage til cue-punktet. Stoppet: sæt cue her – hold for at lytte.")
            // PLAY/PAUSE: lyser når den spiller, blinker når den står stille
            Button { player.playPause() } label: {
                ZStack {
                    Circle().fill(Color(white: 0.1))
                    Circle().stroke(CDJButtons.playGreen.opacity(player.playing || blink ? 1 : 0.35), lineWidth: 3)
                    HStack(spacing: 1) {
                        Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                        Image(systemName: "pause.fill").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(player.playing || blink ? CDJButtons.playGreen : CDJButtons.playGreen.opacity(0.5))
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .help("Play/pause (mellemrum)")
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { blink = true }
        }
    }
}

// MARK: - Detaljewaveform (zoom, grid, markører)

struct DetailWaveform: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack
    @Binding var zoom: Double
    let gridMode: Bool
    var showSuggestions: Bool = false
    @State private var dragStart: Double?
    @State private var wasPlaying = false
    @State private var gridShift: Double = 0
    @State private var zoomBase: Double?
    @State private var hover = false
    @Environment(\.displayScale) private var scale

    static let zoomSteps: [Double] = [2, 4, 8, 16, 32, 64]

    var firstBeat: Double { (track.firstBeatMs ?? 0) / 1000 + gridShift }

    var body: some View {
        GeometryReader { geo in
            let w: Double = Double(geo.size.width)
            ZStack(alignment: .topLeading) {
                // Tegnes i skærmens takt (60/120 Hz) med den præcise afspilningsposition – ingen hak når der er zoomet ind
                TimelineView(.animation(minimumInterval: nil, paused: !player.playing)) { _ in
                    Canvas { ctx, size in draw(ctx, size, pos: player.livePosition()) }
                }
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
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundColor(Color(red: 0.35, green: 0.6, blue: 1))
                    Text("Bars").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(red: 0.35, green: 0.6, blue: 1))
                    Text(pos.barsToPhrase == 8 && pos.beat == 1 ? "· ny frase" : "· frase om \(pos.barsToPhrase)")
                        .font(.system(size: 11)).monospacedDigit().foregroundColor(.mist.opacity(0.6))
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.65)))
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
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                let secsPerPx = zoom / max(1, width)
                if gridMode {
                    gridShift = Double(v.translation.width) * secsPerPx
                } else {
                    if dragStart == nil { dragStart = player.position }
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
                    dragStart = nil
                }
            }
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize, pos: Double) {
        let w = Double(size.width), h = Double(size.height)
        let bands = player.bands
        let secsPerPx = zoom / max(1, w)
        let t0 = pos - zoom / 2
        let mid = h / 2

        // 2) Waveformen som i rekordbox: toppe i høj opløsning, én skærm-pixel ad gangen, farven fra
        //    frekvensbåndene (bas rød, mellem grøn, diskant blå). Ingen udglatning – transienterne står skarpt.
        let peaks = player.peaks
        if bands.count >= 3 {
            let s = max(1, Double(scale))
            let px = 1 / s
            let n = Int(w * s)
            let halfH = h / 2 - 9
            let rate = MusicAnalyzer.waveformRate
            let prate = MusicAnalyzer.peakRate
            let pcount = peaks.count
            let levels = 16.0
            var paths = [Int: Path]()
            for i in 0..<n {
                let x = Double(i) * px
                let ta = t0 + x * secsPerPx
                let tb = ta + px * secsPerPx
                if tb <= 0 || ta >= player.duration { continue }
                // Højde: største top i pixlens tidsrum (eller nærmeste top, når der er zoomet langt ind)
                var amp = 0.0
                if pcount > 0 {
                    let a = max(0, Int(ta * prate))
                    let b = min(pcount, max(a + 1, Int(ceil(tb * prate))))
                    if a < pcount {
                        for k in a..<b { amp = max(amp, Double(peaks[k])) }
                    }
                } else {
                    let col = ta * rate
                    amp = max(WaveColor.sample(bands, at: col, band: 0),
                              max(WaveColor.sample(bands, at: col, band: 1), WaveColor.sample(bands, at: col, band: 2)))
                }
                if amp < 1 { continue }
                // Farven er gennemsnittet over ca. 50 ms (eller pixlens tidsrum), så den ikke flimrer i striber
                let tm = (ta + tb) / 2
                let half = max(0.012, (tb - ta) / 2)
                let ca = max(0, Int((tm - half) * rate)), cb = max(ca + 1, Int((tm + half) * rate) + 1)
                var lo = 0.0, mi = 0.0, hi = 0.0
                let bcols = bands.count / 3
                if ca < bcols {
                    let end = min(bcols, cb)
                    for c in ca..<end {
                        lo += Double(bands[c * 3]); mi += Double(bands[c * 3 + 1]); hi += Double(bands[c * 3 + 2])
                    }
                }
                guard let c = WaveColor.rgb(lo, mi, hi, floor: 0.1, boost: true) else { continue }
                // Farverne samles i spande, så hele waveformen tegnes med få fyld-kald
                let q = levels - 1
                let key = Int((c.r * q).rounded()) * 10000 + Int((c.g * q).rounded()) * 100 + Int((c.b * q).rounded())
                let bh = amp / 255 * halfH
                paths[key, default: Path()].addRect(CGRect(x: x, y: mid - bh, width: px, height: bh * 2))
            }
            for (key, path) in paths {
                let r = Double(key / 10000) / (levels - 1)
                let g = Double((key / 100) % 100) / (levels - 1)
                let b = Double(key % 100) / (levels - 1)
                ctx.fill(path, with: .color(Color(red: r, green: g, blue: b)))
            }
        } else {
            ctx.draw(Text(PlayerModel.shared.analyzingWave ? "Analyserer waveform …" : "Ingen waveform")
                        .font(.system(size: 12)).foregroundColor(.mist.opacity(0.5)),
                     at: CGPoint(x: w / 2, y: mid))
        }

        // Beatgrid som i rekordbox: grå slag-streger med små grå mærker øverst og nederst,
        // hvide takt-streger med røde trekanter. Fraser (hver 8. takt) får orange trekanter og taktnummer.
        if let bpm = track.bpm, bpm > 0 {
            let beat = 60 / bpm
            let fb = firstBeat
            var k = Int(floor((t0 - fb) / beat))
            let pxPerBeat = beat / secsPerPx
            let showBeats = pxPerBeat >= 22
            let showBars = pxPerBeat * 4 >= 12
            let line = 1 / max(1, Double(scale))
            let red = Color(red: 0.92, green: 0.18, blue: 0.15)
            func triangles(_ x: Double, _ color: Color) {
                var top = Path()
                top.move(to: CGPoint(x: x - 4.5, y: 0))
                top.addLine(to: CGPoint(x: x + 4.5, y: 0))
                top.addLine(to: CGPoint(x: x, y: 6))
                top.closeSubpath()
                var bottom = Path()
                bottom.move(to: CGPoint(x: x - 4.5, y: h))
                bottom.addLine(to: CGPoint(x: x + 4.5, y: h))
                bottom.addLine(to: CGPoint(x: x, y: h - 6))
                bottom.closeSubpath()
                ctx.fill(top, with: .color(color))
                ctx.fill(bottom, with: .color(color))
            }
            while true {
                let tb = fb + Double(k) * beat
                if tb > t0 + zoom { break }
                if tb >= 0 && tb <= player.duration {
                    let x = (tb - t0) / secsPerPx
                    let inBar = BeatGrid.mod(k, BeatGrid.beatsPerBar)
                    let inPhrase = BeatGrid.mod(k, BeatGrid.beatsPerBar * BeatGrid.barsPerPhrase)
                    if inBar == 0 && (showBars || inPhrase == 0) {
                        ctx.fill(Path(CGRect(x: x - line, y: 6, width: line * 2, height: h - 12)), with: .color(Color.white.opacity(0.9)))
                        triangles(x, inPhrase == 0 ? Color.ember : red)
                        if inPhrase == 0 {
                            let bar = Int(floor(Double(k) / Double(BeatGrid.beatsPerBar))) + 1
                            ctx.draw(Text("\(bar)").font(.system(size: 10, weight: .semibold)).foregroundColor(Color.ember),
                                     at: CGPoint(x: x + 4, y: h - 13), anchor: .leading)
                        }
                    } else if inBar != 0 && showBeats {
                        ctx.fill(Path(CGRect(x: x - line / 2, y: 6, width: line, height: h - 12)), with: .color(Color(white: 0.6).opacity(0.55)))
                        ctx.fill(Path(CGRect(x: x - 1.5, y: 0, width: 3, height: 4)), with: .color(Color(white: 0.6)))
                        ctx.fill(Path(CGRect(x: x - 1.5, y: h - 4, width: 3, height: 4)), with: .color(Color(white: 0.6)))
                    }
                }
                k += 1
            }
        }

        // 3) Memory cues: rød trekant øverst (som rekordbox)
        for cue in (track.cues ?? []) where cue >= t0 && cue <= t0 + zoom {
            let x = (cue - t0) / secsPerPx
            var tri = Path()
            tri.move(to: CGPoint(x: x - 5, y: 0))
            tri.addLine(to: CGPoint(x: x + 5, y: 0))
            tri.addLine(to: CGPoint(x: x, y: 8))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(Color(red: 0.9, green: 0.2, blue: 0.2)))
        }

        // Hot cues A–H: farvet streg med bogstav-mærke øverst (som rekordbox)
        for (letter, at) in (track.hotCues ?? [:]) where at >= t0 && at <= t0 + zoom {
            let x = (at - t0) / secsPerPx
            let c = HotCue.rgb[letter] ?? (1, 1, 1)
            let color = Color(red: c.0, green: c.1, blue: c.2)
            ctx.fill(Path(CGRect(x: x - 0.75, y: 14, width: 1.5, height: h - 14)), with: .color(color))
            // Mærket står midt over stregen, så det er tydeligt præcis hvilket slag cue'en ligger på
            let tag = Path(roundedRect: CGRect(x: x - 7.5, y: 0, width: 15, height: 15), cornerRadius: 3)
            ctx.fill(tag, with: .color(color))
            ctx.draw(Text(letter).font(.system(size: 11, weight: .heavy)).foregroundColor(.black),
                     at: CGPoint(x: x, y: 7.5), anchor: .center)
        }

        // EQ-områder: let tonet felt med "EQ"
        for r in (track.eqRegions ?? []) where r.end >= t0 && r.start <= t0 + zoom {
            let x0 = max(0, (r.start - t0) / secsPerPx), x1 = min(w, (r.end - t0) / secsPerPx)
            let editing: Bool = player.editingRegion == r.id
            ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: h)), with: .color(Color.ember.opacity(editing ? 0.16 : 0.08)))
            ctx.fill(Path(CGRect(x: x0, y: h - 3, width: x1 - x0, height: 3)), with: .color(Color.ember.opacity(editing ? 0.9 : 0.5)))
            ctx.draw(Text("EQ").font(.system(size: 9, weight: .bold)).foregroundColor(Color.ember), at: CGPoint(x: x0 + 4, y: h - 12), anchor: .leading)
        }

        // Forslag til hot cues (stiplede, kun i Cues-fanen og kun for tomme bogstaver)
        if showSuggestions {
            for (letter, at) in player.cueSuggestions where track.hotCues?[letter] == nil && at >= t0 && at <= t0 + zoom {
                let x = (at - t0) / secsPerPx
                let c = HotCue.rgb[letter] ?? (1, 1, 1)
                let color = Color(red: c.0, green: c.1, blue: c.2)
                var dash = Path()
                dash.move(to: CGPoint(x: x, y: 16))
                dash.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(dash, with: .color(color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                ctx.stroke(Path(roundedRect: CGRect(x: x - 7.5, y: 0.75, width: 15, height: 14), cornerRadius: 3),
                           with: .color(color), lineWidth: 1.5)
                ctx.draw(Text(letter).font(.system(size: 11, weight: .heavy)).foregroundColor(color),
                         at: CGPoint(x: x, y: 7.5), anchor: .center)
            }
        }

        // Cue-punktet (CUE-knappen): orange trekant nederst
        if player.cuePoint >= t0 && player.cuePoint <= t0 + zoom {
            let x = (player.cuePoint - t0) / secsPerPx
            var tri = Path()
            tri.move(to: CGPoint(x: x - 6, y: h))
            tri.addLine(to: CGPoint(x: x + 6, y: h))
            tri.addLine(to: CGPoint(x: x, y: h - 9))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(CDJButtons.cueOrange))
        }

        // 4) Afspilningshoved i midten
        ctx.fill(Path(CGRect(x: w / 2 - 0.75, y: 0, width: 1.5, height: h)), with: .color(.white))
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
                if let img = player.overviewImage(width: 2400, height: 80) {
                    // Fuld farve som den store waveform; det der er spillet, dæmpes (som rekordbox)
                    Image(decorative: img, scale: 1).resizable().interpolation(.high)
                    Rectangle().fill(Color.black.opacity(0.5))
                        .frame(width: max(0, w * frac))
                }
                if let zoom, hover {
                    // Holdes inden for waveformen – også i starten og slutningen af sangen
                    let zw: CGFloat = min(w, max(4, w * CGFloat(zoom / dur)))
                    let zx: CGFloat = min(max(0, w * frac - zw / 2), w - zw)
                    RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1)
                        .frame(width: zw)
                        .offset(x: zx)
                }
                // Memory cues: små røde trekanter nederst
                ForEach(Array((track.cues ?? []).enumerated()), id: \.offset) { item in
                    let x: CGFloat = w * CGFloat(item.element / dur)
                    Image(systemName: "triangle.fill").font(.system(size: 7))
                        .foregroundColor(Color(red: 0.9, green: 0.2, blue: 0.2))
                        .offset(x: x - 3.5, y: 11)
                }
                // Hot cues A–H: farvede bogstav-mærker øverst (som rekordbox' preview)
                ForEach(HotCue.letters.filter { track.hotCues?[$0] != nil }, id: \.self) { letter in
                    let at: Double = track.hotCues?[letter] ?? 0
                    let c = HotCue.rgb[letter] ?? (1, 1, 1)
                    Text(letter)
                        .font(.system(size: 9, weight: .heavy)).foregroundColor(.black)
                        .frame(width: 11, height: 11)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Color(red: c.0, green: c.1, blue: c.2)))
                        .offset(x: w * CGFloat(at / dur) - 5.5, y: -9)
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
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                player.seek(Double(max(0, min(1, v.location.x / max(1, w)))))
            })
        }
    }

    func timeText(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - Takt-lineal under overblikket (som rekordbox)

struct BarRuler: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var body: some View {
        Canvas { ctx, size in
            let w = Double(size.width), h = Double(size.height)
            let dur = max(0.001, player.duration)
            guard w > 10, let bpm = track.bpm, bpm > 0 else { return }
            let barSec = 60 / bpm * Double(BeatGrid.beatsPerBar)
            let fb = (track.firstBeatMs ?? 0) / 1000
            let totalBars = Int((dur - fb) / barSec) + 1
            guard totalBars > 0 else { return }
            let pxPerBar = w * barSec / dur
            // Tal med mindst ~36 px imellem: hver 8., 16., 32. … takt
            var labelEvery = 8
            while Double(labelEvery) * pxPerBar < 36 && labelEvery < 4096 { labelEvery *= 2 }
            let tickEvery = pxPerBar >= 5 ? 1 : (pxPerBar * 4 >= 5 ? 4 : 8)
            var bar = 0
            while bar < totalBars {
                let t = fb + Double(bar) * barSec
                let x = t / dur * w
                if bar % labelEvery == 0 {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: 6)), with: .color(Color.mist.opacity(0.6)))
                    ctx.draw(Text("\(bar + 1)").font(.system(size: 10)).monospacedDigit().foregroundColor(Color.mist.opacity(0.6)),
                             at: CGPoint(x: x + 2, y: h - 5), anchor: .leading)
                } else if bar % BeatGrid.barsPerPhrase == 0 {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: 4)), with: .color(Color.mist.opacity(0.4)))
                } else if bar % tickEvery == 0 {
                    ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: 2)), with: .color(Color.mist.opacity(0.25)))
                }
                bar += 1
            }
            // Hvor du er
            let px = player.position / dur * w
            ctx.fill(Path(CGRect(x: px - 0.5, y: 0, width: 1, height: h)), with: .color(Color.white.opacity(0.8)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sangens opbygning (intro, buildup, drop, breakdown, outro)

struct SectionStrip: View {
    @ObservedObject private var player = PlayerModel.shared

    var body: some View {
        let secs = player.sections
        let dur: Double = max(0.001, player.duration)
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                ForEach(Array(secs.enumerated()), id: \.offset) { item in
                    let s = item.element
                    let x0: CGFloat = w * CGFloat(max(0, s.start) / dur)
                    let x1: CGFloat = w * CGFloat(min(dur, s.end) / dur)
                    let c = s.kind.rgb
                    // Sektionen der spiller nu lyser op
                    let active: Bool = player.position >= s.start && player.position < s.end
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: c.0, green: c.1, blue: c.2).opacity(active ? 0.95 : 0.3))
                        if active {
                            RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.8), lineWidth: 1)
                        }
                        if x1 - x0 > 44 {
                            Text(s.ordinal > 1 && (s.kind == .drop || s.kind == .breakdown || s.kind == .buildup)
                                 ? "\(s.kind.title) \(s.ordinal)" : s.kind.title)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(active ? Color.black : Color(red: c.0, green: c.1, blue: c.2))
                                .lineLimit(1)
                                .padding(.leading, 4)
                        }
                    }
                    .frame(width: max(1, x1 - x0 - 1))
                    .offset(x: x0)
                    .help("\(s.kind.title) – takt \(s.startBar + 1)–\(s.endBar)")
                }
            }
        }
        .opacity(secs.isEmpty ? 0 : 1)
    }
}

// MARK: - Niveaumåler som på en DJM-mixer

/// To lodrette LED-søjler (L/R) med dB-skala +9 … −33, grøn/orange/rød og CLIP-lampe øverst.
/// 0 dB på måleren svarer til et normalt klubniveau (RMS ca. −9 dBFS), som på en mixer.
struct DJMMeter: View {
    @ObservedObject private var player = PlayerModel.shared
    static let steps: [Double] = [9, 6, 3, 0, -3, -6, -9, -12, -15, -18, -21, -24, -27, -30, -33]
    static let offset = 9.0            // dBFS (RMS) + 9 = mixerens dB

    static func color(_ db: Double) -> Color {
        if db >= 6 { return Color(red: 0.95, green: 0.2, blue: 0.16) }
        if db >= -3 { return Color(red: 0.98, green: 0.62, blue: 0.12) }
        return Color(red: 0.25, green: 0.85, blue: 0.3)
    }

    var body: some View {
        let l: Double = player.levelL + DJMMeter.offset
        let r: Double = player.levelR + DJMMeter.offset
        let hold: Double = player.holdDB + DJMMeter.offset
        VStack(spacing: 4) {
            Text("CLIP")
                .font(.system(size: 8, weight: .heavy))
                .foregroundColor(player.clipped ? .white : Color(red: 0.6, green: 0.15, blue: 0.12))
                .frame(width: 30, height: 12)
                .background(RoundedRectangle(cornerRadius: 2).fill(player.clipped ? Color(red: 0.95, green: 0.15, blue: 0.12) : Color(red: 0.25, green: 0.05, blue: 0.05)))
                .onTapGesture { player.resetClip() }
                .help("Lyser kun hvis sangen klipper (0 dBFS). Klik for at nulstille.")
            HStack(alignment: .top, spacing: 3) {
                column(level: l, hold: hold)
                VStack(spacing: 0) {
                    ForEach(DJMMeter.steps, id: \.self) { db in
                        Text(db > 0 ? "\(Int(db))" : "\(Int(db))")
                            .font(.system(size: 7, weight: .medium)).monospacedDigit()
                            .foregroundColor(.mist.opacity(0.55))
                            .frame(height: 9)
                    }
                }
                .frame(width: 16)
                column(level: r, hold: hold)
            }
            HStack(spacing: 14) {
                Text("L").font(.system(size: 8, weight: .bold)).foregroundColor(.mist.opacity(0.5))
                Text("R").font(.system(size: 8, weight: .bold)).foregroundColor(.mist.opacity(0.5))
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.45)))
        .help(String(format: "Niveau %.1f dB (mixer-skala) · top %.1f dBFS", max(l, r), player.peakDB))
    }

    func column(level: Double, hold: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(DJMMeter.steps, id: \.self) { db in
                let lit: Bool = level >= db
                let held: Bool = !lit && abs(hold - db) < 1.5 && hold > -40
                RoundedRectangle(cornerRadius: 1)
                    .fill(DJMMeter.color(db).opacity(lit ? 1 : (held ? 0.6 : 0.12)))
                    .frame(width: 9, height: 7)
                    .frame(height: 9)
            }
        }
    }
}

// MARK: - Niveaumåler (som rekordbox: to tynde vandrette bjælker, grøn → orange)

struct LevelMeter: View {
    @ObservedObject private var player = PlayerModel.shared
    // RMS-skala: et normalt klubmaster (−9 LUFS) ligger omkring −10 dBFS = grønt med orange spids
    static let minDB = -40.0
    static let maxDB = -2.0

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
                .init(color: Color(red: 0.25, green: 0.75, blue: 0.35), location: 0.68),
                .init(color: Color(red: 0.95, green: 0.62, blue: 0.2), location: 0.92),
                .init(color: Color(red: 1, green: 0.4, blue: 0.2), location: 1)
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
        .help(String(format: "Niveau (RMS) %.1f dBFS · højeste top %.1f dBFS. Rød kant = sangen klipper (klik for at nulstille).",
                     max(player.levelL, player.levelR), player.peakDB))
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

// MARK: - Cues: hot cues A–H og memory cues (som rekordbox' CUE/LOOP-panel)

struct CueTools: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var memory: [Double] { track.cues ?? [] }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(HotCue.letters, id: \.self) { letter in
                hotCueButton(letter)
            }
            Divider().frame(height: 26).padding(.horizontal, 4)
            Button("MEMORY") {
                LibraryStore.shared.addCue(track.id, at: player.quantized(player.position))
            }
            .buttonStyle(CueToolStyle())
            .help("Gem en memory cue ved afspilningshovedet (på nærmeste slag)")
            Button { if let c = memory.last(where: { $0 < player.position - 0.2 }) { player.seek(seconds: c) } } label: {
                Image(systemName: "arrowtriangle.left.fill")
            }
            .buttonStyle(CueToolStyle())
            .help("Forrige memory cue")
            Button { if let c = memory.first(where: { $0 > player.position + 0.2 }) { player.seek(seconds: c) } } label: {
                Image(systemName: "arrowtriangle.right.fill")
            }
            .buttonStyle(CueToolStyle())
            .help("Næste memory cue")
            Button { LibraryStore.shared.removeCue(track.id, near: player.position, tolerance: 4) } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(CueToolStyle())
            .disabled(memory.isEmpty)
            .help("Slet nærmeste memory cue")
            Spacer(minLength: 0)
            let open: Int = player.cueSuggestions.keys.filter { track.hotCues?[$0] == nil }.count
            Button {
                player.applySuggestions()
            } label: {
                Label(open > 0 ? "Sæt forslag (\(open))" : "Forslag sat", systemImage: "wand.and.stars")
            }
            .buttonStyle(.ember)
            .disabled(open == 0)
            .help("Sætter de stiplede forslag på de tomme hot cues – ud fra dine regler i Indstillinger → Cues, eller det appen har lært af dig")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    func hotCueButton(_ letter: String) -> some View {
        let set: Bool = track.hotCues?[letter] != nil
        let c = HotCue.rgb[letter] ?? (1, 1, 1)
        let color = Color(red: c.0, green: c.1, blue: c.2)
        return Button {
            let shift = NSEvent.modifierFlags.contains(.shift)
            player.hotCue(letter, delete: shift)
        } label: {
            // Tom = grå; sat = i sin farve (som rekordbox)
            Text(letter)
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(set ? .black : Color(white: 0.55))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 5).fill(set ? color : Color(white: 0.16)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.3).opacity(set ? 0 : 1), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(set ? "Hot cue \(letter): hop dertil · shift-klik sletter" : "Hot cue \(letter): sæt ved afspilningshovedet")
        .modMenu(title: "Hot cue \(letter)") {
            set ? [MMItem.action("Slet hot cue \(letter)", icon: "trash", destructive: true) { PlayerModel.shared.hotCue(letter, delete: true) }] : []
        }
    }
}

struct CueToolStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.mist.opacity(0.9))
            .frame(minWidth: 30, minHeight: 30)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

// MARK: - EQ med drejeknapper

/// Drejeknap som på en DJM: 0 dB peger lige op (kl. 12), helt til venstre = −26 dB (kill), helt til højre = +6 dB.
/// Træk op/ned (eller til siden) for at skrue, dobbeltklik for 0 dB.
struct Knob: View {
    let title: String
    @Binding var value: Double
    var minDB: Double = -26
    var maxDB: Double = 6
    @State private var startF: Double?

    /// dB → knappens stilling 0…1 (0,5 = 0 dB), to lineære halvdele som på en DJM
    func position(_ v: Double) -> Double {
        v < 0 ? 0.5 * (1 - v / minDB) : 0.5 + 0.5 * min(1, v / maxDB)
    }

    func dB(at f: Double) -> Double {
        let p = max(0, min(1, f))
        let v = p < 0.5 ? minDB * (1 - p / 0.5) : maxDB * (p - 0.5) / 0.5
        return (v * 2).rounded() / 2
    }

    var body: some View {
        let f: Double = position(value)
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(Color(white: 0.14))
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1)
                // Spor (270°) og bue fra kl. 12 (0 dB) til stillingen
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(-4)
                Circle()
                    .trim(from: min(0.5, f) * 0.75, to: max(0.5, f) * 0.75)
                    .stroke(value < -20 ? Color(red: 0.9, green: 0.25, blue: 0.2) : Color.ember,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .padding(-4)
                // Midtermærke kl. 12
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1.5, height: 4).offset(y: -27)
                // Viser
                Capsule()
                    .fill(Color.mist)
                    .frame(width: 2.5, height: 11)
                    .offset(y: -10)
                    .rotationEffect(.degrees((f - 0.5) * 270))
            }
            .frame(width: 40, height: 40)
            .padding(5)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if startF == nil { startF = f }
                    let delta = (Double(g.translation.width) - Double(g.translation.height)) / 160
                    value = dB(at: (startF ?? f) + delta)
                }
                .onEnded { _ in startF = nil })
            .onTapGesture(count: 2) { value = 0 }
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.mist.opacity(0.7))
            Text(value <= minDB + 0.01 ? "KILL" : String(format: "%+.1f dB", value))
                .font(.system(size: 11)).monospacedDigit().foregroundColor(.mist)
        }
        .help("Træk op/ned for at skrue. Dobbeltklik = 0 dB. Helt ned = kill.")
    }
}

struct EQPanel: View {
    @ObservedObject private var player = PlayerModel.shared
    let track: LibTrack

    var regions: [EQRegionData] { track.eqRegions ?? [] }
    var editing: EQRegionData? { regions.first { $0.id == player.editingRegion } }

    /// Knapperne styrer enten EQ for hele sangen eller det valgte område.
    func binding(_ band: WritableKeyPath<EQRegionData, Double>, base: WritableKeyPath<EQSettings, Double>) -> Binding<Double> {
        Binding(
            get: { editing.map { $0[keyPath: band] } ?? player.eq[keyPath: base] },
            set: { v in
                if let r = editing {
                    LibraryStore.shared.updateEQRegion(track.id, r.id) { $0[keyPath: band] = v }
                } else {
                    player.eq[keyPath: base] = v
                }
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            regionBar
            HStack(spacing: 18) {
                Knob(title: "Lows", value: binding(\.low, base: \.low))
                Knob(title: "Mids", value: binding(\.mid, base: \.mid))
                Knob(title: "High", value: binding(\.high, base: \.high))
                VStack(alignment: .leading, spacing: 6) {
                    Text(editing == nil ? "EQ for hele sangen – høres med det samme." :
                            "EQ kun i det valgte område (\(barText(editing!))) – høres når afspilningen er der.")
                        .font(.system(size: 11)).foregroundColor(.mist.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Nulstil") {
                            if let r = editing {
                                LibraryStore.shared.updateEQRegion(track.id, r.id) { $0.low = 0; $0.mid = 0; $0.high = 0 }
                            } else {
                                player.eq = EQSettings()
                            }
                        }
                        .buttonStyle(.ghost)
                        Button("Gem i filen…") { save() }
                            .buttonStyle(.ember)
                            .disabled(player.eq.isFlat && regions.isEmpty)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    var regionBar: some View {
        HStack(spacing: 6) {
            Button { player.editingRegion = nil } label: { Text("Hele sangen") }
                .buttonStyle(RegionChipStyle(active: editing == nil))
            ForEach(regions) { r in
                Button { player.editingRegion = r.id; player.seek(seconds: r.start) } label: { Text(barText(r)) }
                    .buttonStyle(RegionChipStyle(active: player.editingRegion == r.id))
                    .modMenu(title: "EQ-område \(barText(r))") {
                        [MMItem.action("Slet område", icon: "trash", destructive: true) {
                            if PlayerModel.shared.editingRegion == r.id { PlayerModel.shared.editingRegion = nil }
                            LibraryStore.shared.removeEQRegion(track.id, r.id)
                        }]
                    }
            }
            ModMenuButton(items: {
                var items = [MMItem]()
                if let s = player.sections.first(where: { $0.start <= player.position && player.position < $0.end }) {
                    items.append(.action("Denne sektion (\(s.kind.title))", icon: "rectangle.split.3x1") { addRegion(s.start, s.end) })
                }
                items.append(.action("Denne frase (8 takter)", icon: "music.note") { addPhrase() })
                items.append(.action("Fra her og 16 takter frem", icon: "arrow.right.to.line") { addBars(16) })
                return items
            }) {
                Label("Nyt område", systemImage: "plus").font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.mist).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }
            if let r = editing {
                Button("Start her") { LibraryStore.shared.updateEQRegion(track.id, r.id) { $0.start = player.quantized(player.position) } }
                    .buttonStyle(RegionChipStyle(active: false))
                Button("Slut her") { LibraryStore.shared.updateEQRegion(track.id, r.id) { $0.end = player.quantized(player.position) } }
                    .buttonStyle(RegionChipStyle(active: false))
            }
            Spacer(minLength: 0)
        }
    }

    func barText(_ r: EQRegionData) -> String {
        guard let bpm = track.bpm, bpm > 0 else { return String(format: "%d:%02d", Int(r.start) / 60, Int(r.start) % 60) }
        let fb = (track.firstBeatMs ?? 0) / 1000
        let a = BeatGrid.position(at: r.start + 0.01, bpm: bpm, firstBeat: fb).bar
        let b = BeatGrid.position(at: r.end - 0.01, bpm: bpm, firstBeat: fb).bar
        return "Takt \(a)–\(b)"
    }

    func addRegion(_ start: Double, _ end: Double) {
        let r = EQRegionData(start: start, end: end)
        LibraryStore.shared.addEQRegion(track.id, r)
        player.editingRegion = r.id
    }

    func addPhrase() {
        guard let bpm = track.bpm, bpm > 0 else { return addBars(8) }
        let phrase = 60 / bpm * 4 * Double(BeatGrid.barsPerPhrase)
        let fb = (track.firstBeatMs ?? 0) / 1000
        let start = fb + floor((player.position - fb) / phrase) * phrase
        addRegion(max(0, start), min(player.duration, start + phrase))
    }

    func addBars(_ n: Int) {
        let bar = 60 / max(1, track.bpm ?? 120) * 4
        let start = player.quantized(player.position)
        addRegion(start, min(player.duration, start + Double(n) * bar))
    }

    func save() {
        let eq = player.eq
        let regs = regions
        let wav: Bool = !["wav", "aif", "aiff"].contains(track.ext)
        var msg = eq.isFlat ? "" : "Hele sangen: \(eq.summary). "
        if !regs.isEmpty { msg += "\(regs.count) EQ-område\(regs.count == 1 ? "" : "r") lægges ind præcis på deres takter. " }
        msg += "Filen rettes bagefter til \(Int(LoudnessPrefs.target)) LUFS, så den ikke klipper."
            + (wav ? " \(track.codec) kan ikke skrives uden tab, så den gemmes som 24-bit WAV." : "")
            + " Originalen ligger i Musik/MODULR/Originaler."
        Dialogs.shared.confirm("Læg EQ'en ind i filen?", message: msg, icon: "slider.vertical.3", button: "Gem i filen") {
            LibraryStore.shared.applyEQ(track.id, eq: eq, regions: regs)
            player.eq = EQSettings()
            player.editingRegion = nil
        }
    }
}

struct RegionChipStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(active ? .void : .mist.opacity(0.85))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.ember : Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
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
                Text("Dynamik").frame(width: 96, alignment: .trailing)
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
            Text(dynamicsText(j)).frame(width: 96, alignment: .trailing)
            Text(lufsText(j)).frame(width: 110, alignment: .trailing)
            statusText(j).frame(width: 130, alignment: .leading).padding(.leading, 12)
        }
        .font(.system(size: 12)).monospacedDigit().foregroundColor(.mist.opacity(0.8))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .help(j.note)
    }

    func dynamicsText(_ j: LibraryStore.ProcessJob) -> String {
        if let e = j.expandedDB, e > 0.5 { return String(format: "Ekspansion +%.0f", e) }
        if let l = j.limitingDB, l > 0.1 { return String(format: "Limiter %.1f dB", l) }
        return j.status == .done ? "Ingen" : "–"
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
