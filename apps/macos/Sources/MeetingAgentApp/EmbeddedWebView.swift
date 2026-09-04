import SwiftUI
import WebKit

struct EmbeddedWebView: NSViewRepresentable {
    let url: URL
    let reloadID: Int

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadID != reloadID {
            context.coordinator.lastReloadID = reloadID
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(reloadID: reloadID) }

    final class Coordinator {
        var lastReloadID: Int
        init(reloadID: Int) { self.lastReloadID = reloadID }
    }
}
