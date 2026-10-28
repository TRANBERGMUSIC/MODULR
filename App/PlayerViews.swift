// MODULR – afspiller-panelet: detaljewaveform med zoom, beatgrid (takt/slag/fraser), markører,
// grid-redigering som i rekordbox, EQ med knapper og niveaumåler. Plus "Fiks tracks"-panelet.

import SwiftUI
import AppKit

enum PlayerMode: Hashable { case play, grid, eq, cues, bass }

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
                                    .revealWipe(trigger: t.id)
                                VStack(spacing: 2) {
                                    OverviewWaveform(track: t, zoom: zoom, suggestions: mode == .cues).frame(height: 38)
                                        .revealWipe(trigger: t.id)
                                    BarRuler(track: t).frame(height: 14)
                                    SectionStrip().frame(height: 14)
                                        .entrance(delay: 0.25, trigger: t.id)
                                }
                            }
                            DJMMeter()
                                .frame(width: 52, height: 182)
                        }
                        Group {
                            switch mode {
                            case .grid: GridEditBar(track: t)
                            case .eq: EQPanel(track: t)
                            case .cues: CueTools(track: t)
                            case .bass: LowEndPanel(track: t)
                            case .play: EmptyView()
                            }
                        }
                        .id(mode)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                        .animation(Motion.snappy, value: mode)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func header(_ t: LibTrack?) -> some View {
        HStack(spacing: 12) {
            // Signatur: coveret åbner, og titlen skubbes op, når en ny sang loades
            ZStack {
                Cover(track: t, size: 44, fallbackURL: player.externalArt)
                    .id(t?.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
            }
            .frame(width: 44, height: 44)
            // Træk et billede (screenshot, foto) på coveret → sangens artwork, tilpasset til kvadrat
            .dropDestination(for: URL.self) { urls, _ in
                guard let t, LibraryStore.shared.index.track(t.id) != nil else { return false }
                let rest = LibraryStore.shared.takeArtworkImages(urls, for: [t.id])
                return rest.count < urls.count
            }
            .help("Træk et billede herover for at bruge det som artwork")
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t?.title ?? "Dobbeltklik på en sang for at afspille den")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.mist).lineLimit(1)
                    Text(t.map { $0.artist.isEmpty ? "Ukendt kunstner" : $0.artist } ?? "Vælg en sang for at se waveform, grid, EQ og niveau")
                        .font(.system(size: 12)).foregroundColor(.mist.opacity(0.6)).lineLimit(1)
                }
                .id(t?.id)
                .transition(.asymmetric(insertion: .push(from: .bottom), removal: .opacity))
            }
            .clipped()
            .layoutPriority(1)
            Spacer(minLength: 8)
            if let t {
                if let k = t.key {
                    KeyPill(key: k)
                        .id(k)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                Text(t.bpmText).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundColor(.mist)
                    .contentTransition(.numericText(value: t.bpm ?? 0))
                    .fixedSize()
                if !compact {
                    UndoRedoButtons()
                    ModSegmented(selection: $mode, options: [(PlayerMode.play, "Afspil"), (PlayerMode.grid, "Grid"),
                                                             (PlayerMode.cues, "Cues"), (PlayerMode.eq, "EQ"),
                                                             (PlayerMode.bass, "Bas")])
                        .fixedSize()
                }
            }
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 12, weight: .bold)).foregroundColor(.mist.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(t == nil)
            .help("Forrige sang (eller starten af sangen)")
            CDJButtons()
                .disabled(t == nil)
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 12, weight: .bold)).foregroundColor(.mist.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(t == nil)
            .help("Næste sang")
        }
        .animation(Motion.reveal, value: t?.id)
        .animation(Motion.snappy, value: t?.bpm)
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
            .scaleEffect(cueDown ? 0.9 : 1)
            .animation(Motion.press, value: cueDown)
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
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
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
        // Din EQ ses i waveformen: et dræbt bånd forsvinder (farve og højde)
        let eqAt = player.eqVisual(track)
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
                        // Zoomet ind: højeste top (skarpe anslag). Zoomet ud: mest gennemsnit, så hvert kick
                        // ikke skyder op som en tynd streg helt til kanten (de lignede grid-streger)
                        var mx = 0.0, sum = 0.0
                        for k in a..<b { let v = Double(peaks[k]); mx = max(mx, v); sum += v }
                        let n = Double(b - a)
                        amp = n <= 2 ? mx : 0.3 * mx + 0.7 * (sum / n)
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
                if let eqAt {
                    let g = eqAt(tm)
                    let tot = lo + mi + hi
                    if tot > 0 { amp *= (lo * g.0 + mi * g.1 + hi * g.2) / tot }
                    lo *= g.0; mi *= g.1; hi *= g.2
                    if amp < 1 { continue }
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
            // Aldrig tættere end ca. 40 px: zoomet ind også slag; ellers hver takt, hver 2./4./8. takt
            let showBeats = pxPerBeat >= 22
            var barStep = 1
            while Double(barStep) * pxPerBeat * 4 < 40 && barStep < 8 { barStep *= 2 }
            let showBars = true
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
                    let barIndex = Int(floor(Double(k) / Double(BeatGrid.beatsPerBar)))
                    if inBar == 0 && showBars && (BeatGrid.mod(barIndex, barStep) == 0 || inPhrase == 0) {
                        ctx.fill(Path(CGRect(x: x - line, y: 6, width: line * 1.5, height: h - 12)), with: .color(Color.white.opacity(0.6)))
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
            for sug in player.cueSuggestions where sug.at >= t0 && sug.at <= t0 + zoom {
                let letter = sug.letter ?? "·"
                let x = (sug.at - t0) / secsPerPx
                let c = sug.letter.flatMap { HotCue.rgb[$0] } ?? (0.6, 0.6, 0.6)
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
    var suggestions: Bool = false
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
                // Forslag (kun i Cues-fanen): stiplede bogstaver, så du ser hele planen på én gang
                if suggestions {
                    ForEach(player.cueSuggestions) { sug in
                        let c = sug.letter.flatMap { HotCue.rgb[$0] } ?? (0.6, 0.6, 0.6)
                        let color = Color(red: c.0, green: c.1, blue: c.2)
                        let x: CGFloat = w * CGFloat(sug.at / dur)
                        Rectangle().fill(color.opacity(0.7)).frame(width: 1)
                            .offset(x: x - 0.5)
                        Text(sug.letter ?? "·")
                            .font(.system(size: 9, weight: .heavy)).foregroundColor(color)
                            .frame(width: 11, height: 11)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.75)))
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(color, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])))
                            .offset(x: x - 5.5, y: -9)
                    }
                    .transition(.opacity)
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
    @State private var hoverHandle: Int?
    @State private var dragging: Int?

    /// Grid-tal til at regne takter om til tid
    var grid: (bpm: Double, fb: Double, barSec: Double)? {
        guard let t = player.liveTrack, let bpm = t.bpm, bpm > 0 else { return nil }
        return (bpm, (t.firstBeatMs ?? 0) / 1000, 60 / bpm * 4)
    }

    var body: some View {
        let secs = player.sections
        let own = player.hasOwnSections
        let dur: Double = max(0.001, player.duration)
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                ForEach(Array(secs.enumerated()), id: \.offset) { item in
                    box(item.offset, item.element, secs: secs, w: w, dur: dur, own: own)
                }
                // Grænserne kan trækkes (hele takter) – så laver du dine egne sektioner
                ForEach(Array(secs.indices.dropFirst()), id: \.self) { i in
                    handle(i, secs: secs, w: w, dur: dur)
                }
            }
            .coordinateSpace(name: "sections")
        }
        .opacity(secs.isEmpty ? 0 : 1)
    }

    func box(_ i: Int, _ s: SongSection, secs: [SongSection], w: CGFloat, dur: Double, own: Bool) -> some View {
        let x0: CGFloat = w * CGFloat(max(0, s.start) / dur)
        let x1: CGFloat = w * CGFloat(min(dur, s.end) / dur)
        let c = s.kind.rgb
        let color = Color(red: c.0, green: c.1, blue: c.2)
        // Sektionen der spiller nu lyser op
        let active: Bool = player.position >= s.start && player.position < s.end
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(active ? 0.95 : 0.3))
            if active {
                RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.8), lineWidth: 1)
            }
            if x1 - x0 > 44 {
                Text(s.ordinal > 1 && (s.kind == .drop || s.kind == .breakdown || s.kind == .buildup)
                     ? "\(s.kind.title) \(s.ordinal)" : s.kind.title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(active ? Color.black : color)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
        .frame(width: max(1, x1 - x0 - 1))
        .contentShape(Rectangle())
        .onTapGesture {
            // Som en hot cue: hop til starten af sektionen (og afspil, hvis den står stille)
            player.seek(seconds: s.start)
            if !player.playing { player.play() }
        }
        .modMenu(title: "\(s.kind.title) · takt \(s.startBar + 1)–\(s.endBar)",
                 subtitle: own ? "Dine egne sektioner" : "Appens forslag – ret det, så bliver det dit") { menu(i, secs: secs) }
        .offset(x: x0)
        .help(helpText(s, own: own))
    }

    func helpText(_ s: SongSection, own: Bool) -> String {
        let base: String = "\(s.kind.title) – takt \(s.startBar + 1)–\(s.endBar). Klik for at hoppe dertil · træk i kanterne for at flytte · højreklik for at skifte type, dele eller slå sammen."
        return own ? base : base + "\nAppens forslag – indtil du retter det."
    }

    func handle(_ i: Int, secs: [SongSection], w: CGFloat, dur: Double) -> some View {
        let x: CGFloat = w * CGFloat(secs[i].start / dur)
        let lit = hoverHandle == i || dragging == i
        return Rectangle()
            .fill(Color.clear)
            .frame(width: 9)
            .overlay(Capsule().fill(Color.white.opacity(lit ? 0.95 : 0)).frame(width: 2))
            .contentShape(Rectangle())
            .offset(x: x - 4.5)
            .onHover { inside in
                if inside { hoverHandle = i; NSCursor.resizeLeftRight.push() } else {
                    if hoverHandle == i { hoverHandle = nil }
                    NSCursor.pop()
                }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("sections"))
                .onChanged { v in
                    guard let gr = grid, let t = player.liveTrack else { return }
                    dragging = i
                    let time = Double(v.location.x / max(1, w)) * dur
                    let bar = Int(((time - gr.fb) / gr.barSec).rounded())
                    let cur = player.sections
                    let new = SongStructure.moveBoundary(cur, index: i, toBar: bar, bpm: gr.bpm, firstBeat: gr.fb, duration: player.duration)
                    if new != cur || !player.hasOwnSections {
                        LibraryStore.shared.setSections(t.id, new, label: "Flyt sektionsgrænse")
                    }
                }
                .onEnded { _ in dragging = nil })
            .help("Træk for at flytte grænsen (hele takter)")
    }

    func menu(_ i: Int, secs: [SongSection]) -> [MMItem] {
        guard let gr = grid, let t = player.liveTrack else { return [] }
        let dur = player.duration
        let id = t.id
        func save(_ list: [SongSection], _ label: String) { LibraryStore.shared.setSections(id, list, label: label) }
        var items = [MMItem]()
        let kinds: [MMItem] = SectionKind.allCases.map { k in
            MMItem.action(k.title + (k == secs[i].kind ? "  ✓" : ""), icon: "rectangle.fill") {
                save(SongStructure.setKind(secs, index: i, k, bpm: gr.bpm, firstBeat: gr.fb, duration: dur), "Sektion → \(k.title)")
            }
        }
        items.append(.submenu("Skift til", icon: "tag", kinds))
        let playBar = Int(((player.position - gr.fb) / gr.barSec).rounded())
        if playBar > secs[i].startBar && playBar < secs[i].endBar {
            items.append(.action("Del ved afspilningshovedet (takt \(playBar + 1))", icon: "scissors") {
                save(SongStructure.split(secs, atBar: playBar, bpm: gr.bpm, firstBeat: gr.fb, duration: dur), "Del sektion")
            })
        } else {
            let mid = (secs[i].startBar + secs[i].endBar) / 2
            if mid > secs[i].startBar {
                items.append(.action("Del på midten (takt \(mid + 1))", icon: "scissors") {
                    save(SongStructure.split(secs, atBar: mid, bpm: gr.bpm, firstBeat: gr.fb, duration: dur), "Del sektion")
                })
            }
        }
        if i > 0 {
            items.append(.action("Slå sammen med forrige", icon: "arrow.left.to.line") {
                save(SongStructure.mergeWithNext(secs, index: i - 1, bpm: gr.bpm, firstBeat: gr.fb, duration: dur), "Slå sektioner sammen")
            })
        }
        if i + 1 < secs.count {
            items.append(.action("Slå sammen med næste", icon: "arrow.right.to.line") {
                save(SongStructure.mergeWithNext(secs, index: i, bpm: gr.bpm, firstBeat: gr.fb, duration: dur), "Slå sektioner sammen")
            })
        }
        if player.hasOwnSections {
            items.append(.divider)
            items.append(.action("Gendan appens forslag", icon: "wand.and.stars") {
                LibraryStore.shared.setSections(id, nil, label: "Gendan appens sektioner")
            })
        }
        return items
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
/// Grid-fortryd bruger nu det fælles forløb (⌘Z), så det også gælder cues, sektioner og EQ.
final class GridHistory {
    static let shared = GridHistory()
    func push(_ t: LibTrack) {}
    func canUndo(_ id: UUID) -> Bool { EditHistory.shared.canUndo }
    func canRedo(_ id: UUID) -> Bool { EditHistory.shared.canRedo }
    func undo(_ t: LibTrack) { EditHistory.shared.undo() }
    func redo(_ t: LibTrack) { EditHistory.shared.redo() }
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
                UndoRedoButtons()
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

    var suggestions: [CueSuggestion] { player.cueSuggestions }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            buttonsRow
            planRow
            suggestionRow
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
        .animation(Motion.snappy, value: suggestions.map(\.id))
    }

    // MARK: Planen – skriv selv hvilke dele der skal have hot cues

    var planRow: some View {
        let parsed = player.cuePlan
        return HStack(spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.mist.opacity(0.6))
            TextField("Fx: første slag, buildup, drop, breakdown, drop 2, outro", text: $player.cuePlanText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(parsed.unknown.isEmpty ? Color.white.opacity(0.08) : Color.orange.opacity(0.6), lineWidth: 1))
                .help("Skriv de dele du vil have hot cues på, adskilt med komma. Forstår: første slag, intro, groove, buildup, drop, breakdown, outro – med nummer (drop 2, andet drop), \"alle drops\", \"sidste breakdown\" og takter (+16, \"4 takter før drop\"). Bogstaverne A–H gives altid i tidsrækkefølge.")
            if !parsed.unknown.isEmpty {
                Text("Forstår ikke: \(parsed.unknown.joined(separator: ", "))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Menu {
                ForEach(addable) { item in
                    Button(item.title) { append(item.text) }
                }
                Divider()
                Button("Gendan standardplanen") { player.cuePlanText = CuePlan.standard }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            .help("Tilføj en del til planen")
            if !player.cueMoved.isEmpty || !player.cueDismissed.isEmpty {
                Button { player.resetSuggestions() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(CueToolStyle())
                .help("Fortryd dine flytninger og fjernede forslag i denne sang")
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    struct PlanItem: Identifiable {
        var title: String
        var text: String
        var id: String { title }
    }

    var addable: [PlanItem] {
        var out = [PlanItem(title: "Første slag", text: "første slag"), PlanItem(title: "16 takter inde", text: "første slag +16")]
        // De dele sangen faktisk har – så du kan se hvad der kan vælges
        for sec in player.sections {
            let many = player.sections.filter { $0.kind == sec.kind }.count > 1
            let title = many ? "\(sec.ordinal). \(sec.kind.title.lowercased())" : sec.kind.title
            let rule = CueRule(target: CueRule.Target(rawValue: sec.kind.rawValue) ?? .none, ordinal: sec.ordinal)
            out.append(PlanItem(title: title + " · takt \(sec.startBar + 1)", text: CuePlan.text(for: rule)))
        }
        out.append(PlanItem(title: "Alle drops", text: "alle drops"))
        out.append(PlanItem(title: "Sidste breakdown", text: "sidste breakdown"))
        return out
    }

    func append(_ text: String) {
        let cur = player.cuePlanText.trimmingCharacters(in: .whitespaces)
        player.cuePlanText = cur.isEmpty ? text : (cur.hasSuffix(",") ? cur + " " + text : cur + ", " + text)
    }

    // MARK: Forslagene – se dem, flyt dem, sæt dem

    @ViewBuilder
    var suggestionRow: some View {
        if suggestions.isEmpty {
            Text(emptyText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.mist.opacity(0.55))
                .frame(height: 44)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions) { sug in
                        SuggestionCard(sug: sug)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
        }
    }

    var emptyText: String {
        if player.sections.isEmpty { return "Ingen forslag endnu – sangen skal have BPM og være analyseret, før opbygningen kan findes" }
        if player.cuePlan.parts.isEmpty { return "Skriv hvilke dele du vil have hot cues på – eller klik + for at vælge" }
        if HotCue.letters.allSatisfy({ track.hotCues?[$0] != nil }) { return "Alle hot cues A–H er sat" }
        return "Delene i din plan findes ikke i sangen (eller er allerede sat)"
    }

    var buttonsRow: some View {
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
            let open: Int = suggestions.filter { $0.letter != nil }.count
            Button {
                player.applySuggestions()
            } label: {
                Label(open > 0 ? "Sæt alle forslag (\(open))" : "Ingen ledige forslag", systemImage: "wand.and.stars")
                    .contentTransition(.numericText(value: Double(open)))
            }
            .buttonStyle(.ember)
            .disabled(open == 0)
            .help("Sætter forslagene nedenfor på deres bogstaver – i tidsrækkefølge, og uden at røre de hot cues du selv har sat")
        }
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

/// Ét forslag: bogstav, del og takt. Klik = lyt dertil · ‹ › = flyt én takt (⇧ = 4 takter) · ✓ = sæt · × = fjern.
struct SuggestionCard: View {
    @ObservedObject private var player = PlayerModel.shared
    let sug: CueSuggestion
    @State private var hover = false

    var color: Color {
        guard let l = sug.letter, let c = HotCue.rgb[l] else { return Color(white: 0.5) }
        return Color(red: c.0, green: c.1, blue: c.2)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(sug.letter ?? "–")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(color)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35)))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
            VStack(alignment: .leading, spacing: 1) {
                Text(sug.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.mist)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("takt \(sug.bar) · \(clock(sug.at))")
                        .contentTransition(.numericText(value: Double(sug.bar)))
                    if sug.moved != 0 {
                        Text("\(sug.moved > 0 ? "+" : "−")\(abs(sug.moved))")
                            .foregroundColor(.ember)
                    } else if sug.learned != 0 {
                        Text("lært \(sug.learned > 0 ? "+" : "−")\(abs(sug.learned))")
                            .foregroundColor(.orange.opacity(0.8))
                            .help("Du plejer at flytte denne del \(abs(sug.learned)) takter \(sug.learned < 0 ? "tidligere" : "senere")")
                    }
                }
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundColor(.mist.opacity(0.55))
                if sug.letter == nil {
                    Text("Ingen plads i rækkefølgen")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange)
                }
            }
            .frame(minWidth: 84, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { player.seek(seconds: sug.at) }
            .help("Klik for at hoppe dertil og lytte")
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    iconButton("chevron.left", help: "Flyt én takt tidligere (⇧: 4 takter)") { move(-1) }
                    iconButton("chevron.right", help: "Flyt én takt senere (⇧: 4 takter)") { move(1) }
                }
                HStack(spacing: 2) {
                    iconButton("checkmark", help: "Sæt kun denne", tint: .ember) { player.applySuggestions(only: [sug.id]) }
                        .disabled(sug.letter == nil)
                    iconButton("xmark", help: "Fjern forslaget i denne sang") { player.dismissSuggestion(sug.id) }
                }
            }
        }
        .padding(.leading, 6).padding(.trailing, 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(hover ? 0.5 : 0.18), lineWidth: 1))
        .onHover { h in withAnimation(Motion.hover) { hover = h } }
        .modMenu(title: sug.title) {
            [MMItem.action("Flyt 8 takter tidligere", icon: "backward.end") { player.moveSuggestion(sug.id, bars: -8) },
             MMItem.action("Flyt 4 takter tidligere", icon: "chevron.left.2") { player.moveSuggestion(sug.id, bars: -4) },
             MMItem.action("Flyt 4 takter senere", icon: "chevron.right.2") { player.moveSuggestion(sug.id, bars: 4) },
             MMItem.action("Flyt 8 takter senere", icon: "forward.end") { player.moveSuggestion(sug.id, bars: 8) },
             MMItem.divider,
             MMItem.action("Sæt kun denne", icon: "checkmark", enabled: sug.letter != nil) { player.applySuggestions(only: [sug.id]) },
             MMItem.action("Fjern forslaget", icon: "xmark", destructive: true) { player.dismissSuggestion(sug.id) }]
        }
    }

    func move(_ bars: Int) {
        let n = NSEvent.modifierFlags.contains(.shift) ? bars * 4 : bars
        player.moveSuggestion(sug.id, bars: n)
        player.seek(seconds: max(0, sug.at + Double(n) * barSec))
    }

    var barSec: Double {
        guard let bpm = player.liveTrack?.bpm, bpm > 0 else { return 0 }
        return 60 / bpm * 4
    }

    func iconButton(_ icon: String, help: String, tint: Color = .mist, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(tint.opacity(0.9))
                .frame(width: 18, height: 16)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.press)
        .help(help)
    }

    func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
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
                band("Lows", "Bas og kick · under 220 Hz", binding(\.low, base: \.low))
                band("Mids", "Vokal og synth · 220 Hz–3 kHz", binding(\.mid, base: \.mid))
                band("High", "Hihats og luft · over 3 kHz", binding(\.high, base: \.high))
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

    @State private var beforeKill: [String: Double] = [:]

    /// Knap + KILL-knap: som en isolator på en DJ-mixer – båndet forsvinder næsten helt (som stems).
    func band(_ title: String, _ about: String, _ value: Binding<Double>) -> some View {
        let killed = value.wrappedValue <= -25.9
        return VStack(spacing: 4) {
            Knob(title: title, value: value)
            Button {
                if killed {
                    value.wrappedValue = beforeKill[title] ?? 0
                } else {
                    beforeKill[title] = value.wrappedValue
                    value.wrappedValue = -26
                }
            } label: {
                Text("KILL")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(killed ? .white : .mist.opacity(0.6))
                    .frame(width: 40, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(killed ? Color(red: 0.9, green: 0.22, blue: 0.18) : Color.white.opacity(0.07)))
            }
            .buttonStyle(.press)
            .help("\(title): \(about). Klik = fjern båndet helt (klik igen for at få det tilbage)")
        }
        .animation(Motion.snappy, value: killed)
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
