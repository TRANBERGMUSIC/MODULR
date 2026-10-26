// MODULR – indlejret browser til download-gates (Hypeddit, ToneDen, lnk.to …) og Bandcamp.
// DU gennemfører selv gaten (follow/like/e-mail). MODULR klikker ikke, udfylder intet og
// kører ingen scripts på siden – den fanger kun den fil, siden selv giver dig til sidst.

import SwiftUI
import WebKit

struct GateBrowserSheet: View {
    let ticket: GateSessionTicket
    let onFile: (URL, URL?, String?) -> Void
    let onClose: () -> Void
    @State private var currentURL: String = ""
    @State private var status = "Gennemfør trinene på siden. Når den giver dig filen, fanger MODULR den automatisk."

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.ember)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ticket.page.source.title)
                        .font(.headline)
                    Text(currentURL.isEmpty ? ticket.page.url.absoluteString : currentURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Åbn i min browser") { NSWorkspace.shared.open(ticket.page.url) }
                Button("Luk") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            Divider()
            GateWebView(ticket: ticket, currentURL: $currentURL, status: $status, onFile: onFile)
        }
        .frame(minWidth: 900, minHeight: 650)
    }
}

struct GateWebView: NSViewRepresentable {
    let ticket: GateSessionTicket
    @Binding var currentURL: String
    @Binding var status: String
    let onFile: (URL, URL?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()      // så du kan forblive logget ind på gate-tjenesterne
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: ticket.page.url))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let parent: GateWebView
        private var destinations: [ObjectIdentifier: URL] = [:]
        private var sources: [ObjectIdentifier: URL] = [:]
        weak var webView: WKWebView?

        init(_ parent: GateWebView) { self.parent = parent }

        // Popups (target=_blank / window.open) åbnes i samme vindue
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            self.webView = webView
            if let url = navigationAction.request.url, SourcePolicy.isBlockedForBrowsing(url) {
                parent.status = "Blokeret: \(url.host ?? "") er ikke en tilladt kilde."
                decisionHandler(.cancel)
                return
            }
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse,
               let cd = http.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().contains("attachment") {
                decisionHandler(.download)
                return
            }
            if let mime = navigationResponse.response.mimeType?.lowercased(),
               mime.hasPrefix("audio/") || mime == "application/zip" || mime == "application/octet-stream" {
                decisionHandler(.download)
                return
            }
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.currentURL = webView.url?.absoluteString ?? ""
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MODULR-gate-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(suggestedFilename.isEmpty ? "download" : suggestedFilename)
            destinations[ObjectIdentifier(download)] = dest
            if let u = response.url { sources[ObjectIdentifier(download)] = u }
            parent.status = "Henter \(suggestedFilename) …"
            completionHandler(dest)
        }

        func downloadDidFinish(_ download: WKDownload) {
            let key = ObjectIdentifier(download)
            guard let dest = destinations[key] else { return }
            let title = webView?.title
            if let src = sources[key], SourcePolicy.isForbidden(src) {
                try? FileManager.default.removeItem(at: dest)
                parent.status = "Filen kom fra \(src.host ?? "en ukendt vært") og er afvist og slettet."
                return
            }
            parent.status = "Filen er hentet – MODULR verificerer den nu."
            parent.onFile(dest, sources[key], title)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            parent.status = "Download fejlede: \(error.localizedDescription)"
        }
    }
}
