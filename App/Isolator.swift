// MODULR – EQ som en isolator på en DJ-mixer: lyden deles i tre bånd med stejle filtre (24 dB/oktav,
// Linkwitz-Riley), og hvert bånd har sin egen volumen. Helt nede = båndet er væk (kill) – næsten som stems:
// bas/kick, mellemtone (vokal, synth) og diskant (hihats) kan fjernes hver for sig.
// Står alle tre på 0 dB, går lyden helt uden om filtrene (urørt).

import AVFoundation

final class IsolatorEQ {
    /// Delefrekvenser: under 220 Hz = bas og kick, 220 Hz–3 kHz = vokal/synth, over 3 kHz = hihats og luft.
    static let lowCross: Float = 220
    static let highCross: Float = 3000

    let lowF = AVAudioUnitEQ(numberOfBands: 2)    // lavpas × 2
    let midF = AVAudioUnitEQ(numberOfBands: 4)    // højpas × 2 + lavpas × 2
    let highF = AVAudioUnitEQ(numberOfBands: 2)   // højpas × 2
    let lowV = AVAudioMixerNode()
    let midV = AVAudioMixerNode()
    let highV = AVAudioMixerNode()
    let dryV = AVAudioMixerNode()                 // urørt lyd (bruges når EQ'en står flad)
    let sum = AVAudioMixerNode()

    var nodes: [AVAudioNode] { [lowF, midF, highF, lowV, midV, highV, dryV, sum] }
    var output: AVAudioNode { sum }

    init() {
        Self.setup(lowF, [(.lowPass, Self.lowCross), (.lowPass, Self.lowCross)])
        Self.setup(midF, [(.highPass, Self.lowCross), (.highPass, Self.lowCross),
                          (.lowPass, Self.highCross), (.lowPass, Self.highCross)])
        Self.setup(highF, [(.highPass, Self.highCross), (.highPass, Self.highCross)])
        apply(gains: [0, 0, 0], wet: 0)
    }

    private static func setup(_ unit: AVAudioUnitEQ, _ filters: [(AVAudioUnitEQFilterType, Float)]) {
        for (i, f) in filters.enumerated() where i < unit.bands.count {
            let b = unit.bands[i]
            b.filterType = f.0          // 2. ordens Butterworth – to i træk = Linkwitz-Riley 24 dB/oktav
            b.frequency = f.1
            b.gain = 0
            b.bypass = false
        }
        unit.globalGain = 0
        unit.bypass = false
    }

    func attach(to engine: AVAudioEngine) { nodes.forEach { engine.attach($0) } }
    func detach(from engine: AVAudioEngine) { nodes.forEach { engine.detach($0) } }
    func disconnect(in engine: AVAudioEngine) { nodes.forEach { engine.disconnectNodeOutput($0) } }

    /// Kobler kilde → (tre bånd + urørt) → sum → destination. Bagfra, så ingen ende er uenig om formatet.
    func connect(in engine: AVAudioEngine, from source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat) {
        engine.connect(sum, to: destination, format: format)
        engine.connect(lowV, to: sum, fromBus: 0, toBus: 0, format: format)
        engine.connect(midV, to: sum, fromBus: 0, toBus: 1, format: format)
        engine.connect(highV, to: sum, fromBus: 0, toBus: 2, format: format)
        engine.connect(dryV, to: sum, fromBus: 0, toBus: 3, format: format)
        engine.connect(lowF, to: lowV, fromBus: 0, toBus: 0, format: format)
        engine.connect(midF, to: midV, fromBus: 0, toBus: 0, format: format)
        engine.connect(highF, to: highV, fromBus: 0, toBus: 0, format: format)
        let points = [AVAudioConnectionPoint(node: lowF, bus: 0), AVAudioConnectionPoint(node: midF, bus: 0),
                      AVAudioConnectionPoint(node: highF, bus: 0), AVAudioConnectionPoint(node: dryV, bus: 0)]
        engine.connect(source, to: points, fromBus: 0, format: format)
    }

    /// Knappens dB → volumen. Ned til −20 dB som normalt; de sidste 6 dB glider ned til helt væk (kill).
    static func amp(_ db: Float) -> Float {
        if db >= -20 { return powf(10, db / 20) }
        return max(0, 0.1 * (db + 26) / 6)
    }

    /// `wet` 0 = urørt lyd, 1 = de tre bånd (glider imellem, så der ikke kommer et klik).
    func apply(gains g: [Float], wet: Float) {
        guard g.count >= 3 else { return }
        let w = max(0, min(1, wet))
        lowV.outputVolume = w * Self.amp(g[0])
        midV.outputVolume = w * Self.amp(g[1])
        highV.outputVolume = w * Self.amp(g[2])
        dryV.outputVolume = 1 - w
    }
}
