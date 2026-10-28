// MODULR – kerne: sangens opbygning (intro, buildup, drop, breakdown, outro), forslag til cue points A–H
// ud fra en plan du selv skriver (altid i tidsrækkefølge), og læring af hvordan du plejer at flytte dem. Plus EQ-områder.

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
                var best = b, bestScore = change(b) * (b % 8 == 0 ? 1.1 : (b % 4 == 0 ? 1.05 : 1))
                for c in max(lowLimit, b - 4)...max(max(lowLimit, b - 4), min(highLimit, b + 4)) {
                    // Dansemusik skifter næsten altid på 4/8-takters grænser – de vinder ved tæt løb
                    let sc = change(c) * (c % 8 == 0 ? 1.1 : (c % 4 == 0 ? 1.05 : 1))
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

/// Et hot cue-forslag: hvilket bogstav, hvor, og hvilken del af sangen.
struct CueSuggestion: Identifiable, Equatable {
    var id: String              // fx "drop#2" – samme del i samme sang har altid samme id
    var letter: String?         // nil = ingen ledig plads i rækkefølgen (dine egne cues ligger i vejen)
    var at: Double              // sekunder
    var bar: Int                // takt (1 = første takt)
    var title: String           // "2. drop", "Første slag +16"
    var target: CueRule.Target
    var moved: Int              // takter du har flyttet forslaget
    var learned: Int            // takter appen flytter det ud fra det lærte
}

/// Planen: en tekst du selv skriver ("første slag, buildup, drop, breakdown, drop 2, outro"),
/// som bliver til en liste af dele. Bogstaverne A–H gives altid i tidsrækkefølge.
enum CuePlan {
    static let standard = "første slag, første slag +16, buildup, drop, breakdown, buildup 2, drop 2, outro"

    /// Ord der genkendes (dansk og engelsk). Rækkefølgen betyder noget: "breakdown" før "drop" osv.
    static let words: [(CueRule.Target, [String])] = [
        (.buildup, ["buildup", "build-up", "build up", "build", "opbygning", "riser", "oprul"]),
        (.breakdown, ["breakdown", "break down", "break", "pause"]),
        (.drop, ["drop"]),
        (.intro, ["intro", "indledning"]),
        (.outro, ["outro", "slutning", "afslutning"]),
        (.main, ["groove", "main", "vers", "verse", "hook"]),
        (.firstBeat, ["første slag", "første beat", "første takt", "first beat", "start", "begyndelse", "beat 1", "slag 1"]),
    ]

    static let ordinalWords: [(Int, [String])] = [
        (0, ["alle", "all", "hver", "hvert", "every", "each"]),
        (-1, ["sidste", "last", "final"]),
        (1, ["første", "first", "1."]),
        (2, ["anden", "andet", "second", "2."]),
        (3, ["tredje", "third", "3."]),
        (4, ["fjerde", "fourth", "4."]),
    ]

    /// Teksten → dele i den rækkefølge du skrev dem, plus de ord appen ikke forstod.
    static func parse(_ text: String) -> (parts: [CueRule], unknown: [String]) {
        var s = " " + text.lowercased() + " "
        for sep in ["→", "->", ";", "\n", "/", "|", " og ", " and ", " then ", " så "] {
            s = s.replacingOccurrences(of: sep, with: ",")
        }
        s = s.replacingOccurrences(of: "−", with: "-")
        var parts = [CueRule]()
        var unknown = [String]()
        for raw in s.split(separator: ",") {
            var tok = raw.trimmingCharacters(in: .whitespaces)
            guard !tok.isEmpty else { continue }
            // Hvilken del? (første ord-match vinder)
            var hit: CueRule.Target?
            var matchedWord = ""
            outer: for (t, list) in words {
                for w in list where tok.contains(w) {
                    hit = t; matchedWord = w
                    break outer
                }
            }
            guard let target = hit else { unknown.append(tok); continue }
            let plural = tok.contains(matchedWord + "s") || tok.contains(matchedWord + "er")
            tok = tok.replacingOccurrences(of: matchedWord, with: " ")

            // Forskydning: "+16", "-4", "16 takter før", "8 bars after"
            var offset = 0
            if let m = firstMatch(#"([+-])\s*(\d+)"#, in: tok) {
                let n = Int(m.groups[1]) ?? 0
                offset = m.groups[0] == "-" ? -n : n
                tok = m.removed
            } else if let m = firstMatch(#"(\d+)\s*(takter|takt|bars|bar)\s*(før|inden|tidligere|before|efter|inde|ind|after|into|senere)?"#, in: tok) {
                let n = Int(m.groups[0]) ?? 0
                let neg = ["før", "inden", "tidligere", "before"].contains(m.groups[2])
                offset = neg ? -n : n
                tok = m.removed
            }

            // Hvilken af dem: "drop 2", "2. drop", "andet drop", "alle drops", "sidste breakdown"
            var ordinal = plural ? 0 : 1
            if target != .firstBeat {
                var found = false
                for (n, list) in ordinalWords {
                    if list.contains(where: { w in tok.split(separator: " ").contains { $0 == w } || (w.hasSuffix(".") && tok.contains(w)) }) {
                        ordinal = n; found = true
                        break
                    }
                }
                if !found, let m = firstMatch(#"(\d+)"#, in: tok), let n = Int(m.groups[0]), n >= 1, n <= 9 {
                    ordinal = n
                }
            }
            parts.append(CueRule(target: target, ordinal: target == .firstBeat ? 1 : ordinal, offsetBars: offset))
        }
        return (parts, unknown)
    }

    /// Tekst for én del (bruges når du klikker en del ind i planen).
    static func text(for r: CueRule) -> String {
        var s: String
        switch r.target {
        case .none: return ""
        case .firstBeat: s = "første slag"
        default:
            let name = r.target.title.lowercased()
            switch r.ordinal {
            case 0: s = "alle \(name)s"
            case -1: s = "sidste \(name)"
            case 1: s = name
            default: s = "\(name) \(r.ordinal)"
            }
        }
        if r.offsetBars != 0 { s += " \(r.offsetBars > 0 ? "+" : "-")\(abs(r.offsetBars))" }
        return s
    }

    private struct Match { var groups: [String]; var removed: String }

    private static func firstMatch(_ pattern: String, in s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        var groups = [String]()
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: s) { groups.append(String(s[r])) } else { groups.append("") }
        }
        guard let all = Range(m.range, in: s) else { return nil }
        var rest = s
        rest.replaceSubrange(all, with: " ")
        return Match(groups: groups, removed: rest)
    }
}

