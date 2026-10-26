// MODULR – skærmbilledet "Find bedre version".

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FindBetterToolView: View {
    @EnvironmentObject var model: FindBetterModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Vælg en sang…") { pick() }
                    .buttonStyle(.borderedProminent)
                if let f = model.file {
                    Text(f.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.file != nil {
                    Button("Start forfra") { model.reset() }
                }
            }
            .padding(10)
            .background(Color.graphite)
            Divider()

            if model.file == nil {
                VStack(spacing: 14) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 54))
                        .foregroundColor(.ember)
                    Text("Træk en sang herind")
                        .font(.title2)
                    Text("MODULR genkender præcis den sang og finder steder, hvor kunstneren eller labelet selv giver den gratis i bedre kvalitet. Kun officielle kilder – ingen stream-ripping.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(dropTargeted ? Color.ember.opacity(0.12) : Color.void)
            } else {
                StepBar(current: model.step, busy: model.busy)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let e = model.errorText {
                            Banner(text: e, color: .red)
                        }
                        if let m = model.message {
                            HStack(spacing: 8) {
                                if model.busy { ProgressView().controlSize(.small) }
                                Text(m).foregroundStyle(.secondary)
                            }
                        }
                        if let q = model.original {
                            Card(title: "Din fil") {
                                HStack {
                                    Text(q.label)
                                    Spacer()
                                    ScoreBadge(score: q.score)
                                }
                            }
                        }
                        IdentitySection()
                        if !model.sources.isEmpty {
                            Card(title: "Kilder") {
                                ForEach(model.sources) { s in
                                    HStack {
                                        Image(systemName: s.ok == nil ? "clock" : (s.ok! ? "checkmark.circle" : "minus.circle"))
                                            .foregroundColor(s.ok == true ? .ember : .secondary)
                                        Text(s.kind.title).frame(width: 110, alignment: .leading)
                                        Text(s.text).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if let r = model.result {
                            ResultCard(result: r)
                        }
                        if !model.rejections.isEmpty {
                            Card(title: "Afvist og slettet") {
                                ForEach(model.rejections, id: \.self) { Text("⛔️ " + $0).font(.callout) }
                            }
                        }
                        if model.step.map({ $0.rawValue >= FBStep.candidates.rawValue }) == true && model.result == nil {
                            CandidateList()
                        }
                        if model.nothingBetter || (!model.purchaseLinks.isEmpty && model.result == nil && model.step == .candidates) {
                            PurchaseSection()
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.start(file: url) } }
            }
            return true
        }
        .sheet(item: $model.gateTicket) { ticket in
            GateBrowserSheet(ticket: ticket,
                             onFile: { file, source, title in model.browserDownloaded(file: file, sourceURL: source, ticket: ticket, pageTitle: title) },
                             onClose: { model.gateClosed() })
        }
        .alert("Åbn download-gate?", isPresented: Binding(
            get: { model.pendingGateCandidate != nil },
            set: { if !$0 { model.pendingGateCandidate = nil } }
        )) {
            Button("Åbn") {
                if let page = model.pendingGateCandidate?.page { model.openGate(page) }
            }
            Button("Annullér", role: .cancel) { model.pendingGateCandidate = nil }
        } message: {
            Text("Siden åbner i MODULRs browser. Du gennemfører selv trinene (fx follow eller e-mail). MODULR klikker ikke for dig og fanger kun filen, siden selv giver dig.")
        }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        if panel.runModal() == .OK, let url = panel.url { model.start(file: url) }
    }
}

// MARK: - Dele

struct StepBar: View {
    let current: FBStep?
    let busy: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FBStep.allCases) { s in
                let done = (current?.rawValue ?? -1) > s.rawValue
                let active = current == s
                HStack(spacing: 4) {
                    if active && busy { ProgressView().controlSize(.mini) }
                    else if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    Text(s.title).font(.system(size: 11, weight: active ? .semibold : .regular))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .foregroundColor(active ? .void : (done ? .mist : .secondary))
                .background(Capsule().fill(active ? Color.ember : (done ? Color.ember.opacity(0.25) : Color.graphite)))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.void)
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(2)
                .foregroundColor(.ember)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.graphite))
    }
}

struct Banner: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.18)))
    }
}

struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)/100")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(score >= 88 ? Color.ember : (score >= 65 ? Color.amber.opacity(0.5) : Color.red.opacity(0.4))))
            .foregroundColor(score >= 88 ? .void : .mist)
    }
}

