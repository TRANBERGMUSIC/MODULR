// MODULR – tests af kernelogikken. Kør med: bash run_tests.command
// (main.swift: testprogrammet kører direkte, uden @main)
//
//  • Fingerprint: samme sang i 128 vs lossless matcher; radio edit og extended afvises; anden sang afvises.
//  • Spektral cutoff på syntetiske filer: 128 / 192 / 320 / lossless / opskaleret.
//  • Kandidatfiltrering: downloadable true/false, gate-domæner, købslinks.
//  • "Kun bedre"-reglen.
//  • Politik: ingen kode-sti kan hente fra en URL der ikke kom fra en godkendt kilde.
//  • robots.txt, ID3/WAV/AIFF-artwork, Bandcamp-fortolkning, tekst-matchning.

import Foundation
import AVFoundation

var passed = 0
var failed = 0

func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
    if cond {
        passed += 1
        print("  ✅ \(name)")
    } else {
        failed += 1
        print("  ❌ \(name)  \(detail())")
    }
}

func section(_ s: String) { print("\n▶ \(s)") }

// MARK: - Syntetisk lyd

struct RNG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

let sr = 44100.0
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("modulr-tests-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func write(_ samples: [Float], to url: URL, settings: [String: Any]) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    let peak = max(0.0001, samples.map { abs($0) }.max() ?? 1)
    for c in 0..<2 {
        let ch = buf.floatChannelData![c]
        for i in 0..<samples.count { ch[i] = samples[i] / peak * 0.9 }
    }
    let f = try AVAudioFile(forWriting: url, settings: settings)
    try f.write(from: buf)
}

let wavSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
]

/// Støj med en knivskarp grænse: mange sinustoner jævnt fordelt op til `cutoff`.
func bandLimitedNoise(cutoff: Double, seconds: Double = 3, seed: UInt64 = 1) -> [Float] {
    var rng = RNG(state: seed)
    let n = Int(seconds * sr)
    let tones = 1600
    var cosW = [Double](), sinW = [Double](), x = [Double](), y = [Double]()
    for _ in 0..<tones {
        let f = 40 + rng.next() * (cutoff - 40)
        let w = 2 * Double.pi * f / sr
        cosW.append(cos(w)); sinW.append(sin(w))
        let ph = rng.next() * 2 * Double.pi
        x.append(cos(ph)); y.append(sin(ph))
    }
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        var s = 0.0
        for k in 0..<tones {
            let nx = x[k] * cosW[k] - y[k] * sinW[k]
            let ny = x[k] * sinW[k] + y[k] * cosW[k]
            x[k] = nx; y[k] = ny
            s += ny
        }
        out[i] = Float(s / sqrt(Double(tones)))
    }
    return out
}

/// En lille "sang": akkorder, melodi, kick og hihat.
func song(seed: UInt64, bars: Int, bpm: Double = 124) -> [Float] {
    var rng = RNG(state: seed)
    let beat = 60 / bpm
    let roots = (0..<8).map { _ in Int(rng.next() * 12) }
    let barLen = Int(sr * beat * 4)
    var out = [Float]()
    out.reserveCapacity(barLen * bars)
    for b in 0..<bars {
        let r = roots[b % 8]
        let mel = [0, 3, 5, 7, 10][b % 5]
        for i in 0..<barLen {
            let t = Double(i) / sr
            var s = 0.0
            for k in [0, 4, 7, 12] {
                s += 0.12 * sin(2 * .pi * 220 * pow(2, Double(r + k) / 12) * t) * exp(-0.3 * t)
            }
            s += 0.1 * sin(2 * .pi * 220 * pow(2, Double(r + mel + 12) / 12) * t)
            let inBeat = t.truncatingRemainder(dividingBy: beat)
            if inBeat < 0.05 { s += 0.4 * sin(2 * .pi * 55 * inBeat) * exp(-inBeat * 44100 / 800) }
            s += (rng.next() - 0.5) * 0.06
            out.append(Float(s))
        }
    }
    return out
}

// MARK: - Tekst og matchning

