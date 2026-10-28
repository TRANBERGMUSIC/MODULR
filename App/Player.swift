// MODULR – afspilleren: AVAudioEngine med 3-bånds EQ (bas, mellem, diskant) og niveaumåler.
// Måleren sidder efter EQ'en og før lytte-volumen, så den viser sangens reelle niveau (dBFS):
// over −1 dBFS er det røde felt, ved 0 dBFS klipper filen.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI
import AppKit
import MediaPlayer

struct EQSettings: Codable, Equatable {
    var low: Double = 0      // dB, bas og kick under 220 Hz (−26 = kill … +6)
    var mid: Double = 0      // dB, 220 Hz–3 kHz (vokal, synth)
    var high: Double = 0     // dB, over 3 kHz (hihats, luft)

    var isFlat: Bool { abs(low) < 0.05 && abs(mid) < 0.05 && abs(high) < 0.05 }

    /// Som en DJM-mixer: lav-shelf 70 Hz, mellem-klokke 1 kHz, høj-shelf 13 kHz – −26 til +6 dB.
    func configure(_ unit: AVAudioUnitEQ) {
        let b = unit.bands
        guard b.count >= 3 else { return }
        b[0].filterType = .lowShelf
        b[0].frequency = 70
        b[0].gain = Float(low)
        b[1].filterType = .parametric
        b[1].frequency = 1000
        b[1].bandwidth = 2.0
        b[1].gain = Float(mid)
        b[2].filterType = .highShelf
        b[2].frequency = 13000
        b[2].gain = Float(high)
        for band in b { band.bypass = false }
        unit.bypass = false
        unit.globalGain = 0
    }

    /// Kun forstærkningen – filtertyper og frekvenser røres ikke (så skifter lyden ikke med et hak).
    static func setGains(_ unit: AVAudioUnitEQ, _ g: [Float]) {
        let b = unit.bands
        guard b.count >= 3, g.count >= 3 else { return }
        if b[0].gain != g[0] { b[0].gain = g[0] }
        if b[1].gain != g[1] { b[1].gain = g[1] }
        if b[2].gain != g[2] { b[2].gain = g[2] }
    }

    var gains: [Float] { [Float(low), Float(mid), Float(high)] }

    var summary: String {
        func f(_ v: Double) -> String { String(format: "%+.1f", v) }
        return "Lows \(f(low)) · Mids \(f(mid)) · High \(f(high)) dB"
    }
}

/// Lås-beskyttet opsamling fra lyd-tråden (tap'en) til skærmen.
final class MeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sumL: Double = 0
    private var sumR: Double = 0
    private var count: Double = 0
    private var peak: Float = 0
    private var clip = false

    /// rms² pr. kanal (vægtet med antal samples), største top, og om der var ægte klip.
    func add(msL: Float, msR: Float, frames: Int, peak p: Float, clipped: Bool) {
        lock.lock()
        sumL += Double(msL) * Double(frames)
        sumR += Double(msR) * Double(frames)
        count += Double(frames)
        peak = max(peak, p)
        if clipped { clip = true }
        lock.unlock()
    }

    func take() -> (rmsL: Float, rmsR: Float, peak: Float, clipped: Bool) {
        lock.lock()
        defer { sumL = 0; sumR = 0; count = 0; peak = 0; clip = false; lock.unlock() }
        guard count > 0 else { return (0, 0, peak, clip) }
        return (Float((sumL / count).squareRoot()), Float((sumR / count).squareRoot()), peak, clip)
    }
}

