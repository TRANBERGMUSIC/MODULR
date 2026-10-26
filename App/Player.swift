// MODULR – afspilleren: AVAudioEngine med 3-bånds EQ (bas, mellem, diskant) og niveaumåler.
// Måleren sidder efter EQ'en og før lytte-volumen, så den viser sangens reelle niveau (dBFS):
// over −1 dBFS er det røde felt, ved 0 dBFS klipper filen.

import Foundation
import AVFoundation
import Accelerate
import SwiftUI

struct EQSettings: Codable, Equatable {
    var low: Double = 0      // dB, lav shelf 100 Hz
    var mid: Double = 0      // dB, klokke 1 kHz (1,5 oktav)
    var high: Double = 0     // dB, høj shelf 8 kHz

    var isFlat: Bool { abs(low) < 0.05 && abs(mid) < 0.05 && abs(high) < 0.05 }

    func configure(_ unit: AVAudioUnitEQ) {
        let b = unit.bands
        guard b.count >= 3 else { return }
        b[0].filterType = .lowShelf
        b[0].frequency = 100
        b[0].gain = Float(low)
        b[1].filterType = .parametric
        b[1].frequency = 1000
        b[1].bandwidth = 1.5
        b[1].gain = Float(mid)
        b[2].filterType = .highShelf
        b[2].frequency = 8000
        b[2].gain = Float(high)
        for band in b { band.bypass = false }
        unit.globalGain = 0
    }

    var summary: String {
        func f(_ v: Double) -> String { String(format: "%+.1f", v) }
        return "Bas \(f(low)) · Mellem \(f(mid)) · Diskant \(f(high)) dB"
    }
}

/// Lås-beskyttet opsamling fra lyd-tråden (tap'en) til skærmen.
final class MeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peakL: Float = 0
    private var peakR: Float = 0

    func add(_ l: Float, _ r: Float) {
        lock.lock()
        peakL = max(peakL, l)
        peakR = max(peakR, r)
        lock.unlock()
    }

    func take() -> (Float, Float) {
        lock.lock()
        defer { peakL = 0; peakR = 0; lock.unlock() }
        return (peakL, peakR)
    }
}

final class PlayerModel: ObservableObject {
    static let shared = PlayerModel()

    @Published var track: LibTrack?
    @Published var playing = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var bands: [UInt8] = []
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

    @Published var eq = EQSettings() { didSet { eq.configure(eqUnit) } }
    @Published var volume: Double = 0.85 { didSet { engine.mainMixerNode.outputVolume = Float(volume) } }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let eqUnit = AVAudioUnitEQ(numberOfBands: 3)
    private var file: AVAudioFile?
    private var sampleRate: Double = 44100
    private var startFrame: AVAudioFramePosition = 0
    private var token = 0
    private var timer: Timer?
    private let meter = MeterBox()
    private var holdUntil = Date.distantPast
    private var tapInstalled = false

    init() {
        engine.attach(node)
        engine.attach(eqUnit)
        EQSettings().configure(eqUnit)
        engine.mainMixerNode.outputVolume = Float(volume)
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
        externalArt = art
        externalOverview = nil
        bands = LibraryStore.shared.bands(t)
        if bands.isEmpty { analyzeWave(t) }
        eq = EQSettings()
        clipped = false
        holdDB = -80
        startFrame = 0
        position = 0
        guard let f = try? AVAudioFile(forReading: t.url) else {
            file = nil
            duration = t.duration ?? 0
            return
        }
        file = f
        sampleRate = f.processingFormat.sampleRate
        duration = Double(f.length) / sampleRate
        connect(format: f.processingFormat)
        if autoplay { play() }
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
                self.externalOverview = WaveformCache.render(bands: r.bands, width: 2400, height: 80)
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
        if let t = liveTrack { bands = LibraryStore.shared.bands(t) }
    }

    private func connect(format: AVAudioFormat) {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            eqUnit.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eqUnit)
        engine.connect(node, to: eqUnit, format: format)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: format)
        let box = meter
        eqUnit.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            guard let d = buf.floatChannelData else { return }
            let n = vDSP_Length(buf.frameLength)
            var l: Float = 0
            vDSP_maxmgv(d[0], 1, &l, n)
            var r: Float = l
            if buf.format.channelCount > 1 { vDSP_maxmgv(d[1], 1, &r, n) }
            box.add(l, r)
        }
        tapInstalled = true
        engine.prepare()
    }

    func play() {
        guard let f = file else { return }
        if startFrame >= f.length { startFrame = 0 }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        schedule(from: startFrame)
        node.play()
        playing = true
        startTimer()
    }

    func pause() {
        guard playing else { return }
        startFrame = frame(for: currentTime())
        position = Double(startFrame) / sampleRate
        stopNode()
        playing = false
    }

    func toggle() { playing ? pause() : play() }

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
            schedule(from: startFrame)
            node.play()
        }
    }

    func stop() {
        stopNode()
        stopTimer()
        playing = false
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

    private func currentTime() -> Double {
        guard playing, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else {
            return Double(startFrame) / sampleRate
        }
        return min(duration, Double(startFrame + pt.sampleTime) / pt.sampleRate)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if playing { position = currentTime() }
        let (l, r) = meter.take()
        func db(_ v: Float) -> Double { v > 0 ? 20 * log10(Double(v)) : -80 }
        let dl = playing ? db(l) : -80
        let dr = playing ? db(r) : -80
        // Hurtigt op, roligt ned (ca. 24 dB/s)
        levelL = dl > levelL ? dl : max(dl, levelL - 0.8)
        levelR = dr > levelR ? dr : max(dr, levelR - 0.8)
        let peak = max(dl, dr)
        if peak >= holdDB || Date() > holdUntil {
            holdDB = peak >= holdDB ? peak : max(peak, holdDB - 0.5)
            if peak >= holdDB { holdUntil = Date().addingTimeInterval(1.5) }
        }
        if max(l, r) >= 1.0 { clipped = true }
        if !playing && levelL <= -79 && levelR <= -79 { stopTimer() }
    }
}

// MARK: - EQ i filen (offline med samme EQ som afspilleren)

enum EQRender {
    static func render(url: URL, eq: EQSettings) throws -> ([[Float]], Double) {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let unit = AVAudioUnitEQ(numberOfBands: 3)
        eq.configure(unit)
        engine.attach(node)
        engine.attach(unit)
        engine.connect(node, to: unit, format: fmt)
        engine.connect(unit, to: engine.mainMixerNode, format: fmt)
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
        while engine.manualRenderingSampleTime < file.length {
            let left = file.length - engine.manualRenderingSampleTime
            let frames = AVAudioFrameCount(min(Int64(maxFrames), left))
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
