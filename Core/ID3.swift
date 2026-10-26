// MODULR – kerne: ID3-tags (v2.3/v2.4) med artwork, skrevet i MP3, WAV ("id3 "-chunk) og AIFF ("ID3 "-chunk).
// Pioneer CDJ: artwork skal være indlejret, kun JPEG, maks. 800×800.
// Kun Foundation.

import Foundation

enum TagError: LocalizedError {
    case unsupported(String)
    case unreadableTag
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let f): return "Formatet \(f) understøttes ikke"
        case .unreadableTag: return "Filens eksisterende tag kunne ikke læses – intet er ændret"
        case .corrupt(let m): return "Filen ser ud til at være beskadiget (\(m)) – intet er ændret"
        }
    }
}

enum ID3 {
    struct Frame: Equatable {
        var id: String
        var flags: UInt16 = 0
        var data: Data
    }

    // MARK: Byg

    static func textFrame(_ id: String, _ text: String) -> Frame {
        var d = Data([0x01, 0xFF, 0xFE])                     // UTF-16 med BOM (gyldig i v2.3 og v2.4)
        d.append(text.data(using: .utf16LittleEndian) ?? Data())
        return Frame(id: id, data: d)
    }

    /// Forside-billede (type 3), JPEG.
    static func pictureFrame(jpeg: Data) -> Frame {
        var d = Data([0x00])                                  // ISO-8859-1 for MIME/beskrivelse
        d.append("image/jpeg".data(using: .isoLatin1)!)
        d.append(0x00)
        d.append(0x03)                                        // front cover
        d.append(0x00)                                        // tom beskrivelse
        d.append(jpeg)
        return Frame(id: "APIC", data: d)
    }

    static func syncsafe(_ v: Int) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    static func bigEndian(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    static func build(frames: [Frame], version: UInt8 = 3) -> Data {
        var body = Data()
        for f in frames {
            guard let idData = f.id.data(using: .ascii), idData.count == 4 else { continue }
            body.append(idData)
            body.append(contentsOf: version == 4 ? syncsafe(f.data.count) : bigEndian(f.data.count))
            body.append(UInt8(f.flags >> 8))
            body.append(UInt8(f.flags & 0xFF))
            body.append(f.data)
        }
        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [version, 0x00, 0x00])
        tag.append(contentsOf: syncsafe(body.count))
        tag.append(body)
        return tag
    }

    // MARK: Læs

    static func readSyncsafe(_ d: Data, _ at: Int) -> Int {
        let b = [UInt8](d[d.startIndex + at ..< d.startIndex + at + 4])
        return (Int(b[0]) << 21) | (Int(b[1]) << 14) | (Int(b[2]) << 7) | Int(b[3])
    }

    static func readBigEndian(_ d: Data, _ at: Int) -> Int {
        let b = [UInt8](d[d.startIndex + at ..< d.startIndex + at + 4])
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }

    /// Samlet længde af et ID3v2-tag der starter i begyndelsen af `d` (header + krop), ellers nil.
    static func tagLength(_ d: Data) -> Int? {
        guard d.count >= 10, d.prefix(3) == Data("ID3".utf8) else { return nil }
        let footer = (d[d.startIndex + 5] & 0x10) != 0 ? 10 : 0
        return 10 + readSyncsafe(d, 6) + footer
    }

