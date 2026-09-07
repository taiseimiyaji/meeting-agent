import AppKit
import SwiftUI
import WebKit

// Compile alongside EmbeddedWebView.swift; uses real WebKit, not a mocked delegate.
@main struct EmbeddedWebViewCheck {
    @MainActor final class StateBox { var value: WebLoadState = .loading }

    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let delayed = directory.appendingPathComponent("delayed.html")
                try "<div id='root'></div><script>setTimeout(()=>document.getElementById('root').innerHTML='<p>Meetings</p>',500)</script>".write(to: delayed, atomically: true, encoding: .utf8)
                let empty = directory.appendingPathComponent("empty.html")
                try "<div id='root'></div>".write(to: empty, atomically: true, encoding: .utf8)
                let state = StateBox()
                let parent = MeetingWebView(url: delayed, reloadID: 0, retryID: 0, state: Binding(get: { state.value }, set: { state.value = $0 }))
                let coordinator = parent.makeCoordinator()
                let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
                webView.navigationDelegate = coordinator
                coordinator.load(webView)
                try await expect(state, ready: true, name: "delayed JavaScript render")
                coordinator.parent = MeetingWebView(url: empty, reloadID: 1, retryID: 0, state: parent.$state)
                state.value = .loading
                coordinator.load(webView)
                try await expect(state, ready: false, name: "blank JavaScript app reports failure")
                coordinator.parent = parent
                state.value = .loading
                coordinator.load(webView)
                try await expect(state, ready: true, name: "reload recovers after failure")
                coordinator.webViewWebContentProcessDidTerminate(webView)
                try await expect(state, ready: false, name: "terminated WebKit process reports failure")
                if let url = CommandLine.arguments.dropFirst().first.flatMap(URL.init(string:)) {
                    coordinator.parent = MeetingWebView(url: url, reloadID: 2, retryID: 0, state: parent.$state)
                    state.value = .loading
                    coordinator.load(webView)
                    try await expect(state, ready: true, name: "bundled local HTTP application renders")
                }
                coordinator.timeout?.cancel()
                print("Embedded WebView verification passed")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func expect(_ state: StateBox, ready: Bool, name: String) async throws {
        for _ in 0..<250 {
            try await Task.sleep(for: .milliseconds(100))
            switch state.value {
            case .loading: continue
            case .ready where ready: print("PASS: \(name)"); return
            case .failed where !ready: print("PASS: \(name)"); return
            default: throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected state: \(state.value)"])
            }
        }
        throw NSError(domain: name, code: 2, userInfo: [NSLocalizedDescriptionKey: "Verification timed out"])
    }
}
