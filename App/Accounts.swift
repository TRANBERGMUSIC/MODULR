// MODULR – Konti: log ind én gang hos hver tjeneste. Loginnet gemmes i MODULRs egen browser
// (samme som gate-browseren), så gates typisk kun kræver et par klik bagefter.
// Du skriver selv brugernavn og kodeord på tjenesternes egne sider – MODULR ser dem aldrig.

import SwiftUI
import WebKit
import AuthenticationServices
import CryptoKit

struct Service: Identifiable, Equatable {
    let id: String
    let name: String
    let loginURL: URL
    let domains: [String]
    let why: String

    static let all: [Service] = [
        Service(id: "soundcloud", name: "SoundCloud", loginURL: URL(string: "https://soundcloud.com/signin")!,
                domains: ["soundcloud.com"], why: "Gates beder ofte om follow/like/repost på SoundCloud"),
        Service(id: "hypeddit", name: "Hypeddit", loginURL: URL(string: "https://hypeddit.com")!,
                domains: ["hypeddit.com"], why: "Den mest brugte download-gate"),
        Service(id: "toneden", name: "ToneDen", loginURL: URL(string: "https://www.toneden.io")!,
                domains: ["toneden.io"], why: "Download-gate"),
        Service(id: "spotify", name: "Spotify", loginURL: URL(string: "https://accounts.spotify.com/login")!,
                domains: ["spotify.com"], why: "Gates beder ofte om follow/pre-save på Spotify"),
        Service(id: "instagram", name: "Instagram", loginURL: URL(string: "https://www.instagram.com/accounts/login/")!,
                domains: ["instagram.com"], why: "Nogle gates beder om et Instagram-follow"),
        Service(id: "bandcamp", name: "Bandcamp", loginURL: URL(string: "https://bandcamp.com/login")!,
                domains: ["bandcamp.com"], why: "Gratis downloads og din samling"),
    ]
}

final class AccountsModel: ObservableObject {
    @Published var confirmed: [String: Date] = [:]
    @Published var hasCookies: Set<String> = []
    @Published var soundCloudUser: String?
    @Published var soundCloudStatus: String?
    @Published var connecting = false

    private let key = "accounts.confirmed"

    init() {
        if let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Date] { confirmed = d }
        refresh()
    }

    /// Ser efter cookies fra hver tjeneste i MODULRs browser.
    func refresh() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var found = Set<String>()
            for s in Service.all {
                if cookies.contains(where: { c in
                    let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return s.domains.contains { Domains.matches(d, $0) }
                }) { found.insert(s.id) }
            }
            DispatchQueue.main.async { self.hasCookies = found }
        }
    }

    func isLoggedIn(_ s: Service) -> Bool { confirmed[s.id] != nil && hasCookies.contains(s.id) }

    func confirm(_ s: Service) {
        confirmed[s.id] = Date()
        UserDefaults.standard.set(confirmed, forKey: key)
        refresh()
    }

    /// Log ud: slet tjenestens cookies og data i MODULRs browser.
    func logout(_ s: Service) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let mine = records.filter { r in s.domains.contains { r.displayName.lowercased().contains($0.components(separatedBy: ".")[0]) } }
            store.removeData(ofTypes: types, for: mine) {
                DispatchQueue.main.async {
                    self.confirmed[s.id] = nil
                    UserDefaults.standard.set(self.confirmed, forKey: self.key)
                    self.refresh()
                }
            }
        }
    }

    // MARK: SoundCloud-API med din konto (OAuth 2.1 + PKCE)

    private var authSession: ASWebAuthenticationSession?
    private let presenter = AuthPresenter()

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func loadSoundCloudUser(settings: FBSettings) {
        guard settings.soundCloudConfigured, SoundCloudAPI.hasUserLogin else {
            soundCloudUser = nil
            return
        }
        let api = SoundCloudAPI(clientID: settings.keys.soundCloudClientID, clientSecret: settings.keys.soundCloudClientSecret)
        Task {
            let name = try? await api.me()
            await MainActor.run { self.soundCloudUser = name }
        }
    }

    func connectSoundCloud(settings: FBSettings) {
        guard settings.soundCloudConfigured else {
            soundCloudStatus = "Indsæt først client-id og secret fra din SoundCloud-app."
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Self.base64url(Data(bytes))
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        var c = URLComponents(string: "https://secure.soundcloud.com/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: settings.keys.soundCloudClientID),
            URLQueryItem(name: "redirect_uri", value: SoundCloudAPI.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        let api = SoundCloudAPI(clientID: settings.keys.soundCloudClientID, clientSecret: settings.keys.soundCloudClientSecret)
        connecting = true
        soundCloudStatus = "Log ind i vinduet fra SoundCloud …"
        let session = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "modulr") { [weak self] callback, error in
            guard let self else { return }
            guard error == nil, let callback,
                  let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems,
                  items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.connecting = false
                    self.soundCloudStatus = "Login blev afbrudt."
                }
                return
            }
            Task {
                do {
                    try await api.exchange(code: code, verifier: verifier)
                    let name = try? await api.me()
                    await MainActor.run {
                        self.soundCloudUser = name ?? "forbundet"
                        self.soundCloudStatus = nil
                        self.connecting = false
                    }
                } catch {
                    await MainActor.run {
                        self.soundCloudStatus = error.localizedDescription
                        self.connecting = false
                    }
                }
            }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        authSession = session
        session.start()
    }

    func disconnectSoundCloud() {
        SoundCloudAPI.logoutUser()
        soundCloudUser = nil
    }
}

