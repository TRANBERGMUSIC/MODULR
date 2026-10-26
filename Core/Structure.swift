// MODULR – kerne: sangens opbygning (intro, buildup, drop, breakdown, outro), forslag til cue points A–H
// ud fra regler du selv kan sætte, og læring af hvordan du plejer at sætte dem. Plus EQ-områder.

import Foundation

enum SectionKind: String, Codable, CaseIterable, Identifiable {
    case intro, main, buildup, drop, breakdown, outro
    var id: String { rawValue }

    var title: String {
        switch self {
        case .intro: return "Intro"
        case .main: return "Groove"
        case .buildup: return "Buildup"
        case .drop: return "Drop"
        case .breakdown: return "Breakdown"
        case .outro: return "Outro"
        }
    }

    /// Farve til sektionsstrimlen (r, g, b)
    var rgb: (Double, Double, Double) {
        switch self {
        case .intro: return (0.45, 0.48, 0.55)
        case .main: return (0.55, 0.45, 0.75)
        case .buildup: return (0.95, 0.78, 0.25)
        case .drop: return (0.95, 0.32, 0.22)
        case .breakdown: return (0.28, 0.55, 0.95)
        case .outro: return (0.45, 0.48, 0.55)
        }
    }
}

struct SongSection: Codable, Equatable {
    var kind: SectionKind
    var ordinal: Int          // 1 = første drop, 2 = andet drop …
    var startBar: Int         // 0-baseret fra takt 1
    var endBar: Int
    var start: Double         // sekunder
    var end: Double
}

enum SongStructure {
    static let phraseBars = 8

    /// Opdeler sangen i fraser på 8 takter og navngiver dem ud fra bas/kick og energi.
    /// `bands`: 3 bytes pr. kolonne, 150 kolonner/s (MODULRs waveform-analyse).
    static func analyze(bands: [UInt8], bpm: Double, firstBeat: Double, duration: Double) -> [SongSection] {
        let rate = 150.0
        let cols = bands.count / 3
        guard bpm > 0, cols > 0, duration > 0 else { return [] }
        let barSec = 60 / bpm * 4
        let nbars = Int((duration - firstBeat) / barSec)
        guard nbars >= 8 else { return [] }
        var lo = [Double](repeating: 0, count: nbars)
        var en = [Double](repeating: 0, count: nbars)
        for i in 0..<nbars {
            let a = max(0, Int((firstBeat + Double(i) * barSec) * rate))
            let b = min(cols, Int((firstBeat + Double(i + 1) * barSec) * rate))
            guard b > a else { continue }
            var l = 0.0, e = 0.0
            for c in a..<b {
                l += Double(bands[c * 3])
                e += Double(max(bands[c * 3], max(bands[c * 3 + 1], bands[c * 3 + 2])))
            }
            lo[i] = l / Double(b - a)
            en[i] = e / Double(b - a)
        }
        func p90(_ v: [Double]) -> Double {
            let s = v.sorted()
            return max(1e-6, s[min(s.count - 1, Int(Double(s.count) * 0.9))])
        }
        let loRef = p90(lo), enRef = p90(en)

        struct Phrase { var kind: SectionKind; var start: Int; var end: Int; var energy: Double; var rising: Bool }
        var phrases = [Phrase]()
        var p = 0
        while p < nbars {
            let e = min(nbars, p + phraseBars)
            let n = Double(e - p)
            let L = lo[p..<e].reduce(0, +) / n / loRef
            let E = en[p..<e].reduce(0, +) / n / enRef
            var rising = false
            if e - p >= 4 {
                let first = (en[p] + en[p + 1]) / 2
                let last = (en[e - 2] + en[e - 1]) / 2
                rising = last > first * 1.25
            }
            let kind: SectionKind = L < 0.45 ? .breakdown : (E > 0.8 && L > 0.7 ? .drop : .main)
            phrases.append(Phrase(kind: kind, start: p, end: e, energy: E, rising: rising))
            p = e
        }
        // Buildup: frasen lige før et drop, hvis den stiger (eller er en breakdown med energi)
        if phrases.count > 1 {
            for i in 0..<(phrases.count - 1)
            where phrases[i + 1].kind == .drop && phrases[i].kind != .drop
                && (phrases[i].rising || (phrases[i].kind == .breakdown && phrases[i].energy > 0.4)) {
                phrases[i].kind = .buildup
            }
        }
        // Intro: alt før første drop/breakdown/buildup. Outro: groove efter sidste drop.
        let firstMain = phrases.firstIndex { [.drop, .breakdown, .buildup].contains($0.kind) } ?? phrases.count
        for i in 0..<firstMain { phrases[i].kind = .intro }
        if let lastDrop = phrases.lastIndex(where: { $0.kind == .drop }) {
            for i in (lastDrop + 1)..<phrases.count where phrases[i].kind == .main { phrases[i].kind = .outro }
        }
        // Præcise grænser: fraserne giver grænsen ±4 takter – den rigtige takt er der hvor bas og energi
        // skifter mest (2 takter før mod 2 takter efter). Så rammer et drop på takt 26 også takt 26.
        func change(_ b: Int) -> Double {
            guard b >= 2, b + 2 <= nbars else { return -1 }
            let l1 = (lo[b - 2] + lo[b - 1]) / 2, l2 = (lo[b] + lo[b + 1]) / 2
            let e1 = (en[b - 2] + en[b - 1]) / 2, e2 = (en[b] + en[b + 1]) / 2
            return abs(l2 - l1) / loRef + abs(e2 - e1) / enRef
        }
        var merged = [Phrase]()
        for ph in phrases {
            if let last = merged.last, last.kind == ph.kind {
                merged[merged.count - 1].end = ph.end
            } else {
                merged.append(ph)
            }
        }
        if merged.count > 1 {
            for i in 1..<merged.count {
                let b = merged[i].start
                let lowLimit = merged[i - 1].start + 1
                let highLimit = merged[i].end - 1
                var best = b, bestScore = change(b)
                for c in max(lowLimit, b - 4)...max(max(lowLimit, b - 4), min(highLimit, b + 4)) {
                    let sc = change(c)
                    if sc > bestScore + 1e-9 { best = c; bestScore = sc }
                }
                merged[i].start = best
                merged[i - 1].end = best
            }
        }
        phrases = merged

        // Slå ens fraser sammen og nummerér (1. drop, 2. drop …)
        var out = [SongSection]()
        var counts = [SectionKind: Int]()
        for ph in phrases {
            if var last = out.last, last.kind == ph.kind {
                last.endBar = ph.end
                last.end = firstBeat + Double(ph.end) * barSec
                out[out.count - 1] = last
            } else {
                counts[ph.kind, default: 0] += 1
                out.append(SongSection(kind: ph.kind, ordinal: counts[ph.kind]!, startBar: ph.start, endBar: ph.end,
                                       start: firstBeat + Double(ph.start) * barSec, end: firstBeat + Double(ph.end) * barSec))
            }
        }
        return out
    }
}