struct IdentitySection: View {
    @EnvironmentObject var model: FindBetterModel
    @State private var artist = ""
    @State private var title = ""
    @State private var version = ""
    @State private var loadedFor: TrackIdentity?

    var body: some View {
        if model.needsIdentityChoice {
            Card(title: "Hvilken sang er det?") {
                if let note = model.identityNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if model.identityOptions.count > 1 {
                    Text("Lyden og filens tags er uenige. Vælg den rigtige:")
                        .font(.callout)
                }
                ForEach(model.identityOptions) { opt in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.identity.displayName)
                            Text("\(opt.source)\(opt.fromFingerprint ? " (fingerprint)" : "") · \(Int(opt.confidence * 100)) %")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Brug denne") { model.confirmIdentity(opt.identity) }
                    }
                }
                Divider()
                Text("Eller ret oplysningerne selv:").font(.callout)
                HStack {
                    TextField("Kunstner", text: $artist)
                    TextField("Titel", text: $title)
                    TextField("Version (fx Extended Mix)", text: $version)
                }
                .textFieldStyle(.roundedBorder)
                Button("Søg med disse oplysninger") {
                    var id = model.identity ?? TrackIdentity(title: "", artists: [], duration: 0)
                    id.artists = TextMatch.splitArtists(artist)
                    id.title = title
                    id.version = version.isEmpty ? nil : version
                    id.musicBrainzID = nil
                    model.confirmIdentity(id)
                }
                .disabled(title.isEmpty || artist.isEmpty)
            }
            .onAppear { load() }
        } else if let id = model.identity {
            Card(title: "Sangen") {
                Text(id.displayName).font(.headline)
                HStack(spacing: 12) {
                    Text(String(format: "%d:%02d", Int(id.duration) / 60, Int(id.duration) % 60))
                    if let isrc = id.isrc { Text("ISRC \(isrc)") }
                    if id.musicBrainzID != nil { Text("MusicBrainz ✓") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let note = model.identityNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func load() {
        guard let id = model.identity, loadedFor != id else { return }
        loadedFor = id
        artist = id.artists.joined(separator: ", ")
        title = id.title
        version = id.version ?? ""
    }
}

struct CandidateList: View {
    @EnvironmentObject var model: FindBetterModel

    var body: some View {
        Card(title: "Kandidater") {
            if model.candidates.isEmpty {
                Text("Ingen gratis versioner af præcis denne sang blev fundet i de officielle kilder.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.candidates) { c in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(c.raw.artist) – \(c.raw.title)").lineLimit(1)
                        HStack(spacing: 6) {
                            Chip(text: c.raw.source.title)
                            Chip(text: c.raw.kind.title, strong: c.raw.kind == .directDownload)
                            if let f = c.raw.format { Chip(text: f) }
                            Chip(text: "Ikke verificeret – tjekkes efter download", dim: true)
                        }
                        switch c.match {
                        case .match(let s):
                            Text("Match \(Int(s * 100)) %" + (c.raw.duration.map { " · \(Int($0)) s" } ?? " · længde ukendt"))
                                .font(.caption).foregroundStyle(.secondary)
                        case .otherVersion(let why):
                            Text("Samme sang, anden version: \(why)").font(.caption).foregroundColor(.amber)
                        case .noMatch(let why):
                            Text(why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(c.raw.kind == .directDownload ? "Hent" : "Åbn") { model.choose(c) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }
                .padding(.vertical, 4)
                Divider()
            }
            if model.hiddenOtherVersions > 0 {
                Text("\(model.hiddenOtherVersions) andre versioner (radio edit, extended, remix …) er skjult. Kan vises under Indstillinger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct Chip: View {
    let text: String
    var strong = false
    var dim = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(strong ? Color.ember : Color.void))
            .foregroundColor(strong ? .void : (dim ? .secondary : .mist))
    }
}

struct ResultCard: View {
    let result: FBResult

    var body: some View {
        Card(title: "Fundet og verificeret") {
            Text("✅ " + result.summary)
            Text(result.savedFile.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.savedFile]) }
                Button("Åbn herkomst-fil") { NSWorkspace.shared.open(result.provenanceFile) }
            }
        }
    }
}

struct PurchaseSection: View {
    @EnvironmentObject var model: FindBetterModel

    var body: some View {
        Card(title: model.nothingBetter ? "Intet gratis i bedre kvalitet" : "Kan købes her") {
            if model.nothingBetter {
                Text("Der findes ingen gratis download af præcis denne sang fra kunstneren eller labelet i de kilder, der er slået til. Her kan den købes:")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.purchaseLinks) { link in
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
        }
    }
}
