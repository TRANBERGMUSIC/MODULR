// MODULR – kerne: kvalitetsscore 0–100, label og "kun bedre"-reglen.
// Kun Foundation, så det kan testes uden lyd.

import Foundation

/// Filens tekniske data (fra containeren) – det filen PÅSTÅR.
struct FormatInfo: Equatable {
    var codec: String            // "MP3", "AAC", "FLAC", "ALAC", "WAV", "AIFF" …
    var container: String        // filendelse i store bogstaver
    var nominalKbps: Int?
    var sampleRate: Double
    var bitDepth: Int?
    var channels: Int

    var isLossless: Bool {
        ["FLAC", "ALAC", "WAV", "AIFF", "PCM"].contains(codec)
    }
}

/// Samlet kvalitetsvurdering: hvad filen påstår + hvad lyden faktisk viser.
struct QualityReport: Equatable {
    var format: FormatInfo
    var cutoffHz: Double?
    var tierKbps: Int            // 9999 = fuld båndbredde
    var tierLabel: String
    var score: Int               // 0–100
    var label: String            // fx "MP3 320 kbps, ægte" / "FLAC, men lyder som 128 kbps"
    var upscaled: Bool           // fx WAV/FLAC/320 der reelt er lavere kvalitet
}

enum ImprovementRule: String, CaseIterable, Codable, Identifiable {
    case realTier        // standard: kun hvis den reelle kvalitet er et trin bedre
    case anyImprovement  // enhver højere score

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realTier: return "Kun hvis den reelle kvalitet er bedre (anbefalet)"
        case .anyImprovement: return "Enhver forbedring af kvalitetsscoren"
        }
    }
}

enum Quality {
    /// Rang for den reelle kvalitet. Lossless kun hvis lyden faktisk er fuld båndbredde.
    static func rank(tierKbps: Int, lossless: Bool) -> Int {
        switch tierKbps {
        case 9999: return lossless ? 9 : 8   // lossy uden lowpass ≈ 320
        case 320...: return 8
        case 256...: return 7
        case 192...: return 6
        case 160...: return 5
        case 128...: return 4
        case 96...: return 3
        default: return 2
        }
    }

    static func score(tierKbps: Int, lossless: Bool) -> Int {
        switch rank(tierKbps: tierKbps, lossless: lossless) {
        case 9: return 100
        case 8: return 88
        case 7: return 78
        case 6: return 65
        case 5: return 55
        case 4: return 45
        case 3: return 30
        default: return 20
        }
    }

    static func make(format: FormatInfo, cutoffHz: Double?, tierKbps: Int, tierLabel: String) -> QualityReport {
        let lossless = format.isLossless
        let s = score(tierKbps: tierKbps, lossless: lossless)
        let sounds = tierKbps >= 9999 ? "fuld båndbredde" : tierLabel
        var upscaled = false
        var label: String

        if lossless {
            if tierKbps >= 9999 {
                let bits = format.bitDepth.map { "\($0)-bit" } ?? ""
                let khz = String(format: "%.1f kHz", format.sampleRate / 1000).replacingOccurrences(of: ".", with: ",")
                label = "\(format.codec) \(bits) \(khz), ægte lossless".replacingOccurrences(of: "  ", with: " ")
            } else {
                upscaled = true
                label = "\(format.codec), men lyder som \(sounds)"
            }
        } else {
            let claimed = format.nominalKbps ?? 0
            let claimedText = claimed > 0 ? "\(claimed) kbps" : "ukendt bitrate"
            let realRank = rank(tierKbps: tierKbps, lossless: false)
            let claimedRank = claimed > 0 ? rank(tierKbps: claimed, lossless: false) : realRank
            if realRank >= claimedRank || claimed - 40 <= min(tierKbps, 320) {
                label = "\(format.codec) \(claimedText), ægte"
            } else {
                upscaled = true
                label = "\(format.codec) \(claimedText), men lyder som \(sounds)"
            }
        }
        return QualityReport(format: format, cutoffHz: cutoffHz, tierKbps: tierKbps, tierLabel: tierLabel,
                             score: s, label: label, upscaled: upscaled)
    }

    /// "Kun bedre"-reglen: accepter kun en ny fil hvis den er reelt bedre end den gamle.
    static func isBetter(_ new: QualityReport, than old: QualityReport, rule: ImprovementRule) -> (better: Bool, reason: String) {
        let newRank = rank(tierKbps: new.tierKbps, lossless: new.format.isLossless)
        let oldRank = rank(tierKbps: old.tierKbps, lossless: old.format.isLossless)
        switch rule {
        case .realTier:
            if newRank > oldRank { return (true, "Reelt bedre: \(new.label) i stedet for \(old.label)") }
        case .anyImprovement:
            if new.score > old.score { return (true, "Bedre score: \(new.score) mod \(old.score)") }
        }
        if new.upscaled && newRank <= oldRank {
            return (false, "Opskaleret: filen påstår \(new.format.codec), men lyder som \(new.tierLabel)")
        }
        if newRank == oldRank { return (false, "Samme kvalitet som din fil (\(new.tierLabel))") }
        return (false, "Dårligere kvalitet end din fil (\(new.tierLabel))")
    }
}
