// MODULR – EQ der kan dræbe et bånd næsten helt (som stems / en isolator på en DJ-mixer):
// bas og kick under 220 Hz, vokal/synth 220 Hz–3 kHz, hihats og luft over 3 kHz.
// Én AVAudioUnitEQ i serie (afspiller → EQ → mixer) – samme simple kobling som før, så lyden aldrig
// står "afkoblet". Normalt arbejder knapperne med shelf/klokke; helt i bund slås stejle filtre til
// (24 dB/oktav), så båndet forsvinder. Står alt på 0 dB, er alle bånd neutrale (urørt lyd).

import AVFoundation

final class IsolatorEQ {
    static let lowCross: Float = 220
    static let highCross: Float = 3000

    // Bånd i EQ-enheden
    private enum B {
        static let lowCut1 = 0, lowCut2 = 1      // højpas 220 Hz ×2 (kun ved kill)
        static let lowShelf = 2
        static let mid1 = 3, mid2 = 4            // to brede klokker der dækker 220 Hz–3 kHz
        static let highShelf = 5
        static let highCut1 = 6, highCut2 = 7    // lavpas 3 kHz ×2 (kun ved kill)
        static let count = 8
    }

    let unit = AVAudioUnitEQ(numberOfBands: B.count)
    var output: AVAudioNode { unit }
    var nodes: [AVAudioNode] { [unit] }

    init() {
        let b = unit.bands
        func set(_ i: Int, _ type: AVAudioUnitEQFilterType, _ f: Float, bw: Float = 1) {
            b[i].filterType = type
            b[i].frequency = f
            b[i].bandwidth = bw
            b[i].gain = 0
            b[i].bypass = false
        }
        set(B.lowCut1, .highPass, Self.lowCross)
        set(B.lowCut2, .highPass, Self.lowCross)
        set(B.lowShelf, .lowShelf, Self.lowCross)
        set(B.mid1, .parametric, 520, bw: 1.7)
        set(B.mid2, .parametric, 1350, bw: 1.7)
        set(B.highShelf, .highShelf, Self.highCross)
        set(B.highCut1, .lowPass, Self.highCross)
        set(B.highCut2, .lowPass, Self.highCross)
        unit.globalGain = 0
        unit.bypass = false
        apply(gains: [0, 0, 0], wet: 0)
    }

    func attach(to engine: AVAudioEngine) { engine.attach(unit) }
    func detach(from engine: AVAudioEngine) { engine.detach(unit) }
    func disconnect(in engine: AVAudioEngine) { engine.disconnectNodeOutput(unit) }

    /// Kilde → EQ → destination. Bagfra, så EQ'ens to ender aldrig er uenige om formatet.
    func connect(in engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat) {
        engine.connect(unit, to: destination, format: format)
        engine.connect(source, to: unit, format: format)
    }

    /// Knappens dB → volumen (bruges også til at vise EQ'en i waveformen og Bas-visningen).
    static func amp(_ db: Float) -> Float {
        if db >= -20 { return powf(10, db / 20) }
        return max(0, 0.1 * (db + 26) / 6)
    }

    /// Knappens dB → filterets dB: som knappen ned til −20, derefter hurtigt ned mod −44 dB.
    static func filterDB(_ db: Float) -> Float {
        db >= -20 ? db : -20 + (db + 20) * 4
    }

    /// `wet` bruges ikke længere (alt neutralt = urørt), men beholdes så kaldene er de samme.
    func apply(gains g: [Float], wet: Float) {
        guard g.count >= 3 else { return }
        let b = unit.bands
        let low = Self.filterDB(g[0]), mid = Self.filterDB(g[1]), high = Self.filterDB(g[2])
        let lowKill = g[0] <= -25.9, highKill = g[2] <= -25.9
        func gain(_ i: Int, _ v: Float) { if b[i].gain != v { b[i].gain = v } }
        func bypass(_ i: Int, _ v: Bool) { if b[i].bypass != v { b[i].bypass = v } }
        gain(B.lowShelf, max(-96, low))
        bypass(B.lowCut1, !lowKill); bypass(B.lowCut2, !lowKill)
        // To overlappende klokker: halvdelen hver, så de tilsammen giver knappens værdi i midten
        gain(B.mid1, max(-96, mid * 0.62))
        gain(B.mid2, max(-96, mid * 0.62))
        gain(B.highShelf, max(-96, high))
        bypass(B.highCut1, !highKill); bypass(B.highCut2, !highKill)
    }
}
