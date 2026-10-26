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

/// Dine regler for hvor hot cues A–H skal foreslås – og hvad appen har lært af dig.
struct CueRulesSettingsView: View {
    @State private var rules: [String: CueRule] = CueRules.rules
    @State private var learnOn: Bool = CueRules.learnEnabled
    @State private var learned = CueRules.learned

    var body: some View {
        Form {
            Section("Hvor skal cues foreslås?") {
                ForEach(HotCue.letters, id: \.self) { letter in
                    row(letter)
                }
                Button("Gendan standard") {
                    rules = CueRules.defaults
                    CueRules.rules = rules
                }
            }
            Section("Lær af mig") {
                Toggle("Lær hvordan jeg selv sætter cues", isOn: $learnOn)
                    .onChange(of: learnOn) { _, v in CueRules.learnEnabled = v }
                Text("Når du sætter en hot cue selv, noterer appen hvor i sangen den ligger (fx \"1. drop\" eller \"16 takter efter første slag\"). Efter 3 sange med samme mønster bruges dit mønster i stedet for reglen ovenfor.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Glem det lærte") {
                    CueRules.learned = [:]
                    learned = [:]
                }
                .disabled(learned.isEmpty)
            }
        }
    }

    func row(_ letter: String) -> some View {
        let rule = rules[letter] ?? CueRule(target: .none)
        let c = HotCue.rgb[letter] ?? (1, 1, 1)
        return HStack(spacing: 10) {
            Text(letter)
                .font(.system(size: 12, weight: .heavy)).foregroundColor(.black)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: c.0, green: c.1, blue: c.2)))
            Picker("", selection: Binding(get: { rule.target }, set: { v in set(letter) { $0.target = v } })) {
                ForEach(CueRule.Target.allCases) { t in Text(t.title).tag(t) }
            }
            .labelsHidden()
            .frame(width: 130)
            if rule.target != .none && rule.target != .firstBeat {
                Stepper("Nr. \(rule.ordinal)", value: Binding(get: { rule.ordinal }, set: { v in set(letter) { $0.ordinal = max(1, v) } }), in: 1...6)
                    .frame(width: 110)
            }
            if rule.target != .none {
                Stepper(rule.offsetBars == 0 ? "Lige på" : "\(rule.offsetBars > 0 ? "+" : "")\(rule.offsetBars) takter",
                        value: Binding(get: { rule.offsetBars }, set: { v in set(letter) { $0.offsetBars = v } }), in: -32...64, step: 4)
                    .frame(width: 150)
            }
            Spacer()
            if learnOn, let l = CueRules.learnedRule(for: letter) {
                Text("Lært: \(l.rule.summary) (\(l.count)×)")
                    .font(.caption).foregroundColor(.orange)
            }
        }
    }

    func set(_ letter: String, _ change: (inout CueRule) -> Void) {
        var r = rules[letter] ?? CueRule(target: .none)
        change(&r)
        rules[letter] = r
        CueRules.rules = rules
    }
}