// MARK: - Regler for cue points

/// Hvor en hot cue skal sidde: første slag eller starten af en bestemt sektion – plus/minus et antal takter.
struct CueRule: Codable, Equatable {
    enum Target: String, Codable, CaseIterable, Identifiable {
        case none, firstBeat, intro, main, buildup, drop, breakdown, outro
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: return "Ingen"
            case .firstBeat: return "Første slag"
            case .intro: return "Intro"
            case .main: return "Groove"
            case .buildup: return "Buildup"
            case .drop: return "Drop"
            case .breakdown: return "Breakdown"
            case .outro: return "Outro"
            }
        }
        var section: SectionKind? { SectionKind(rawValue: rawValue) }
    }

    var target: Target
    var ordinal: Int = 1         // hvilken (1. drop, 2. drop …)
    var offsetBars: Int = 0      // takter efter (+) eller før (−)

    var key: String { "\(target.rawValue)#\(ordinal)\(offsetBars >= 0 ? "+" : "")\(offsetBars)" }

    init(target: Target, ordinal: Int = 1, offsetBars: Int = 0) {
        self.target = target
        self.ordinal = ordinal
        self.offsetBars = offsetBars
    }

    init?(key: String) {
        let parts = key.split(separator: "#")
        guard parts.count == 2, let t = Target(rawValue: String(parts[0])) else { return nil }
        let rest = String(parts[1])
        guard let signIdx = rest.firstIndex(where: { $0 == "+" || $0 == "-" }),
              let ord = Int(rest[..<signIdx]), let off = Int(rest[signIdx...].replacingOccurrences(of: "+", with: "")) else { return nil }
        self.init(target: t, ordinal: ord, offsetBars: off)
    }

    var summary: String {
        var s: String
        switch target {
        case .none: return "Ingen"
        case .firstBeat: s = "Første slag"
        default: s = "\(ordinal). \(target.title.lowercased())"
        }
        if offsetBars != 0 { s += " \(offsetBars > 0 ? "+" : "−")\(abs(offsetBars)) takter" }
        return s
    }

    /// Tidspunktet (sekunder) for reglen i en sang, eller nil hvis sangen ikke har den sektion.
    func resolve(sections: [SongSection], bpm: Double, firstBeat: Double, duration: Double) -> Double? {
        guard bpm > 0 else { return nil }
        let barSec = 60 / bpm * 4
        var base: Double?
        switch target {
        case .none: return nil
        case .firstBeat:
            base = firstBeat
        default:
            guard let kind = target.section else { return nil }
            base = sections.first { $0.kind == kind && $0.ordinal == ordinal }?.start
        }
        guard let b = base else { return nil }
        let t = b + Double(offsetBars) * barSec
        return t >= 0 && t < duration ? t : nil
    }
}

