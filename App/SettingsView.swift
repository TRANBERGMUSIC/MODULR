// MODULR – indstillinger (Cmd + ,): kilder, API-nøgler og regler.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: FBSettings

    var body: some View {
        TabView {
            Form {
                Section("Kilder") {
                    Toggle("SoundCloud (officielt API)", isOn: $settings.useSoundCloud)
                    Toggle("Bandcamp (gratis og name your price)", isOn: $settings.useBandcamp)
                    Toggle("Download-gates (Hypeddit, ToneDen, lnk.to, Fanlink)", isOn: $settings.useGates)
                    Toggle("Generel websøgning (kun gates, Bandcamp og kunstnerens egne domæner)", isOn: $settings.useWebSearch)
                }
                Text("MODULR henter aldrig fra api-v2, stream-URL'er, YouTube, filehosts eller \"mp3 download\"-sider – det er spærret i koden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("Kilder", systemImage: "antenna.radiowaves.left.and.right") }

            Form {
                Section("Genkendelse (fingerprint)") {
                    SecureField("AcoustID-nøgle (gratis på acoustid.org)", text: $settings.keys.acoustID)
                    SecureField("AudD API-token (valgfri)", text: $settings.keys.audd)
                    TextField("ACRCloud host, fx identify-eu-west-1.acrcloud.com (valgfri)", text: $settings.keys.acrHost)
                    SecureField("ACRCloud access key", text: $settings.keys.acrKey)
                    SecureField("ACRCloud access secret", text: $settings.keys.acrSecret)
                }
                Section("SoundCloud") {
                    SecureField("Client ID", text: $settings.keys.soundCloudClientID)
                    SecureField("Client secret", text: $settings.keys.soundCloudClientSecret)
                    Text(settings.soundCloudConfigured ? "Konfigureret" : "SoundCloud ikke konfigureret – API-adgang kræver ansøgning hos SoundCloud")
                        .font(.caption)
                        .foregroundColor(settings.soundCloudConfigured ? .ember : .secondary)
                }
                Section("Websøgning") {
                    SecureField("Brave Search API-nøgle (valgfri)", text: $settings.keys.brave)
                }
                Text("Nøglerne gemmes kun på denne Mac i en fil som kun din bruger kan læse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .tabItem { Label("Nøgler", systemImage: "key") }

            Form {
                Picker("Hent kun når", selection: $settings.rule) {
                    ForEach(ImprovementRule.allCases) { r in Text(r.title).tag(r) }
                }
                Toggle("Åbn gates i min egen browser (Safari/Chrome – virker med Google-login)", isOn: $settings.useSystemBrowser)
                Toggle("Spørg før en download-gate åbnes", isOn: $settings.askBeforeGate)
                Toggle("Vis også andre versioner (radio edit, extended, remix)", isOn: $settings.showOtherVersions)
            }
            .padding(20)
            .tabItem { Label("Regler", systemImage: "checklist") }

            LoudnessSettingsView()
                .padding(20)
                .tabItem { Label("Lydstyrke", systemImage: "dial.medium") }

            CueRulesSettingsView()
                .padding(20)
                .tabItem { Label("Cues", systemImage: "flag") }
        }
        .frame(width: 660, height: 520)
    }
}

/// Lydstyrke som Platinum Notes: alle sange rettes til samme niveau, så gain-knappen kan blive i midten.
struct LoudnessSettingsView: View {
    @AppStorage(LoudnessPrefs.autoKey) private var autoFix = true
    @AppStorage(LoudnessPrefs.targetKey) private var target = -10.0

    var body: some View {
        Form {
            Section("Klubniveau") {
                Toggle("Ret lydstyrken automatisk på nye sange", isOn: $autoFix)
                Slider(value: $target, in: -12 ... -6, step: 0.5) {
                    Text("Mål: \(String(format: "%.1f", target)) LUFS")
                }
                Text("−10 LUFS: samme niveau på alle sange, så gain-knappen står samme sted – med luft nok til at hårdt mastrede sange kan få slaget tilbage (dynamik-ekspansion som Platinum Notes).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sådan rettes filerne") {
                Text("WAV/AIFF: gain + en gennemsigtig limiter (top −1 dBFS, højst 5 dB dæmpning), gemt som 24-bit.")
                Text("MP3: tabsfri gain i trin på 1,5 dB – ingen genkodning, så kvaliteten forringes ikke.")
                Text("FLAC/M4A: måles, men rettes ikke.")
                Text("Originalerne gemmes i Musik/MODULR/Originaler – højreklik → \"Gendan original\".")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Ret alle sange nu") { LibraryStore.shared.fixAllLoudness() }
        }
    }
}

/// Din plan for hvor hot cues A–H skal foreslås – og hvad appen har lært af dig.
struct CueRulesSettingsView: View {
    @ObservedObject private var player = PlayerModel.shared
    @State private var learnOn: Bool = CueRules.learnEnabled
    @State private var learned = CueRules.learnedOffsets

    var body: some View {
        Form {
            Section("Hvilke dele skal have hot cues?") {
                TextField("Plan", text: $player.cuePlanText, axis: .vertical)
                    .lineLimit(2...4)
                let parsed = player.cuePlan
                if !parsed.unknown.isEmpty {
                    Text("Forstår ikke: \(parsed.unknown.joined(separator: ", "))").font(.caption).foregroundColor(.orange)
                }
                Text(parsed.parts.isEmpty ? "Ingen dele" : parsed.parts.map { CuePlan.text(for: $0) }.joined(separator: "  →  "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                Text("Skriv delene adskilt med komma: første slag, intro, groove, buildup, drop, breakdown, outro. Med nummer (drop 2, andet drop), \"alle drops\", \"sidste breakdown\" og takter (+16, \"4 takter før drop\"). Bogstaverne A–H gives altid i tidsrækkefølge – H kommer aldrig før G. Står to dele samme sted, vinder den du skrev først; er der flere end 8, beholdes de første.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Gendan standard") { player.cuePlanText = CuePlan.standard }
            }
            Section("Lær af mig") {
                Toggle("Lær hvordan jeg flytter cues", isOn: $learnOn)
                    .onChange(of: learnOn) { _, v in CueRules.learnEnabled = v }
                Text("Flytter du et forslag før du sætter det (eller sætter du selv en cue lidt før en sektion), noterer appen det. Efter 3 gange med samme flytning gør den det selv – fx droppet altid 4 takter tidligere.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(CueRule.Target.allCases.filter { $0.section != nil }) { t in
                    if let l = CueRules.learnedOffset(for: t), l.bars != 0 {
                        Text("\(t.title): \(abs(l.bars)) takter \(l.bars < 0 ? "før" : "efter") (\(l.count)×)")
                            .font(.caption).foregroundColor(.orange)
                    }
                }
                Button("Glem det lærte") {
                    CueRules.learnedOffsets = [:]
                    learned = [:]
                }
                .disabled(learned.isEmpty)
            }
        }
    }
}
