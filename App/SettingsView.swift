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
        }
        .frame(width: 620, height: 440)
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
