import AppKit
import Foundation
import CodexSupport
import MeetingCore

@MainActor final class HelperDelegate: NSObject, NSApplicationDelegate {
    private var started = false
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.count == 1, urls[0].lastPathComponent == "request.meetingcodex",
              let mode = try? String(contentsOf: urls[0], encoding: .utf8) else { application.terminate(nil); return }
        start(mode: mode, directory: urls[0].deletingLastPathComponent())
    }
    func start(mode: String, directory: URL) {
        guard !started, ["status", "summarize"].contains(mode),
              directory.lastPathComponent.hasPrefix("meeting-agent-codex-"),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("request.meetingcodex").path) else {
            NSApplication.shared.terminate(nil); return
        }
        started = true
        Task {
            do {
                try TemporaryWorkspace.mark(directory, role: "helper")
                let runner = try CodexRunner()
                if mode == "status" {
                    try await runner.checkLogin(directory: directory)
                    _ = try await runner.checkAllowance(directory: directory)
                    try Data().write(to: directory.appendingPathComponent("completed"), options: .atomic)
                } else { try await runner.summarize(directory: directory) }
            } catch {
                let failure = (error as? CodexFailure) ?? CodexFailure("Codexの応答を読み取れませんでした。再生成してください。")
                try? JSONEncoder().encode(failure).write(to: directory.appendingPathComponent("error.json"), options: .atomic)
            }
            NSApplication.shared.terminate(nil)
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            try? await Task.sleep(for: .seconds(10))
            if !started { NSApplication.shared.terminate(nil) }
        }
    }
}

@main struct MeetingCodexHelper {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = HelperDelegate()
        app.delegate = delegate
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2 { delegate.start(mode: args[0], directory: URL(fileURLWithPath: args[1])) }
        withExtendedLifetime(delegate) { app.run() }
    }
}
