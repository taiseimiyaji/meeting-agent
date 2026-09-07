import SwiftUI
import WebKit

struct EmbeddedWebView: View {
    let url: URL
    let reloadID: Int
    @State private var retryID = 0
    @State private var state: WebLoadState = .loading

    var body: some View {
        ZStack {
            MeetingWebView(url: url, reloadID: reloadID, retryID: retryID, state: $state)
                .opacity(state == .ready ? 1 : 0)
            switch state {
            case .loading:
                ProgressView("Meetingsを読み込んでいます…")
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Meetingsを表示できませんでした").font(.headline)
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("再試行") { retryID += 1 }
                    Text("繰り返し失敗する場合は、録音を停止してアプリを終了し、起動し直してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            case .ready:
                EmptyView()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum WebLoadState: Equatable {
    case loading, ready, failed(String)
}

struct MeetingWebView: NSViewRepresentable {
    let url: URL
    let reloadID: Int
    let retryID: Int
    @Binding var state: WebLoadState

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.reloadID != reloadID || coordinator.parent.retryID != retryID || coordinator.parent.url != url
        coordinator.parent = self
        if changed { coordinator.load(webView) }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.timeout?.cancel()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MeetingWebView
        var timeout: Task<Void, Never>?
        var generation = 0
        init(parent: MeetingWebView) { self.parent = parent }

        func load(_ webView: WKWebView) {
            generation += 1
            let current = generation
            timeout?.cancel()
            // SwiftUI may invoke load during an NSView update.
            Task { [weak self] in
                guard let self, current == self.generation else { return }
                self.parent.state = .loading
            }
            webView.load(URLRequest(url: parent.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
            timeout = Task { [weak self, weak webView] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, current == self.generation else { return }
                self.fail("画面の読み込みがタイムアウトしました。再試行してください。")
                webView?.stopLoading()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let current = generation
            // Navigation success alone does not mean the JavaScript app rendered.
            webView.callAsyncJavaScript("""
                for (let attempt = 0; attempt < 100; attempt++) {
                    if (document.getElementById('root')?.childElementCount > 0) return true;
                    await new Promise(resolve => setTimeout(resolve, 100));
                }
                return false;
                """, arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self, current == self.generation else { return }
                if case .success(let value) = result, value as? Bool == true {
                    self.timeout?.cancel()
                    self.parent.state = .ready
                } else {
                    self.fail("会議画面を初期化できませんでした。Reloadまたは再試行で読み込み直してください。")
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { handle(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { handle(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("画面表示プロセスが終了しました。再試行してください。") }

        private func handle(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            fail(error.localizedDescription)
        }
        private func fail(_ message: String) {
            generation += 1
            timeout?.cancel()
            parent.state = .failed(message)
        }
    }
}
