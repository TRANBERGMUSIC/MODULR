// MODULR – kerne: Chromaprint-fingerprints (fpcalc) og sammenligning af to optagelser.
// Kun Foundation.

import Foundation

struct Fingerprint: Equatable {
    var raw: [UInt32]          // til sammenligning
    var compressed: String     // til AcoustID-opslag
    var duration: Double
}

struct FingerprintComparison: Equatable {
    var coverageLong: Double   // andel af den LÆNGSTE fil der matcher
    var coverageShort: Double  // andel af den KORTESTE fil der matcher
    var offset: Int
    var similarity: Double     // 1 - bitfejlrate over overlappet

    var percent: Int { Int((coverageLong * 100).rounded()) }
}

enum RecordingVerdict: Equatable {
    case same
    case otherVersion(String)
    case different(String)
}

enum FingerprintError: LocalizedError {
    case fpcalcMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .fpcalcMissing: return "fpcalc (Chromaprint) blev ikke fundet. Geninstallér MODULR med Installer.command."
        case .failed(let m): return "Fingerprint fejlede: \(m)"
        }
    }
}

enum Fingerprinter {
    /// Ca. 8 fingerprint-elementer pr. sekund lyd.
    static let itemsPerSecond = 11025.0 / 4096.0 * 3.0
    static let bitThreshold = 8          // højst 8 af 32 bit må afvige for at et element tæller som match
    static let sameCoverage = 0.80       // mindst 80 % af den længste fil skal matche
    static let durationTolerance = 3.0

    static func fpcalcPath() -> String? {
        var candidates = [String]()
        if let env = ProcessInfo.processInfo.environment["FPCALC"] { candidates.append(env) }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("fpcalc").path { candidates.append(res) }
        candidates += ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc", "/usr/bin/fpcalc"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runFpcalc(_ args: [String]) throws -> [String: Any] {
        guard let path = fpcalcPath() else { throw FingerprintError.fpcalcMissing }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FingerprintError.failed(String(data: errData, encoding: .utf8) ?? "ukendt fejl")
        }
        return obj
    }

    /// Fuldt fingerprint af hele filen (rå) + standard-fingerprint til AcoustID.
    static func fingerprint(of url: URL) throws -> Fingerprint {
        let rawObj = try runFpcalc(["-json", "-raw", "-length", "0", url.path])
        let compObj = try runFpcalc(["-json", url.path])
        let rawValues = (rawObj["fingerprint"] as? [NSNumber]) ?? []
        let raw = rawValues.map { UInt32(truncatingIfNeeded: $0.int64Value) }
        let duration = (rawObj["duration"] as? NSNumber)?.doubleValue ?? (compObj["duration"] as? NSNumber)?.doubleValue ?? 0
        let compressed = compObj["fingerprint"] as? String ?? ""
        guard !raw.isEmpty else { throw FingerprintError.failed("tomt fingerprint") }
        return Fingerprint(raw: raw, compressed: compressed, duration: duration)
    }

    /// Finder den forskydning hvor flest elementer matcher, og måler dækningen.
    static func compare(_ a: [UInt32], _ b: [UInt32]) -> FingerprintComparison {
        let na = a.count, nb = b.count
        guard na > 0, nb > 0 else { return FingerprintComparison(coverageLong: 0, coverageShort: 0, offset: 0, similarity: 0) }
        var bestGood = -1
        var bestOffset = 0
        var bestBits = 0
        var bestN = 0
        for off in (-(nb - 1))..<na {
            let i0 = max(0, off), j0 = max(0, -off)
            let n = min(na - i0, nb - j0)
            if n <= 0 || n <= bestGood { continue }   // kan ikke slå det bedste
            var good = 0
            var bits = 0
            for k in 0..<n {
                let d = (a[i0 + k] ^ b[j0 + k]).nonzeroBitCount
                bits += d
                if d <= bitThreshold { good += 1 }
            }
            if good > bestGood {
                bestGood = good
                bestOffset = off
                bestBits = bits
                bestN = n
            }
        }
        let sim = bestN > 0 ? 1 - Double(bestBits) / Double(32 * bestN) : 0
        return FingerprintComparison(
            coverageLong: Double(bestGood) / Double(max(na, nb)),
            coverageShort: Double(bestGood) / Double(min(na, nb)),
            offset: bestOffset,
            similarity: sim
        )
    }

    /// Er de to filer præcis samme optagelse? (samme sang, samme version, ±3 s)
    static func verdict(_ a: Fingerprint, _ b: Fingerprint) -> (RecordingVerdict, FingerprintComparison) {
        let c = compare(a.raw, b.raw)
        let durDiff = abs(a.duration - b.duration)
        if c.coverageLong >= sameCoverage && durDiff <= durationTolerance {
            return (.same, c)
        }
        if c.coverageShort >= sameCoverage {
            let d = Int((b.duration - a.duration).rounded())
            return (.otherVersion("Samme sang, men en anden version (\(d > 0 ? "+" : "")\(d) s, \(c.percent) % match)"), c)
        }
        return (.different("Ikke samme sang (kun \(c.percent) % match)"), c)
    }
}