    /// Læser frames fra et v2.3/v2.4-tag. nil hvis tagget ikke kan læses sikkert.
    static func parse(_ tag: Data) -> (version: UInt8, frames: [Frame])? {
        let d = Data(tag)
        guard d.count >= 10, d.prefix(3) == Data("ID3".utf8) else { return nil }
        let version = d[3]
        let flags = d[5]
        guard version == 3 || version == 4 else { return nil }
        guard flags & 0x80 == 0 else { return nil }          // unsynchronisation – rør det ikke
        let size = readSyncsafe(d, 6)
        let end = min(d.count, 10 + size)
        var pos = 10
        if flags & 0x40 != 0 {                                // extended header
            guard pos + 4 <= end else { return nil }
            let ext = version == 4 ? readSyncsafe(d, pos) : readBigEndian(d, pos) + 4
            pos += ext
        }
        var frames = [Frame]()
        while pos + 10 <= end {
            if d[pos] == 0 { break }                           // padding
            guard let id = String(data: d[pos..<pos + 4], encoding: .ascii),
                  id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
            let fsize = version == 4 ? readSyncsafe(d, pos + 4) : readBigEndian(d, pos + 4)
            let fflags = UInt16(d[pos + 8]) << 8 | UInt16(d[pos + 9])
            let start = pos + 10
            guard fsize >= 0, start + fsize <= end else { return nil }
            frames.append(Frame(id: id, flags: fflags, data: Data(d[start..<start + fsize])))
            pos = start + fsize
        }
        return (version, frames)
    }

    static func text(of frame: Frame) -> String? {
        guard frame.id.hasPrefix("T"), let enc = frame.data.first else { return nil }
        let body = frame.data.dropFirst()
        let s: String?
        switch enc {
        case 0: s = String(data: body, encoding: .isoLatin1)
        case 1: s = String(data: body, encoding: .utf16)
        case 2: s = String(data: body, encoding: .utf16BigEndian)
        default: s = String(data: body, encoding: .utf8)
        }
        return s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Billeddata fra en APIC-frame.
    static func pictureData(_ frame: Frame) -> Data? {
        guard frame.id == "APIC" else { return nil }
        let b = [UInt8](frame.data)
        guard let enc = b.first else { return nil }
        var i = 1
        while i < b.count && b[i] != 0 { i += 1 }            // MIME-type
        i += 2                                                // 0-terminator + billedtype
        if enc == 1 || enc == 2 {                             // UTF-16-beskrivelse slutter med 00 00
            while i + 1 < b.count && !(b[i] == 0 && b[i + 1] == 0) { i += 2 }
            i += 2
        } else {
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        guard i < b.count else { return nil }
        return Data(b[i...])
    }

    /// Lægger nye frames ind i et eksisterende tag (samme ID erstattes; APIC erstatter alle billeder).
    static func merge(existing: Data?, newFrames: [Frame]) throws -> Data {
        var version: UInt8 = 3
        var frames = [Frame]()
        if let existing {
            guard let parsed = parse(existing) else { throw TagError.unreadableTag }
            version = parsed.version
            frames = parsed.frames
        }
        let replaceIDs = Set(newFrames.map(\.id))
        frames.removeAll { replaceIDs.contains($0.id) }
        frames.append(contentsOf: newFrames)
        return build(frames: frames, version: version)
    }
}

// MARK: - Skriv tags i filer

enum AudioTagger {
    enum Container { case mp3, wav, aiff }

    static func container(of url: URL, header: Data) -> Container? {
        if header.count >= 12, header.prefix(4) == Data("RIFF".utf8), header[8..<12] == Data("WAVE".utf8) { return .wav }
        if header.count >= 12, header.prefix(4) == Data("FORM".utf8),
           header[8..<12] == Data("AIFF".utf8) || header[8..<12] == Data("AIFC".utf8) { return .aiff }
        if url.pathExtension.lowercased() == "mp3" { return .mp3 }
        return nil
    }

    /// Lægger frames (fx artwork) ind i filen. Skriver til en midlertidig fil og udskifter den
    /// først når alt er gået godt, så originalen aldrig efterlades halvt skrevet.
    static func setFrames(_ newFrames: [ID3.Frame], on url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let kind = container(of: url, header: data.prefix(12)) else {
            throw TagError.unsupported(url.pathExtension.uppercased())
        }
        let out: Data
        switch kind {
        case .mp3:
            let existingLength = ID3.tagLength(data)
            let existing = existingLength.map { Data(data.prefix($0)) }
            let tag = try ID3.merge(existing: existing, newFrames: newFrames)
            var d = tag
            d.append(data.dropFirst(existingLength ?? 0))
            out = d
        case .wav, .aiff:
            out = try rewriteChunks(data, bigEndian: kind == .aiff, newFrames: newFrames)
        }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".modulr-\(UUID().uuidString).tmp")
        try out.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    static func readUInt32(_ d: Data, _ at: Int, bigEndian: Bool) -> Int {
        let b = [UInt8](d[d.startIndex + at ..< d.startIndex + at + 4])
        if bigEndian { return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3]) }
        return (Int(b[3]) << 24) | (Int(b[2]) << 16) | (Int(b[1]) << 8) | Int(b[0])
    }

