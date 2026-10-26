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
                Toggle("Spørg før en download-gate åbnes", isOn: $settings.askBeforeGate)
                Toggle("Vis også andre versioner (radio edit, extended, remix)", isOn: $settings.showOtherVersions)
            }
            .padding(20)
            .tabItem { Label("Regler", systemImage: "checklist") }
        }
        .frame(width: 620, height: 440)
    }
}