final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - Skærm

struct AccountsView: View {
    @EnvironmentObject var accounts: AccountsModel
    @EnvironmentObject var settings: FBSettings
    @State private var loginService: Service?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(title: "Log ind med Google") {
                    Text("Google tillader ikke login inde i apps' indbyggede browsere. Derfor åbner MODULR som standard gates i din egen browser (Safari/Chrome), hvor du allerede er logget ind med Google. MODULR fanger filen i Overførsler automatisk og tjekker den.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Åbn gates i min egen browser", isOn: $settings.useSystemBrowser)
                    Text(settings.useSystemBrowser
                         ? "Du behøver ikke logge ind herunder – brug bare din browser som normalt. Første gang spørger macOS, om MODULR må se mappen Overførsler: svar OK."
                         : "Gates åbner i MODULRs egen browser. Log ind herunder med e-mail og kodeord (ikke Google).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Login i MODULRs egen browser (kun hvis du ikke bruger din egen browser til gates). Du skriver selv brugernavn og kodeord på tjenesternes egne sider.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Card(title: "Tjenester") {
                    ForEach(Service.all) { s in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(accounts.isLoggedIn(s) ? Color.ember : Color.secondary.opacity(0.4))
                                .frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.headline)
                                Text(accounts.isLoggedIn(s) ? "Logget ind" : s.why)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if accounts.isLoggedIn(s) {
                                Button("Log ud") { accounts.logout(s) }
                            }
                            Button(accounts.isLoggedIn(s) ? "Åbn" : "Log ind") { loginService = s }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }

                Card(title: "SoundCloud-API (søgning og direkte downloads)") {
                    Text("For at MODULR kan søge på SoundCloud og hente filer, kunstnerne har slået download til, skal du have en SoundCloud-app. Det er gratis, men SoundCloud skal godkende den. (Selve login sker i Safari-vinduet fra macOS, så \"Fortsæt med Google\" virker her.)")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Gå til soundcloud.com/you/apps og ansøg om en app.")
                        Text("2. Sæt redirect-URI til:  \(SoundCloudAPI.redirectURI)")
                            .textSelection(.enabled)
                        Text("3. Indsæt client-id og secret herunder, og klik \"Forbind min SoundCloud-konto\".")
                    }
                    .font(.callout)
                    HStack {
                        SecureField("Client ID", text: $settings.keys.soundCloudClientID)
                        SecureField("Client secret", text: $settings.keys.soundCloudClientSecret)
                    }
                    .textFieldStyle(.roundedBorder)
                    HStack {
                        if let u = accounts.soundCloudUser {
                            Label("Forbundet som \(u)", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.ember)
                            Spacer()
                            Button("Afbryd forbindelse") { accounts.disconnectSoundCloud() }
                        } else {
                            Button(accounts.connecting ? "Venter på SoundCloud …" : "Forbind min SoundCloud-konto") {
                                accounts.connectSoundCloud(settings: settings)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!settings.soundCloudConfigured || accounts.connecting)
                            Spacer()
                        }
                    }
                    if let st = accounts.soundCloudStatus {
                        Text(st).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Card(title: "Genkendelse af sange") {
                    Text("AcoustID er gratis: opret en konto på acoustid.org, vælg \"Register your application\" og indsæt nøglen her.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        SecureField("AcoustID-nøgle", text: $settings.keys.acoustID)
                            .textFieldStyle(.roundedBorder)
                        Button("Åbn acoustid.org") { NSWorkspace.shared.open(URL(string: "https://acoustid.org/new-application")!) }
                    }
                    Label(settings.keys.acoustID.isEmpty ? "Mangler – sange genkendes kun ud fra tags" : "Klar",
                          systemImage: settings.keys.acoustID.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(settings.keys.acoustID.isEmpty ? .amber : .ember)
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.void)
        .onAppear {
            accounts.refresh()
            accounts.loadSoundCloudUser(settings: settings)
        }
        .sheet(item: $loginService) { s in
            LoginBrowserSheet(service: s) {
                accounts.confirm(s)
                loginService = nil
            } onClose: {
                accounts.refresh()
                loginService = nil
            }
        }
    }
}

struct LoginBrowserSheet: View {
    let service: Service
    let onDone: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log ind på \(service.name)").font(.headline)
                Spacer()
                Button("Annullér") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Færdig – jeg er logget ind") { onDone() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(10)
            Divider()
            LoginWebView(url: service.loginURL)
        }
        .frame(minWidth: 900, minHeight: 680)
    }
}

/// Almindelig browser i MODULRs fælles login-lager. Ingen scripts, ingen automatisk udfyldning.
struct LoginWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = navigationAction.request.url, SourcePolicy.isBlockedForBrowsing(u) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