section("Tekst-matchning")
do {
    let a = TextMatch.splitVersion("Losing It (Original Mix)")
    check("Original Mix tæller som ingen version", a.base == "Losing It" && TextMatch.normalizeVersion(a.version) == nil, "\(a)")
    let b = TextMatch.splitVersion("Losing It (Extended Mix)")
    check("Extended Mix → version 'extended'", TextMatch.normalizeVersion(b.version) == "extended", "\(b)")
    let c = TextMatch.splitVersion("Tension (feat. Someone) [Radio Edit]")
    check("feat fjernes, Radio Edit bliver version", c.base == "Tension" && TextMatch.normalizeVersion(c.version) == "radio edit", "\(c)")
    check("Accenter og & normaliseres", TextMatch.normalize("Beyoncé & Jay-Z") == "beyonce and jay z")
    check("Fuzzy lighed ≥ 0,9 ved stavefejl", TextMatch.similarity("Loosing It", "Losing It") >= 0.9)
    check("Forskellige titler < 0,9", TextMatch.similarity("Losing It", "Stop It") < 0.9)

    let id = TrackIdentity(title: "Losing It", artists: ["FISHER"], version: nil, duration: 245)
    check("Samme sang matcher", Matcher.evaluate(rawTitle: "Losing It (Original Mix)", rawArtist: "FISHER", duration: 246, isrc: nil, against: id).isMatch)
    check("Label-upload 'Kunstner - Titel' matcher", Matcher.evaluate(rawTitle: "FISHER - Losing It", rawArtist: "Catch & Release", duration: 244, isrc: nil, against: id).isMatch)
    check("Radio edit afvises som anden version", Matcher.evaluate(rawTitle: "Losing It (Radio Edit)", rawArtist: "FISHER", duration: 180, isrc: nil, against: id).isOtherVersion)
    check("Extended (+60 s) afvises som anden version", Matcher.evaluate(rawTitle: "Losing It", rawArtist: "FISHER", duration: 305, isrc: nil, against: id).isOtherVersion)
    check("Anden sang afvises", !Matcher.evaluate(rawTitle: "Stop It", rawArtist: "FISHER", duration: 245, isrc: nil, against: id).isMatch)
    check("Anden kunstner afvises", !Matcher.evaluate(rawTitle: "Losing It", rawArtist: "Someone Else", duration: 245, isrc: nil, against: id).isMatch)
}

// MARK: - Fingerprint

section("Fingerprint-sammenligning (rene data)")
do {
    var rng = RNG(state: 7)
    let a = (0..<1500).map { _ in UInt32(truncatingIfNeeded: Int(rng.next() * 4_294_967_295)) }
    check("Identisk = 100 % dækning", Fingerprinter.compare(a, a).coverageLong > 0.99)
    let sub = Array(a[300..<900])
    let c = Fingerprinter.compare(a, sub)
    check("Udsnit: kort fil dækket, lang fil ikke", c.coverageShort > 0.99 && c.coverageLong < 0.5, "\(c)")
    let other = (0..<1500).map { _ in UInt32(truncatingIfNeeded: Int(rng.next() * 4_294_967_295)) }
    check("Tilfældig anden fil < 10 %", Fingerprinter.compare(a, other).coverageLong < 0.1)
}