    static func uint32Bytes(_ v: Int, bigEndian: Bool) -> [UInt8] {
        let be = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return bigEndian ? be : be.reversed()
    }

    /// Alle chunks i en RIFF/FORM-fil: (id, start på data, længde).
    static func chunks(_ d: Data, bigEndian: Bool) throws -> [(id: String, start: Int, size: Int)] {
        var out = [(id: String, start: Int, size: Int)]()
        var pos = 12
        while pos + 8 <= d.count {
            guard let id = String(data: d[d.startIndex + pos ..< d.startIndex + pos + 4], encoding: .ascii) else {
                throw TagError.corrupt("ulæselig chunk")
            }
            let size = readUInt32(d, pos + 4, bigEndian: bigEndian)
            let start = pos + 8
            // Sidste chunk må være afkortet (sker i praksis), men aldrig negativ
            let usable = min(size, d.count - start)
            guard usable >= 0 else { throw TagError.corrupt("chunk-størrelse") }
            out.append((id, start, usable))
            pos = start + size + (size % 2)
        }
        return out
    }

    static func rewriteChunks(_ d: Data, bigEndian: Bool, newFrames: [ID3.Frame]) throws -> Data {
        let list = try chunks(d, bigEndian: bigEndian)
        guard list.contains(where: { $0.id == (bigEndian ? "SSND" : "data") }) else {
            throw TagError.corrupt("ingen lyd-chunk")
        }
        let isTag: (String) -> Bool = { $0 == "id3 " || $0 == "ID3 " }
        let existing = list.first { isTag($0.id) }.map { Data(d[d.startIndex + $0.start ..< d.startIndex + $0.start + $0.size]) }
        let tag = try ID3.merge(existing: existing, newFrames: newFrames)

        var out = Data(d.prefix(12))
        for c in list where !isTag(c.id) {
            out.append(Data(c.id.utf8))
            out.append(contentsOf: uint32Bytes(c.size, bigEndian: bigEndian))
            out.append(d[d.startIndex + c.start ..< d.startIndex + c.start + c.size])
            if c.size % 2 == 1 { out.append(0) }
        }
        out.append(Data((bigEndian ? "ID3 " : "id3 ").utf8))
        out.append(contentsOf: uint32Bytes(tag.count, bigEndian: bigEndian))
        out.append(tag)
        if tag.count % 2 == 1 { out.append(0) }
        // Opdatér samlet størrelse i RIFF/FORM-headeren
        let total = out.count - 8
        out.replaceSubrange(4..<8, with: uint32Bytes(total, bigEndian: bigEndian))
        return out
    }

    /// Læser det indlejrede ID3-tag (MP3: i starten, WAV/AIFF: i chunken).
    static func readTag(of url: URL) throws -> Data? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let kind = container(of: url, header: data.prefix(12)) else { return nil }
        switch kind {
        case .mp3:
            return ID3.tagLength(data).map { Data(data.prefix($0)) }
        case .wav, .aiff:
            let list = try chunks(data, bigEndian: kind == .aiff)
            return list.first { $0.id == "id3 " || $0.id == "ID3 " }
                .map { Data(data[data.startIndex + $0.start ..< data.startIndex + $0.start + $0.size]) }
        }
    }
}
