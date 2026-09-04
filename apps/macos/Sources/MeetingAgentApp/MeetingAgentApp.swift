import SwiftUI
import LocalAPI
import MeetingCapture
import MeetingCore
import MeetingPipeline

@main
struct MeetingAgentApp: App {
    @StateObject private var model: AgentViewModel
    private let apiServer: LocalAPIServer
    private let analysisRuntime: MeetingAnalysisRuntime
    private var terminationObserver: NSObjectProtocol?

    init() {
        do {
            let directory = try AgentEnvironment.prepareDataDirectory()
            AgentEnvironment.logger.info("Data directory ready: \(directory.path, privacy: .private)")
            let store = try MeetingStore(path: directory.appendingPathComponent("meeting-agent.sqlite").path)
            let evidenceRoot = directory.appendingPathComponent("Meetings", isDirectory: true)
            let repository = try LocalMeetingRepository(store: store, evidenceRoot: evidenceRoot)
            _ = try store.recoverInterruptedWork()
            let controller = LocalCaptureController(adapter: ScreenCaptureKitAdapter(), store: store, evidenceRoot: evidenceRoot)
            let analysisRuntime = try MeetingAnalysisRuntime(store: store, evidenceRoot: evidenceRoot)
            self.analysisRuntime = analysisRuntime
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: nil
            ) { _ in Task { await analysisRuntime.stop() } }
            Task {
                do { try await analysisRuntime.start() }
                catch { AgentEnvironment.logger.error("Analysis worker failed to start: \(error.localizedDescription, privacy: .public)") }
            }
            let webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true)
            let server = LocalAPIServer(repository: repository, capture: controller, webRoot: webRoot)
            try server.start()
            apiServer = server
            _model = StateObject(wrappedValue: AgentViewModel(capture: controller, apiCredentials: server.credentials))
            AgentEnvironment.logger.info("Local API listening on 127.0.0.1:8765")
        } catch {
            AgentEnvironment.logger.error("Failed to prepare data directory: \(error.localizedDescription, privacy: .public)")
            fatalError("Meeting Agent initialization failed: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("Meeting Agent") {
            ContentView(model: model)
                .frame(minWidth: 820, minHeight: 680)
        }
        MenuBarExtra("Meeting Agent", systemImage: model.isCapturing ? "record.circle.fill" : "waveform.circle") {
            Button(model.isCapturing ? "Stop Capture" : "Open Meeting Agent") {
                if model.isCapturing { Task { await model.stop() } }
                else { NSApp.activate(ignoringOtherApps: true) }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