enum CueRules {
    static let rulesKey = "cue.rules"
    static let learnKey = "cue.learn"
    static let learnEnabledKey = "cue.learnEnabled"

    /// Standard: A første slag, B 16 takter inde, C 1. breakdown, D 1. buildup, E 1. drop,
    /// F 2. breakdown, G 2. drop, H outro.
    static let defaults: [String: CueRule] = [
        "A": CueRule(target: .firstBeat),
        "B": CueRule(target: .firstBeat, offsetBars: 16),
        "C": CueRule(target: .breakdown),
        "D": CueRule(target: .buildup),
        "E": CueRule(target: .drop),
        "F": CueRule(target: .breakdown, ordinal: 2),
        "G": CueRule(target: .drop, ordinal: 2),
        "H": CueRule(target: .outro),
    ]

    static var rules: [String: CueRule] {
        get {
            guard let d = UserDefaults.standard.data(forKey: rulesKey),
                  let r = try? JSONDecoder().decode([String: CueRule].self, from: d) else { return defaults }
            return defaults.merging(r) { _, new in new }
        }
        set {
            if let d = try? JSONEncoder().encode(newValue) { UserDefaults.standard.set(d, forKey: rulesKey) }
        }
    }

    static var learnEnabled: Bool {
        get { UserDefaults.standard.object(forKey: learnEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: learnEnabledKey) }
    }

    /// Hvad du har gjort før: [bogstav: [regel-nøgle: antal]]
    static var learned: [String: [String: Int]] {
        get { (UserDefaults.standard.dictionary(forKey: learnKey) as? [String: [String: Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: learnKey) }
    }

    /// Den regel du selv bruger mest for et bogstav (mindst 3 gange og over halvdelen af gangene).
    static func learnedRule(for letter: String) -> (rule: CueRule, count: Int)? {
        guard learnEnabled, let counts = learned[letter], let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        let total = counts.values.reduce(0, +)
        guard best.value >= 3, Double(best.value) / Double(total) > 0.5, let r = CueRule(key: best.key) else { return nil }
        return (r, best.value)
    }

    /// Reglen der bruges til forslaget: det du har lært appen, ellers dine regler.
    static func effectiveRule(for letter: String) -> CueRule {
        learnedRule(for: letter)?.rule ?? rules[letter] ?? CueRule(target: .none)
    }

    /// Hvilken regel beskriver bedst en cue du selv har sat? (nærmeste sektionsstart, ellers takter fra første slag)
    static func describe(_ t: Double, sections: [SongSection], bpm: Double, firstBeat: Double) -> CueRule? {
        guard bpm > 0 else { return nil }
        let barSec = 60 / bpm * 4
        var best: (CueRule, Int)?
        for s in sections {
            guard let target = CueRule.Target(rawValue: s.kind.rawValue) else { continue }
            let off = Int(((t - s.start) / barSec).rounded())
            guard abs(off) <= 8 else { continue }
            if best == nil || abs(off) < abs(best!.1) { best = (CueRule(target: target, ordinal: s.ordinal, offsetBars: off), off) }
        }
        let fromFirst = Int(((t - firstBeat) / barSec).rounded())
        if fromFirst == 0 || best == nil { return CueRule(target: .firstBeat, offsetBars: max(-64, min(256, fromFirst))) }
        return best?.0
    }

    static func learn(letter: String, rule: CueRule) {
        guard learnEnabled else { return }
        var all = learned
        all[letter, default: [:]][rule.key, default: 0] += 1
        learned = all
    }

    /// Forslag A–H for en sang.
    static func suggestions(sections: [SongSection], bpm: Double, firstBeat: Double, duration: Double) -> [String: Double] {
        var out = [String: Double]()
        for letter in HotCue.letters {
            if let t = effectiveRule(for: letter).resolve(sections: sections, bpm: bpm, firstBeat: firstBeat, duration: duration) {
                out[letter] = t
            }
        }
        return out
    }
}

// MARK: - EQ-områder

/// EQ på et bestemt stykke af sangen (fx mere bas kun i droppet).
struct EQRegionData: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var low: Double = 0
    var mid: Double = 0
    var high: Double = 0

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}