section("Fingerprint på rigtig lyd (fpcalc)")
if Fingerprinter.fpcalcPath() == nil {
    print("  ⚠️ fpcalc ikke fundet – installér MODULR først (Installer.command henter den). Springer over.")
} else {
    do {
        print("  (genererer testsange – tager lidt tid)")
        let A = song(seed: 1, bars: 96)
        let intro = song(seed: 5, bars: 32)
        let B = song(seed: 2, bars: 96)
        let radio = Array(A[0..<Int(Double(A.count) * 0.55)]) + song(seed: 1, bars: 8)
        let aWav = tmp.appendingPathComponent("A.wav")
        let aAac = tmp.appendingPathComponent("A_128.m4a")
        let ext = tmp.appendingPathComponent("A_extended.wav")
        let rad = tmp.appendingPathComponent("A_radio.wav")
        let bWav = tmp.appendingPathComponent("B.wav")
        try write(A, to: aWav, settings: wavSettings)
        try write(A, to: aAac, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr,
                                          AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        try write(intro + A, to: ext, settings: wavSettings)
        try write(radio, to: rad, settings: wavSettings)
        try write(B, to: bWav, settings: wavSettings)

        let fA = try Fingerprinter.fingerprint(of: aWav)
        let (v1, c1) = Fingerprinter.verdict(fA, try Fingerprinter.fingerprint(of: aAac))
        check("Samme sang i 128 kbps vs lossless → samme", v1 == .same, "\(v1) \(c1)")
        let (v2, c2) = Fingerprinter.verdict(fA, try Fingerprinter.fingerprint(of: ext))
        check("Extended version → afvist (anden version)", v2 != .same, "\(v2) \(c2)")
        let (v3, c3) = Fingerprinter.verdict(fA, try Fingerprinter.fingerprint(of: rad))
        check("Radio edit → afvist (anden version)", v3 != .same, "\(v3) \(c3)")
        let (v4, c4) = Fingerprinter.verdict(fA, try Fingerprinter.fingerprint(of: bWav))
        if case .different = v4 { check("Anden sang → afvist", true) } else { check("Anden sang → afvist", false, "\(v4) \(c4)") }
    } catch {
        check("Fingerprint-test kørte", false, error.localizedDescription)
    }
}

// MARK: - Spektral cutoff

section("Spektral cutoff på syntetiske filer")
do {
    let cases: [(String, Double, Int)] = [
        ("128 kbps (16,9 kHz)", 16900, 128),
        ("192 kbps (18,7 kHz)", 18700, 192),
        ("320 kbps (20,4 kHz)", 20400, 320),
        ("lossless (fuld båndbredde)", 21950, 9999),
    ]
    for (name, cutoff, expected) in cases {
        let url = tmp.appendingPathComponent("cut-\(Int(cutoff)).wav")
        try write(bandLimitedNoise(cutoff: cutoff), to: url, settings: wavSettings)
        let r = try Analyzer.analyze(url: url)
        check("\(name) → \(expected == 9999 ? "fuld" : "\(expected)")", r.tier.kbps == expected,
              "målt \(r.cutoffHz.map { String(Int($0)) } ?? "ingen kant") → \(r.tier.label)")
    }
    // Opskaleret: WAV der reelt er 128 kbps
    let up = tmp.appendingPathComponent("upscaled.wav")
    try write(bandLimitedNoise(cutoff: 16200, seed: 9), to: up, settings: wavSettings)
    let (q, _) = try Analyzer.quality(url: up)
    check("WAV med 16 kHz-kant flages som opskaleret", q.upscaled && q.label.contains("lyder som"), q.label)
} catch {
    check("Cutoff-test kørte", false, error.localizedDescription)
}

// MARK: - Kun bedre

section("\"Kun bedre\"-reglen")
do {
    func q(_ codec: String, _ kbps: Int?, tier: Int) -> QualityReport {
        Quality.make(format: FormatInfo(codec: codec, container: codec, nominalKbps: kbps, sampleRate: 44100, bitDepth: codec == "WAV" ? 16 : nil, channels: 2),
                     cutoffHz: nil, tierKbps: tier, tierLabel: tier >= 9999 ? "Fuld båndbredde" : "\(tier) kbps")
    }
    let mp3_128 = q("MP3", 128, tier: 128)
    let mp3_320 = q("MP3", 320, tier: 320)
    let fake320 = q("MP3", 320, tier: 128)
    let wav = q("WAV", 1411, tier: 9999)
    let fakeWav = q("WAV", 1411, tier: 128)
    check("320 er bedre end 128", Quality.isBetter(mp3_320, than: mp3_128, rule: .realTier).better)
    check("Ægte WAV er bedre end 320", Quality.isBetter(wav, than: mp3_320, rule: .realTier).better)
    check("320 vs 320 → samme kvalitet, afvist", !Quality.isBetter(mp3_320, than: mp3_320, rule: .realTier).better)
    check("Fake 320 (reelt 128) er ikke bedre end 128", !Quality.isBetter(fake320, than: mp3_128, rule: .realTier).better)
    let r = Quality.isBetter(fakeWav, than: mp3_128, rule: .realTier)
    check("Opskaleret WAV afvises med begrundelse", !r.better && r.reason.contains("Opskaleret"), r.reason)
    check("Label for ægte fil", mp3_320.label == "MP3 320 kbps, ægte", mp3_320.label)
    check("Label for falsk lossless", fakeWav.label.contains("men lyder som 128"), fakeWav.label)
}

// MARK: - Politik

section("Kildepolitik – kun godkendte kilder")
do {
    let ok = SourcePolicy.approveSoundCloudDownload(downloadable: true, downloadURL: "https://api.soundcloud.com/tracks/123/download")
    check("SoundCloud downloadable=true godkendes", ok != nil)
    check("downloadable=false afvises", SourcePolicy.approveSoundCloudDownload(downloadable: false, downloadURL: "https://api.soundcloud.com/tracks/123/download") == nil)
    check("api-v2 afvises", SourcePolicy.approveSoundCloudDownload(downloadable: true, downloadURL: "https://api-v2.soundcloud.com/tracks/123/download") == nil)
    check("Stream-URL afvises", SourcePolicy.approveSoundCloudDownload(downloadable: true, downloadURL: "https://api.soundcloud.com/tracks/123/stream") == nil)
    check("http (ikke https) afvises", SourcePolicy.approveSoundCloudDownload(downloadable: true, downloadURL: "http://api.soundcloud.com/tracks/123/download") == nil)
    check("Anden vært afvises", SourcePolicy.approveSoundCloudDownload(downloadable: true, downloadURL: "https://evil.example/tracks/123/download") == nil)
    check("HLS-playliste er forbudt", SourcePolicy.isForbidden(URL(string: "https://cf-hls-media.sndcdn.com/playlist/x.m3u8")!))

    let artist = ["fisher.com"]
    func page(_ s: String, _ src: SourceKind = .webSearch) -> ApprovedPage? { SourcePolicy.approvePage(URL(string: s)!, source: src, artistDomains: artist) }
    check("Hypeddit godkendes som gate", page("https://hypeddit.com/fisher/losingit")?.source == .gate)
    check("ToneDen godkendes som gate", page("https://toneden.io/fisher/post/losing-it")?.source == .gate)
    check("Bandcamp-underdomæne godkendes", page("https://fisher.bandcamp.com/track/losing-it")?.source == .bandcamp)
    check("Kunstnerens eget domæne godkendes", page("https://www.fisher.com/free")?.source == .artistSite)
    check("YouTube afvises", page("https://www.youtube.com/watch?v=x") == nil)
    check("Filehost afvises", page("https://www.mediafire.com/file/x") == nil)
    check("Tilfældig mp3-side afvises", page("https://free-mp3-download.example/fisher") == nil)
    check("soundcloud.com kun via SoundCloud-API'et", page("https://soundcloud.com/fisher/losing-it") == nil &&
          page("https://soundcloud.com/fisher/losing-it", .soundcloud) != nil)
    check("Dropbox tæller aldrig som kunstnerens domæne",
          SourcePolicy.approvePage(URL(string: "https://dropbox.com/s/x")!, source: .webSearch, artistDomains: ["dropbox.com"]) == nil)

    // Cachede data kan ikke omgå politikken – de godkendes igen ved brug
    let id = TrackIdentity(title: "Losing It", artists: ["FISHER"], duration: 245)
    let bad = RawCandidate(source: .soundcloud, kind: .directDownload, title: "Losing It", artist: "FISHER", duration: 245,
                           isrc: nil, pageURL: "https://soundcloud.com/x", downloadURL: "https://api-v2.soundcloud.com/tracks/1/download",
                           downloadable: true, format: nil, license: nil, price: nil)
    check("Manipuleret cache-kandidat (api-v2) afvises", CandidateBuilder.approve(bad, identity: id, artistDomains: []) == nil)
    let badGate = RawCandidate(source: .gate, kind: .gate, title: "Losing It", artist: "FISHER", duration: nil, isrc: nil,
                               pageURL: "https://www.mediafire.com/x", downloadURL: nil, downloadable: false,
                               format: nil, license: nil, price: nil)
    check("Manipuleret cache-gate (filehost) afvises", CandidateBuilder.approve(badGate, identity: id, artistDomains: []) == nil)

    let ticket = SourcePolicy.startSession(for: page("https://hypeddit.com/fisher/losingit")!)
    check("Browser-download fra gate godkendes", SourcePolicy.approveBrowserDownload(fileSourceURL: URL(string: "https://cdn.hypeddit.com/f.wav"), ticket: ticket) != nil)
    check("Browser-download fra forbudt vært afvises", SourcePolicy.approveBrowserDownload(fileSourceURL: URL(string: "https://mega.nz/file/x"), ticket: ticket) == nil)
    check("YouTube må besøges i gate-browseren", !SourcePolicy.isBlockedForBrowsing(URL(string: "https://www.youtube.com/channel/x")!))
    check("…men aldrig hentes fra", SourcePolicy.approveBrowserDownload(fileSourceURL: URL(string: "https://www.youtube.com/x.mp3"), ticket: ticket) == nil)
    check("Filehost blokeres også i browseren", SourcePolicy.isBlockedForBrowsing(URL(string: "https://mega.nz/file/x")!))
    check("about:blank blokeres ikke", !SourcePolicy.isBlockedForBrowsing(URL(string: "about:blank")!))
    print("  ℹ️ ApprovedDownload/ApprovedPage/GateSessionTicket kan kun oprettes i Policy.swift (fileprivate init),")
    print("     og HTTP.download tager kun en ApprovedDownload – det er sikret af compileren.")
}

// MARK: - Kandidater

section("Kandidatfiltrering")
do {
    let json = """
    {"collection":[
      {"id":1,"title":"Losing It (Original Mix)","duration":245000,"downloadable":true,"download_url":"https://api.soundcloud.com/tracks/1/download","permalink_url":"https://soundcloud.com/fisher/losing-it","user":{"username":"FISHER"}},
      {"id":2,"title":"Losing It","duration":245500,"downloadable":false,"purchase_url":"https://hypeddit.com/fisher/losingit","user":{"username":"FISHER"}},
      {"id":3,"title":"Losing It","duration":245000,"downloadable":false,"purchase_url":"https://www.beatport.com/track/losing-it/1","purchase_title":"Beatport","user":{"username":"FISHER"}},
      {"id":4,"title":"Losing It (Radio Edit)","duration":180000,"downloadable":true,"download_url":"https://api.soundcloud.com/tracks/4/download","user":{"username":"FISHER"}},
      {"id":5,"title":"Losing It","duration":245000,"downloadable":false,"description":"Free DL: https://toneden.io/fisher/post/x and https://www.mediafire.com/f","user":{"username":"FISHER"}}
    ],"next_href":null}
    """
    let pageObj = try JSONDecoder().decode(CandidateBuilder.SCPage.self, from: Data(json.utf8))
    let raws = pageObj.collection.flatMap(CandidateBuilder.fromSoundCloud)
    let id = TrackIdentity(title: "Losing It", artists: ["FISHER"], duration: 245)
    let approved = raws.compactMap { CandidateBuilder.approve($0, identity: id, artistDomains: []) }
    check("downloadable=true giver direkte download", approved.contains { $0.raw.kind == .directDownload && $0.match.isMatch })
    let plain = try JSONDecoder().decode(CandidateBuilder.SCTrack.self,
                                         from: Data(#"{"id":6,"title":"Losing It","downloadable":false,"user":{"username":"FISHER"}}"#.utf8))
    check("downloadable=false uden links giver ingen kandidat", CandidateBuilder.fromSoundCloud(plain).isEmpty)
    check("purchase_url til Hypeddit bliver gate", approved.contains { $0.raw.kind == .gate && $0.raw.pageURL.contains("hypeddit") })
    check("purchase_url til Beatport bliver kun købslink", approved.contains { $0.raw.kind == .purchaseOnly && $0.download == nil && $0.page == nil })
    check("Gate-link i beskrivelsen findes", approved.contains { $0.raw.pageURL.contains("toneden.io") })
    check("Filehost-link i beskrivelsen ignoreres", !raws.contains { $0.pageURL.contains("mediafire") })
    let shown = CandidateBuilder.filter(approved.filter { $0.raw.kind != .purchaseOnly }, showOtherVersions: false)
    check("Radio edit skjules som standard", !shown.contains { $0.raw.title.contains("Radio Edit") })
    check("Direkte download sorteres først", shown.first?.raw.kind == .directDownload)
} catch {
    check("Kandidat-test kørte", false, error.localizedDescription)
}

section("Bandcamp-fortolkning")
do {
    let search = """
    <ul><li class="searchresult data-search">
      <div class="itemtype">TRACK</div>
      <div class="heading"><a href="https://fisher.bandcamp.com/track/losing-it?from=search&amp;x=1">Losing It</a></div>
      <div class="subhead">from Losing It EP by FISHER</div>
    </li><li class="searchresult data-search">
      <div class="itemtype">ALBUM</div>
      <div class="heading"><a href="https://fisher.bandcamp.com/album/x">Album</a></div>
    </li></ul>
    """
    let hits = CandidateBuilder.parseBandcampSearch(search)
    check("Søgeside: kun spor, URL uden query", hits.count == 1 && hits[0].url == "https://fisher.bandcamp.com/track/losing-it" && hits[0].artist == "FISHER", "\(hits)")
    func trackPage(_ json: String) -> String { "<div data-tralbum=\"\(json.replacingOccurrences(of: "\"", with: "&quot;"))\"></div>" }
    let free = CandidateBuilder.parseBandcampTrack(trackPage(#"{"artist":"FISHER","current":{"title":"Losing It","minimum_price":0.0},"freeDownloadPage":"https://bandcamp.com/download?id=1","trackinfo":[{"title":"Losing It","duration":245.1}]}"#), pageURL: "https://fisher.bandcamp.com/track/losing-it")
    check("Gratis download genkendes", free?.kind == .freeDownload && free?.pageURL == "https://bandcamp.com/download?id=1")
    let nyp = CandidateBuilder.parseBandcampTrack(trackPage(#"{"artist":"FISHER","current":{"title":"Losing It","minimum_price":0.0,"price":0.0},"freeDownloadPage":null,"trackinfo":[{"title":"Losing It","duration":245.1}]}"#), pageURL: "https://fisher.bandcamp.com/track/losing-it")
    check("Name your price genkendes", nyp?.kind == .nameYourPrice)
    let paid = CandidateBuilder.parseBandcampTrack(trackPage(#"{"artist":"FISHER","current":{"title":"Losing It","minimum_price":1.5,"price":1.5},"freeDownloadPage":null,"trackinfo":[{"title":"Losing It","duration":245.1}]}"#), pageURL: "https://fisher.bandcamp.com/track/losing-it")
    check("Betalt spor bliver kun købslink", paid?.kind == .purchaseOnly)
}

// MARK: - Artwork-bibliotek

section("Artwork-matchning")
do {
    func entry(_ a: [String], _ t: String, _ v: String?, _ w: Int = 600) -> ArtworkEntry {
        ArtworkEntry(id: UUID(), artists: a, title: t, version: v, imageFile: "x.jpg", width: w, height: w,
                     source: "test", addedAt: Date(), files: [])
    }
    let lib = [entry(["FISHER"], "Losing It", nil, 500), entry(["FISHER"], "Losing It", nil, 1400),
               entry(["FISHER"], "Losing It", "Chris Lake Remix"), entry(["Someone"], "Other Song", nil)]
    let wav = SongInfo(artist: "FISHER", rawTitle: "Losing It (Extended Mix)")!
    check("WAV (extended) får originalens cover", ArtworkMatcher.best(for: wav, in: lib)?.version == nil)
    check("Største billede vælges ved lige match", ArtworkMatcher.best(for: wav, in: lib)?.width == 1400)
    let remix = SongInfo(artist: "FISHER", rawTitle: "Losing It (Chris Lake Remix)")!
    check("Remix får remixets eget cover", ArtworkMatcher.best(for: remix, in: lib)?.version == "Chris Lake Remix")
    let otherRemix = SongInfo(artist: "FISHER", rawTitle: "Losing It (Someone Remix)")!
    check("Et andet remix får IKKE originalens cover", ArtworkMatcher.best(for: otherRemix, in: [lib[0]]) == nil)
    let fromName = SongInfo(artist: nil, rawTitle: "Losing It")!
    check("Fil uden kunstner-tag matcher på titel", ArtworkMatcher.best(for: fromName, in: lib) != nil)
    check("Anden sang matcher ikke", ArtworkMatcher.best(for: SongInfo(artist: "FISHER", rawTitle: "Stop It")!, in: lib) == nil)
    check("Samme sang genkendes til udskiftning", ArtworkMatcher.sameSong(lib[0], SongInfo(artist: "Fisher", rawTitle: "Losing It (Original Mix)")!))
}

// MARK: - robots.txt

section("robots.txt")
do {
    let r = RobotsRules.parse("""
    User-agent: *
    Disallow: /search
    Allow: /search/ok
    Disallow: /*.json$
    """)
    check("Disallow /search", !r.isAllowed("/search?q=x"))
    check("Længere Allow vinder", r.isAllowed("/search/ok/1"))
    check("Wildcard og $", !r.isAllowed("/a/b.json") && r.isAllowed("/a/b.json5"))
    check("Andre stier tilladt", r.isAllowed("/track/x"))
    let specific = RobotsRules.parse("User-agent: MODULR\nDisallow: /\n\nUser-agent: *\nDisallow:")
    check("Specifik gruppe for MODULR bruges", !specific.isAllowed("/x"))
}

// MARK: - ID3 / artwork

section("ID3 og artwork i WAV/AIFF/MP3")
do {
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: UInt8(7), count: 5000) + [0xFF, 0xD9])
    let tag = ID3.build(frames: [ID3.textFrame("TIT2", "Losing It – ø"), ID3.pictureFrame(jpeg: jpeg)])
    let parsed = ID3.parse(tag)
    check("ID3 rundtur: titel", parsed.flatMap { p in p.frames.first { $0.id == "TIT2" } }.flatMap(ID3.text) == "Losing It – ø")
    check("ID3 rundtur: billede", parsed.flatMap { p in p.frames.first { $0.id == "APIC" } }.flatMap(ID3.pictureData) == jpeg)

    // WAV
    let wav = tmp.appendingPathComponent("art.wav")
    try write(bandLimitedNoise(cutoff: 15000, seconds: 1.5), to: wav, settings: wavSettings)
    let before = try AVAudioFile(forReading: wav).length
    try AudioTagger.setFrames([ID3.pictureFrame(jpeg: jpeg)], on: wav)
    try AudioTagger.setFrames([ID3.pictureFrame(jpeg: jpeg + Data([1]))], on: wav)   // udskift
    let data = try Data(contentsOf: wav)
    let riffSize = AudioTagger.readUInt32(data, 4, bigEndian: false)
    check("WAV: RIFF-størrelse korrekt", riffSize == data.count - 8, "\(riffSize) vs \(data.count - 8)")
    let chunks = try AudioTagger.chunks(data, bigEndian: false)
    check("WAV: præcis én id3-chunk", chunks.filter { $0.id == "id3 " }.count == 1)
    let wavTag = try AudioTagger.readTag(of: wav).flatMap(ID3.parse)
    check("WAV: kun ét billede efter udskiftning", wavTag?.frames.filter { $0.id == "APIC" }.count == 1)
    check("WAV: nyeste billede gemt", wavTag?.frames.first { $0.id == "APIC" }.flatMap(ID3.pictureData) == jpeg + Data([1]))
    check("WAV: lyden er uændret og kan stadig læses", (try? AVAudioFile(forReading: wav).length) == before)

    // AIFF
    let aiff = tmp.appendingPathComponent("art.aiff")
    try write(bandLimitedNoise(cutoff: 15000, seconds: 1.5), to: aiff, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true,
    ])
    let aBefore = try AVAudioFile(forReading: aiff).length
    try AudioTagger.setFrames([ID3.pictureFrame(jpeg: jpeg)], on: aiff)
    let ad = try Data(contentsOf: aiff)
    check("AIFF: FORM-størrelse korrekt", AudioTagger.readUInt32(ad, 4, bigEndian: true) == ad.count - 8)
    check("AIFF: ID3-chunk med billede", (try AudioTagger.readTag(of: aiff)).flatMap(ID3.parse)?.frames.contains { $0.id == "APIC" } == true)
    check("AIFF: lyden er uændret", (try? AVAudioFile(forReading: aiff).length) == aBefore)

    // MP3 (kun tag-delen; lyddata efter tagget skal være uændret)
    let mp3 = tmp.appendingPathComponent("x.mp3")
    let body = Data([0xFF, 0xFB, 0x90, 0x64] + Array(repeating: UInt8(0x55), count: 2000))
    try (ID3.build(frames: [ID3.textFrame("TIT2", "Old")]) + body).write(to: mp3)
    try AudioTagger.setFrames([ID3.textFrame("TPE1", "FISHER"), ID3.pictureFrame(jpeg: jpeg)], on: mp3)
    let md = try Data(contentsOf: mp3)
    let len = ID3.tagLength(md) ?? 0
    let mt = ID3.parse(Data(md.prefix(len)))
    check("MP3: gammel titel bevaret + ny kunstner", mt?.frames.contains { $0.id == "TIT2" } == true && mt?.frames.contains { $0.id == "TPE1" } == true)
    check("MP3: lyddata uændret", Data(md.dropFirst(len)) == body)
} catch {
    check("ID3-test kørte", false, error.localizedDescription)
}

try? FileManager.default.removeItem(at: tmp)
print("\n\(passed) bestået, \(failed) fejlet")
exit(failed == 0 ? 0 : 1)