final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()

    @Published var track: LibTrack? {
        didSet {
            if NowPlayingKey.shared.id != track?.id { NowPlayingKey.shared.id = track?.id }
            // Ny sang: dine flytninger af forslagene hørte til den forrige
            if oldValue?.id != track?.id, !cueMoved.isEmpty || !cueDismissed.isEmpty {
                cueMoved = [:]
                cueDismissed = []
            }
        }
    }
    @Published var playing = false {
        didSet { if NowPlayingKey.shared.playing != playing { NowPlayingKey.shared.playing = playing } }
    }
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var bands: [UInt8] = []
    @Published private(set) var peaks: [UInt8] = []
    @Published private(set) var externalArt: URL?      // cover for sange uden for biblioteket (fx fra USB)
    @Published private(set) var analyzingWave = false
    private var externalOverview: CGImage?
    /// Listen der afspilles fra (sat af den viste tabel) – når en sang slutter, fortsætter den med den næste.
    var listQueue: [LibTrack] = []
    var listArt: [UUID: URL] = [:]
    @Published var advancedTo: UUID?

    /// Den viste liste tilbydes som kø – men en sang der spiller fra en anden liste, beholder sin kø.
    func offerQueue(_ items: [LibTrack], art: [UUID: URL]) {
        if playing, let cur = track, !items.contains(where: { $0.id == cur.id }) { return }
        listQueue = items
        listArt = art
    }

    // Niveau (dBFS) – efter EQ, før lytte-volumen
    @Published var levelL: Double = -80
    @Published var levelR: Double = -80
    @Published var holdDB: Double = -80
    @Published var clipped = false
    @Published var peakDB: Double = -80     // højeste top (til tooltip)

    @Published var eq = EQSettings() {
        didSet {
            appliedEQ = nil
            applyActiveEQ()
            // Kan fortrydes (men ikke når en ny sang nulstiller EQ'en)
            if !resettingEQ, oldValue != eq, let id = track?.id {
                EditHistory.shared.recordEQ(track: id, before: oldValue, after: eq)
            }
        }
    }
    private var resettingEQ = false
    @Published var volume: Double = 0.85 { didSet { engine.mainMixerNode.outputVolume = Float(volume) } }

    private let engine = AVAudioEngine()
    private var node = AVAudioPlayerNode()
    private var iso = IsolatorEQ()
    /// Formatet kæden sidst blev koblet med (samplerate + kanaler)
    private var connectedFormat: (rate: Double, channels: AVAudioChannelCount)?
    private var file: AVAudioFile?
    private var sampleRate: Double = 44100
    private var startFrame: AVAudioFramePosition = 0
    private var token = 0
    private var timer: Timer?
    private let meter = MeterBox()
    private var holdUntil = Date.distantPast
    private var tapInstalled = false

    private var keyMonitor: Any?
    private var keyUpMonitor: Any?

    init() {
        engine.attach(node)
        iso.attach(to: engine)
        engine.mainMixerNode.outputVolume = Float(volume)
        setupRemoteCommands()
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] e in
            if e.keyCode == 8, let self, self.cuePreviewing { self.cueUp(); return nil }
            return e
        }
        // Mellemrum = afspil/pause (men ikke når du skriver i et tekstfelt eller en dialog er åben)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 49 || e.keyCode == 8,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return e }
            if let r = NSApp.keyWindow?.firstResponder, r is NSText || r is NSTextView { return e }
            if Dialogs.shared.current != nil || self.track == nil { return e }
            if e.keyCode == 49 {
                self.playPause()
            } else if !e.isARepeat {
                self.cueDown()              // C = CUE (hold for preview)
            }
            return nil
        }
    }

    // MARK: Mediataster (afspil/pause, næste, forrige) og "Spiller nu" i macOS

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            guard let self, self.track != nil else { return .noActionableNowPlayingItem }
            DispatchQueue.main.async { self.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.track != nil else { return .noActionableNowPlayingItem }
            DispatchQueue.main.async { self.toggle() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let e = ev as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.seek(seconds: e.positionTime) }
            return .success
        }
    }

    func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = track else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        let artURL: URL? = LibraryStore.shared.artURL(t) ?? externalArt
        if let u = artURL, let img = NSImage(contentsOf: u) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
    }

    /// Næste sang i listen.
    func next() {
        guard let cur = track, let i = listQueue.firstIndex(where: { $0.id == cur.id }), i + 1 < listQueue.count else { return }
        let n = listQueue[i + 1]
        load(LibraryStore.shared.index.track(n.id) ?? n, autoplay: true, art: listArt[n.id])
        advancedTo = n.id
    }

    /// Forrige sang – eller starten af sangen, hvis der er spillet mere end 3 sekunder.
    func previous() {
        if position > 3 || track == nil {
            seek(seconds: 0)
            return
        }
        guard let cur = track, let i = listQueue.firstIndex(where: { $0.id == cur.id }), i > 0 else {
            seek(seconds: 0)
            return
        }
        let p = listQueue[i - 1]
        load(LibraryStore.shared.index.track(p.id) ?? p, autoplay: true, art: listArt[p.id])
        advancedTo = p.id
    }

    /// Sangen som den ser ud i biblioteket lige nu (grid og BPM kan være rettet siden den blev indlæst).
    var liveTrack: LibTrack? {
        guard let id = track?.id else { return nil }
        return LibraryStore.shared.index.track(id) ?? track
    }

    func load(_ t: LibTrack, autoplay: Bool = true, art: URL? = nil) {
        stopNode()
        stopTimer()
        playing = false
        track = t
        NowPlayingKey.shared.key = t.key
        externalArt = art
        externalOverview = nil
        bands = LibraryStore.shared.bands(t)
        peaks = LibraryStore.shared.peaks(t)
        if bands.isEmpty || peaks.isEmpty { analyzeWave(t) }
        resettingEQ = true
        eq = EQSettings()
        resettingEQ = false
        clipped = false
        holdDB = -80
        startFrame = 0
        position = 0
        cuePreviewing = false
        cuePoint = autoCue(for: t)
        guard let f = try? AVAudioFile(forReading: t.url) else {
            file = nil
            duration = t.duration ?? 0
            return
        }
        file = f
        sampleRate = f.processingFormat.sampleRate
        duration = Double(f.length) / sampleRate
        connect(format: f.processingFormat)
        if autoplay { play() } else if cuePoint > 0 { seek(seconds: cuePoint) }
    }

    /// Sange uden waveform (fx direkte fra USB): analysér i baggrunden, så de også får waveform.
    private func analyzeWave(_ t: LibTrack) {
        analyzingWave = true
        let url = t.url
        let id = t.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = try? MusicAnalyzer.analyze(url: url)
            DispatchQueue.main.async {
                guard let self, self.track?.id == id else { return }
                self.analyzingWave = false
                guard let r = result else { return }
                self.bands = r.bands
                self.peaks = r.peaks
                if !self.playing, let t = self.track { self.cuePoint = self.autoCue(for: t) }
                self.externalOverview = WaveShape.preview(bands: r.bands, peaks: r.peaks, width: 2400, height: 80)
                if (self.track?.bpm ?? 0) <= 0 || LibraryStore.shared.index.track(id) == nil {
                    self.track?.bpm = (self.track?.bpm ?? 0) > 0 ? self.track?.bpm : r.bpm
                    self.track?.firstBeatMs = r.firstBeatMs
                }
            }
        }
    }

    /// Overbliks-billedet: fra biblioteket, eller beregnet for en sang udefra.
    func overviewImage(width: Int, height: Int) -> CGImage? {
        guard let t = track else { return nil }
        if LibraryStore.shared.index.track(t.id) != nil {
            return WaveformCache.shared.image(for: t, width: width, height: height, store: LibraryStore.shared)
        }
        return externalOverview
    }

    /// Opdaterer waveform-data (efter ny analyse).
    func refreshBands() {
        if let t = liveTrack {
            bands = LibraryStore.shared.bands(t)
            peaks = LibraryStore.shared.peaks(t)
        }
    }

    private func connect(format: AVAudioFormat) {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            iso.output.removeTap(onBus: 0)
            tapInstalled = false
        }
        // Ny samplerate eller nyt antal kanaler (fx 44,1 → 48 kHz): helt nye enheder i stedet for at koble om.
        // At koble de gamle om kan få AVAudioEngine til at gå ned, fordi EQ'ens ind- og udgang kortvarigt
        // har forskellig samplerate (det var crashet, når man skiftede mellem sange).
        let same = connectedFormat.map { $0.rate == format.sampleRate && $0.channels == format.channelCount } ?? false
        if !same {
            engine.detach(node)
            iso.detach(from: engine)
            node = AVAudioPlayerNode()
            iso = IsolatorEQ()
            engine.attach(node)
            iso.attach(to: engine)
        } else {
            engine.disconnectNodeOutput(node)
            iso.disconnect(in: engine)
        }
        // Bagfra: EQ → mixer først, så afspiller → EQ – så EQ'ens ender aldrig er uenige om formatet
        iso.connect(in: engine, from: node, to: engine.mainMixerNode, format: format)
        connectedFormat = (format.sampleRate, format.channelCount)
        appliedEQ = nil            // tving EQ'en ud på den (evt. nye) enhed
        applyActiveEQ()
        let box = meter
        iso.output.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            guard let d = buf.floatChannelData else { return }
            let frames = Int(buf.frameLength)
            let n = vDSP_Length(frames)
            let chans = min(2, Int(buf.format.channelCount))
            var ms: [Float] = [0, 0]
            var peak: Float = 0
            var clipped = false
            for c in 0..<chans {
                vDSP_measqv(d[c], 1, &ms[c], n)
                var p: Float = 0
                vDSP_maxmgv(d[c], 1, &p, n)
                peak = max(peak, p)
                // Ægte klip: mindst 3 samples i træk på/over 0 dBFS (ikke en enkelt top der rører loftet)
                if p >= 0.999 {
                    var run = 0
                    for i in 0..<frames {
                        if abs(d[c][i]) >= 0.999 { run += 1; if run >= 3 { clipped = true; break } } else { run = 0 }
                    }
                }
            }
            if chans == 1 { ms[1] = ms[0] }
            box.add(msL: ms[0], msR: ms[1], frames: frames, peak: peak, clipped: clipped)
        }
        tapInstalled = true
        engine.prepare()
    }

    func play() {
        guard let f = file else { return }
        if startFrame >= f.length { startFrame = 0 }
        // Værn: er afspilleren af en eller anden grund ikke koblet til, kobles den igen (ellers kaster play() en fejl,
        // som macOS sluger – og så reagerer vinduet ikke på klik)
        if engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty {
            connectedFormat = nil
            connect(format: f.processingFormat)
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        guard !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else { return }
        schedule(from: startFrame)
        node.play()
        playing = true
        startTimer()
        updateNowPlaying()
    }

    func pause() {
        guard playing else { return }
        startFrame = frame(for: currentTime())
        position = Double(startFrame) / sampleRate
        stopNode()
        playing = false
        updateNowPlaying()
    }

    func toggle() { playing ? pause() : play() }

    // MARK: CUE og PLAY som på en CDJ (rekordbox' CDJ-mode)

    /// Cue-punktet (ikke en del af A–H). Sættes automatisk på første slag, når en sang indlæses.
    @Published var cuePoint: Double = 0
    @Published private(set) var cuePreviewing = false
    var atCue: Bool { abs(position - cuePoint) < 0.02 }

    /// CDJ'ens "auto cue": det første slag hvor musikken faktisk starter (stilhed i starten springes over).
    func autoCue(for t: LibTrack) -> Double { Self.autoCue(for: t, peaks: peaks) }

    static func autoCue(for t: LibTrack, peaks: [UInt8]) -> Double {
        // Hvor starter lyden? (første top over ca. −26 dB i forhold til sangens højeste)
        var start = 0.0
        if let i = peaks.firstIndex(where: { $0 > 12 }) { start = Double(i) / MusicAnalyzer.peakRate }
        guard let bpm = t.bpm, bpm > 0 else { return start }
        let beat = 60 / bpm
        let fb = (t.firstBeatMs ?? 0) / 1000
        // Nærmeste slag på griddet ved lydens start (højst et halvt slag før)
        let k = ((start - fb) / beat).rounded()
        var cue = fb + k * beat
        if cue < start - beat / 2 { cue += beat }
        return max(0, cue)
    }

    // MARK: Sangens opbygning og cue-forslag

    private var sectionCache: (key: String, value: [SongSection])?

    /// Intro/buildup/drop/breakdown/outro for sangen der er indlæst.
    var sections: [SongSection] {
        if let t = liveTrack, let own = t.sections, !own.isEmpty {
            // Dine egne sektioner ligger i takter – tiderne regnes fra det aktuelle grid (hvis du retter det bagefter)
            guard let bpm = t.bpm, bpm > 0 else { return own }
            return SongStructure.normalize(own, bpm: bpm, firstBeat: (t.firstBeatMs ?? 0) / 1000, duration: duration)
        }
        return autoSections
    }

    /// Har du selv rettet sektionerne på denne sang?
    var hasOwnSections: Bool { !(liveTrack?.sections ?? []).isEmpty }

    /// Appens eget forslag (bruges indtil du selv har rettet).
    var autoSections: [SongSection] {
        guard let t = liveTrack, let bpm = t.bpm, bpm > 0, !bands.isEmpty else { return [] }
        let key = "\(t.id)-\(bpm)-\(t.firstBeatMs ?? 0)-\(bands.count)"
        if let c = sectionCache, c.key == key { return c.value }
        let v = SongStructure.analyze(bands: bands, bpm: bpm, firstBeat: (t.firstBeatMs ?? 0) / 1000, duration: duration)
        sectionCache = (key, v)
        return v
    }

    /// Planen du har skrevet ("første slag, buildup, drop …") – gemmes.
    @Published var cuePlanText: String = CueRules.planText {
        didSet { CueRules.planText = cuePlanText }
    }
    /// Takter du har flyttet hvert forslag i denne sang, og forslag du har fjernet.
    @Published var cueMoved: [String: Int] = [:]
    @Published var cueDismissed: Set<String> = []

    private var planCache: (text: String, parts: [CueRule], unknown: [String])?

    /// Planen som dele (læses kun igen når teksten ændres – waveformen tegnes mange gange i sekundet).
    var cuePlan: (parts: [CueRule], unknown: [String]) {
        if let c = planCache, c.text == cuePlanText { return (c.parts, c.unknown) }
        let p = CuePlan.parse(cuePlanText)
        planCache = (cuePlanText, p.parts, p.unknown)
        return p
    }

    /// Forslag til hot cues A–H: delene fra din plan, i tidsrækkefølge.
    var cueSuggestions: [CueSuggestion] {
        guard let t = liveTrack, let bpm = t.bpm, bpm > 0 else { return [] }
        return CueRules.suggestions(plan: cuePlan.parts, sections: sections, bpm: bpm, firstBeat: autoCue(for: t),
                                    gridStart: (t.firstBeatMs ?? 0) / 1000, duration: duration,
                                    existing: t.hotCues ?? [:], moved: cueMoved, dismissed: cueDismissed)
    }

    /// Flyt et forslag et antal takter (før du sætter det).
    func moveSuggestion(_ id: String, bars: Int) {
        cueMoved[id, default: 0] += bars
    }

    func dismissSuggestion(_ id: String) {
        cueDismissed.insert(id)
    }

    func resetSuggestions() {
        cueMoved = [:]
        cueDismissed = []
    }

    /// Sætter forslagene (alle, eller kun de valgte) på deres bogstaver. Dine egne cues overskrives aldrig.
    /// Hvis du flyttede et forslag, husker appen det – flytter du fx altid droppet 4 takter tidligere, gør den det selv.
    func applySuggestions(only ids: Set<String>? = nil) {
        guard let t = liveTrack else { return }
        var n = 0
        var set = [String: Double]()
        for s in cueSuggestions {
            guard let letter = s.letter, t.hotCues?[letter] == nil else { continue }
            if let ids, !ids.contains(s.id) { continue }
            set[letter] = s.at
            if s.target.section != nil, s.moved != 0 || s.learned != 0 {
                CueRules.learnOffset(s.target, bars: s.learned + s.moved)
            }
            n += 1
        }
        LibraryStore.shared.setHotCues(t.id, set, label: n == 1 ? "Sæt cue-forslag" : "Sæt \(n) cue-forslag")
        LibraryStore.shared.lastMessage = n > 0 ? "\(n) hot cue\(n == 1 ? "" : "s") sat i rækkefølge" : "Ingen ledige forslag"
    }

    // MARK: EQ-områder (live)

    @Published var editingRegion: UUID?
    private var appliedEQ: EQSettings?
    private var currentGains: [Float] = [0, 0, 0]
    private var targetGains: [Float] = [0, 0, 0]

    /// EQ for det sted der spilles lige nu: et EQ-område hvis vi er i et, ellers EQ for hele sangen.
    /// Under afspilning glider knapperne blødt over (ca. 0,1 s) i stedet for at hoppe.
    func applyActiveEQ() {
        let regions = liveTrack?.eqRegions ?? []
        let active: EQSettings = regions.first(where: { $0.contains(position) })
            .map { EQSettings(low: $0.low, mid: $0.mid, high: $0.high) } ?? eq
        if active != appliedEQ {
            appliedEQ = active
            targetGains = active.gains
            targetWet = active.isFlat ? 0 : 1
            if !playing {
                currentGains = targetGains
                currentWet = targetWet
                iso.apply(gains: currentGains, wet: currentWet)
            }
        }
        smoothEQ()
    }

    private var currentWet: Float = 0
    private var targetWet: Float = 0

    private func smoothEQ() {
        guard currentGains != targetGains || currentWet != targetWet else { return }
        for i in 0..<3 {
            let d = targetGains[i] - currentGains[i]
            currentGains[i] = abs(d) < 0.05 ? targetGains[i] : currentGains[i] + d * 0.45
        }
        let dw = targetWet - currentWet
        currentWet = abs(dw) < 0.02 ? targetWet : currentWet + dw * 0.45
        iso.apply(gains: currentGains, wet: currentWet)
    }

    /// Nærmeste slag (quantize, som Q på en CDJ).
    func quantized(_ t: Double) -> Double {
        guard let tr = liveTrack, let bpm = tr.bpm, bpm > 0 else { return t }
        let beat = 60 / bpm
        let fb = (tr.firstBeatMs ?? 0) / 1000
        return max(0, fb + ((t - fb) / beat).rounded() * beat)
    }

    /// CUE trykkes ned (som på en CDJ):
    /// spiller → tilbage til cue-punktet; stoppet et andet sted → nyt cue-punkt her (på nærmeste slag).
    /// Så længe knappen holdes, spiller den fra cue-punktet – slip, og den hopper tilbage og stopper.
    func cueDown() {
        guard track != nil, !cuePreviewing else { return }
        if playing {
            pause()
        } else if !atCue {
            cuePoint = quantized(position)
        }
        seek(seconds: cuePoint)
        cuePreviewing = true
        play()
    }

    /// CUE slippes: under preview → tilbage til cue-punktet og stop.
    func cueUp() {
        guard cuePreviewing else { return }
        cuePreviewing = false
        pause()
        seek(seconds: cuePoint)
    }

    /// PLAY/PAUSE: under cue-preview fortsætter afspilningen (som at trykke PLAY mens CUE holdes).
    func playPause() {
        if cuePreviewing {
            cuePreviewing = false
            return
        }
        toggle()
    }

    /// Hot cue A–H: tom → sæt her (på nærmeste slag); sat → hop dertil (og afspil, hvis stoppet).
    func hotCue(_ letter: String, delete: Bool = false) {
        guard let t = liveTrack else { return }
        let existing = t.hotCues?[letter]
        if delete {
            LibraryStore.shared.setHotCue(t.id, letter, at: nil)
            return
        }
        if let at = existing {
            seek(seconds: at)
            if !playing { play() }
        } else {
            let at = quantized(position)
            LibraryStore.shared.setHotCue(t.id, letter, at: at)
            // Lær hvordan du sætter cues: ligger den lidt før/efter en sektionsstart, noteres forskydningen
            if let bpm = t.bpm, bpm > 0,
               let rule = CueRules.describe(at, sections: sections, bpm: bpm, firstBeat: autoCue(for: t)),
               rule.target.section != nil, abs(rule.offsetBars) <= 4 {
                CueRules.learnOffset(rule.target, bars: rule.offsetBars)
            }
        }
    }

    func seek(_ fraction: Double) { seek(seconds: fraction * duration) }

    func seek(seconds: Double) {
        guard file != nil else { return }
        let s = max(0, min(duration, seconds))
        startFrame = frame(for: s)
        position = s
        if playing {
            if !engine.isRunning {
                do { try engine.start() } catch { playing = false; return }
            }
            guard !engine.outputConnectionPoints(for: node, outputBus: 0).isEmpty else { playing = false; return }
            schedule(from: startFrame)
            node.play()
        }
        updateNowPlaying()
    }

    func stop() {
        stopNode()
        stopTimer()
        playing = false
    }

    /// Slip filer på et USB-stik (så det kan skubbes ud).
    func release(under root: URL) {
        let base = root.standardizedFileURL.path + "/"
        guard let t = track, t.path.hasPrefix(base) else { return }
        stop()
        file = nil
        track = nil
        listQueue.removeAll { $0.path.hasPrefix(base) }
        updateNowPlaying()
    }

    func resetClip() {
        clipped = false
        holdDB = -80
    }

    // MARK: Internt

    private func frame(for seconds: Double) -> AVAudioFramePosition {
        guard let f = file else { return 0 }
        return max(0, min(f.length, AVAudioFramePosition(seconds * sampleRate)))
    }

    private func stopNode() {
        token += 1
        node.stop()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        stopNode()
        let remaining = f.length - frame
        guard remaining > 0 else { return }
        let my = token
        node.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.token == my else { return }
                self.finished()
            }
        }
    }

    private func finished() {
        playing = false
        startFrame = 0
        position = duration
        // Videre til næste sang i listen
        guard let cur = track, let i = listQueue.firstIndex(where: { $0.id == cur.id }), i + 1 < listQueue.count else { return }
        let next = listQueue[i + 1]
        load(LibraryStore.shared.index.track(next.id) ?? next, autoplay: true, art: listArt[next.id])
        advancedTo = next.id
    }

    /// Den præcise position lige nu (til tegning i skærmens takt), ikke kun den der opdateres 30 gange i sekundet.
    func livePosition() -> Double { playing ? currentTime() : position }

    private func currentTime() -> Double {
        guard playing, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else {
            return Double(startFrame) / sampleRate
        }
        return min(duration, Double(startFrame + pt.sampleTime) / pt.sampleRate)
    }

    private func startTimer() {
        timer?.invalidate()
        // .common: timeren kører også mens en museknap holdes nede (CUE, scrub, knapper) – ellers står waveformen stille
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if playing { position = currentTime() }
        applyActiveEQ()
        let m = meter.take()
        func db(_ v: Float) -> Double { v > 0 ? 20 * log10(Double(v)) : -80 }
        // Måleren viser lydniveauet (RMS, som rekordbox' kanal-målere), ikke enkelte toppe
        let dl = playing ? db(m.rmsL) : -80
        let dr = playing ? db(m.rmsR) : -80
        levelL = dl > levelL ? dl : max(dl, levelL - 0.6)
        levelR = dr > levelR ? dr : max(dr, levelR - 0.6)
        let lvl = max(levelL, levelR)
        if lvl >= holdDB || Date() > holdUntil {
            if lvl >= holdDB { holdUntil = Date().addingTimeInterval(1.5) }
            holdDB = lvl >= holdDB ? lvl : max(lvl, holdDB - 0.4)
        }
        if playing { peakDB = max(db(m.peak), peakDB - 0.3) } else { peakDB = -80 }
        if m.clipped { clipped = true }
        if !playing && levelL <= -79 && levelR <= -79 { stopTimer() }
    }
}