enum CueRules {
    static let planKey = "cue.plan"
    static let offsetsKey = "cue.learnOffsets"
    static let learnEnabledKey = "cue.learnEnabled"

    /// Den plan du har skrevet (gemmes).
    static var planText: String {
        get { UserDefaults.standard.string(forKey: planKey) ?? CuePlan.standard }
        set { UserDefaults.standard.set(newValue, forKey: planKey) }
    }

    static var learnEnabled: Bool {
        get { UserDefaults.standard.object(forKey: learnEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: learnEnabledKey) }
    }

    /// Hvor du flytter dine cues i forhold til sektionsstarten: [del: [takter: antal]]
    static var learnedOffsets: [String: [String: Int]] {
        get { (UserDefaults.standard.dictionary(forKey: offsetsKey) as? [String: [String: Int]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: offsetsKey) }
    }

    /// Det du plejer: fx "drop → 4 takter før" (mindst 3 gange og over halvdelen af gangene).
    static func learnedOffset(for target: CueRule.Target) -> (bars: Int, count: Int)? {
        guard learnEnabled, let counts = learnedOffsets[target.rawValue],
              let best = counts.max(by: { $0.value < $1.value }), let bars = Int(best.key) else { return nil }
        let total = counts.values.reduce(0, +)
        guard best.value >= 3, Double(best.value) / Double(total) > 0.5 else { return nil }
        return (bars, best.value)
    }

    static func learnOffset(_ target: CueRule.Target, bars: Int) {
        guard learnEnabled, target.section != nil, abs(bars) <= 16 else { return }
        var all = learnedOffsets
        all[target.rawValue, default: [:]][String(bars), default: 0] += 1
        learnedOffsets = all
    }

    /// Hvilken del beskriver bedst en cue du selv har sat? (nærmeste sektionsstart, ellers takter fra første slag)
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

    /// Forslag A–H: delene fra planen findes i sangen, dobbelte fjernes, og bogstaverne gives i tidsrækkefølge
    /// – også i forhold til de hot cues du allerede har sat (et forslag får aldrig et bogstav der bryder rækkefølgen).
    static func suggestions(plan: [CueRule], sections: [SongSection], bpm: Double, firstBeat: Double, gridStart: Double,
                            duration: Double, existing: [String: Double] = [:], moved: [String: Int] = [:],
                            dismissed: Set<String> = []) -> [CueSuggestion] {
        guard bpm > 0, duration > 0 else { return [] }
        let barSec = 60 / bpm * 4
        struct Cand { var s: CueSuggestion; var priority: Int }
        var cands = [Cand]()
        for (pi, part) in plan.enumerated() {
            var hits = [(base: Double, title: String, id: String)]()
            switch part.target {
            case .none: continue
            case .firstBeat:
                let title = part.offsetBars == 0 ? "Første slag" : "Første slag \(part.offsetBars > 0 ? "+" : "−")\(abs(part.offsetBars))"
                hits.append((firstBeat, title, "firstBeat\(part.offsetBars >= 0 ? "+" : "")\(part.offsetBars)"))
            default:
                guard let kind = part.target.section else { continue }
                let all = sections.filter { $0.kind == kind }
                let chosen: [SongSection]
                switch part.ordinal {
                case 0: chosen = all
                case -1: chosen = all.last.map { [$0] } ?? []
                default: chosen = all.filter { $0.ordinal == part.ordinal }
                }
                for sec in chosen {
                    let name = all.count > 1 ? "\(sec.ordinal). \(kind.title.lowercased())" : kind.title
                    hits.append((sec.start, name, "\(kind.rawValue)#\(sec.ordinal)\(part.offsetBars == 0 ? "" : "\(part.offsetBars > 0 ? "+" : "")\(part.offsetBars)")"))
                }
            }
            for h in hits {
                // Det lærte gælder kun sektioner, og kun når du ikke selv har skrevet en forskydning
                let learned = (part.target.section != nil && part.offsetBars == 0) ? (learnedOffset(for: part.target)?.bars ?? 0) : 0
                let m = moved[h.id] ?? 0
                let bars = part.offsetBars + learned + m
                var t = h.base + Double(bars) * barSec
                if part.target.section != nil, t < firstBeat { t = firstBeat }
                guard t >= 0, t < duration - barSec, !dismissed.contains(h.id) else { continue }
                var title = h.title
                if part.target.section != nil, part.offsetBars != 0 {
                    title += " \(part.offsetBars > 0 ? "+" : "−")\(abs(part.offsetBars))"
                }
                let bar = Int(((t - gridStart) / barSec).rounded()) + 1
                cands.append(Cand(s: CueSuggestion(id: h.id, letter: nil, at: t, bar: bar, title: title, target: part.target,
                                                   moved: m, learned: learned), priority: pi))
            }
        }
        // Samme sted to gange (fx "buildup" = "første slag +16"): den du skrev først vinder
        let minGap = barSec * 1.5
        var kept = [Cand]()
        for c in cands.sorted(by: { ($0.priority, $0.s.at) < ($1.priority, $1.s.at) }) {
            if kept.contains(where: { abs($0.s.at - c.s.at) < minGap || $0.s.id == c.s.id }) { continue }
            if existing.values.contains(where: { abs($0 - c.s.at) < minGap }) { continue }
            kept.append(c)
        }
        // Højst så mange som der er ledige bogstaver – de vigtigste (først i planen) beholdes
        let free = HotCue.letters.filter { existing[$0] == nil }.count
        if kept.count > free { kept = Array(kept.prefix(free)) }

        // Bogstaver i tidsrækkefølge, uden om dine egne cues
        let letters = HotCue.letters
        var out = kept.map(\.s).sorted { $0.at < $1.at }
        var last = -1
        for i in out.indices {
            let at = out[i].at
            var lower = last
            var upper = letters.count
            for (l, t) in existing {
                guard let li = letters.firstIndex(of: l) else { continue }
                if t <= at { lower = max(lower, li) } else { upper = min(upper, li) }
            }
            if let li = ((lower + 1)..<max(lower + 1, upper)).first(where: { existing[letters[$0]] == nil }) {
                out[i].letter = letters[li]
                last = li
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