// MARK: - EQ i filen (offline med samme EQ som afspilleren)

enum EQRender {
    /// EQ for hele sangen plus EQ-områder: områdernes EQ skiftes præcist ved deres start og slut.
    static func render(url: URL, eq: EQSettings, regions: [EQRegionData] = []) throws -> ([[Float]], Double) {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        // Samme isolator som afspilleren – det du hører, er det der gemmes
        let iso = IsolatorEQ()
        engine.attach(node)
        iso.attach(to: engine)
        iso.connect(in: engine, from: node, to: engine.mainMixerNode, format: fmt)
        iso.apply(gains: eq.gains, wet: eq.isFlat ? 0 : 1)
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        try engine.start()
        node.scheduleFile(file, at: nil)
        node.play()
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw LoudnessError.failed("Kunne ikke lave lydbuffer")
        }
        let chans = min(2, Int(engine.manualRenderingFormat.channelCount))
        var out = [[Float]](repeating: [], count: chans)
        for c in 0..<chans { out[c].reserveCapacity(Int(file.length)) }
        var stalls = 0
        let sr = fmt.sampleRate
        var bounds = [AVAudioFramePosition]()
        for r in regions { bounds.append(AVAudioFramePosition(r.start * sr)); bounds.append(AVAudioFramePosition(r.end * sr)) }
        bounds.sort()
        var applied: EQSettings? = nil
        while engine.manualRenderingSampleTime < file.length {
            let now = engine.manualRenderingSampleTime
            // EQ for det sted vi er nået til
            let t = Double(now) / sr
            let active: EQSettings = regions.first(where: { $0.contains(t) }).map { EQSettings(low: $0.low, mid: $0.mid, high: $0.high) } ?? eq
            if active != applied {
                iso.apply(gains: active.gains, wet: active.isFlat ? 0 : 1)
                applied = active
            }
            var left = file.length - now
            if let next = bounds.first(where: { $0 > now }) { left = min(left, next - now) }
            let frames = AVAudioFrameCount(max(1, min(Int64(maxFrames), left)))
            let status = try engine.renderOffline(frames, to: buf)
            switch status {
            case .success:
                stalls = 0
                guard let d = buf.floatChannelData else { break }
                let n = Int(buf.frameLength)
                for c in 0..<chans { out[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: n)) }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                stalls += 1
                if stalls > 100 { throw LoudnessError.failed("EQ-beregningen gik i stå") }
            case .error:
                throw LoudnessError.failed("EQ-beregningen fejlede")
            @unknown default:
                throw LoudnessError.failed("EQ-beregningen fejlede")
            }
        }
        node.stop()
        engine.stop()
        return (out, fmt.sampleRate)
    }
}


/// Tonearten der spiller lige nu – kun den, så tabellen ikke tegnes om 30 gange i sekundet.
/// Det tabellerne lytter på (ændrer sig kun ved ny sang / afspil-pause – ikke 60 gange i sekundet).
final class NowPlayingKey: ObservableObject {
    static let shared = NowPlayingKey()
    @Published var key: MusicalKey?
    @Published var id: UUID?
    @Published var playing = false
}
