import AppKit
import Foundation
import MeetingCapture
import LocalAPI

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var permissions = CapturePermissionSnapshot(screenRecording: .notDetermined, microphone: .notDetermined)
    @Published var targets: [CaptureTarget] = []
    @Published var selectedWindowID: UInt32?
    @Published var isCapturing = false
    @Published var metrics = CaptureMetricsSnapshot()
    @Published var errorMessage: String?
    let apiCredentials: APICredentials

    private let capture: LocalCaptureController
    private let permissionProvider: any CapturePermissionProviding
    private var metricsTask: Task<Void, Never>?
    private let diagnostics = DiagnosticsRecorder()

    init(
        capture: LocalCaptureController,
        apiCredentials: APICredentials,
        permissionProvider: any CapturePermissionProviding = SystemCapturePermissions()
    ) {
        self.capture = capture
        self.apiCredentials = apiCredentials
        self.permissionProvider = permissionProvider
        Task { await refresh() }
    }

    deinit { metricsTask?.cancel() }

    func refresh() async {
        permissions = await permissionProvider.current()
        guard permissions.screenRecording == .granted else { return }
        do {
            targets = try await capture.availableTargets()
            if selectedWindowID == nil {
                selectedWindowID = targets.first(where: {
                    $0.applicationName.localizedCaseInsensitiveContains("Chrome")
                })?.id
            }
        } catch {
            errorMessage = error.localizedDescription
            AgentEnvironment.logger.error("Failed to enumerate capture targets: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestScreenPermission() async {
        permissions.screenRecording = await permissionProvider.requestScreenRecording()
        await refresh()
    }

    func requestMicrophonePermission() async {
        permissions.microphone = await permissionProvider.requestMicrophone()
        await refresh()
    }

    func requestSpeechPermission() async {
        permissions.speechRecognition = await permissionProvider.requestSpeechRecognition()
        await refresh()
    }

    func start() async {
        errorMessage = nil
        do {
            try await capture.start(targetID: selectedWindowID.map(String.init))
            isCapturing = true
            if let directory = try? AgentEnvironment.prepareDataDirectory() {
                try? await diagnostics.start(in: directory)
            }
            metricsTask?.cancel()
            metricsTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.metrics = await self.capture.metricsSnapshot()
                    try? await self.diagnostics.append(self.metrics)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            AgentEnvironment.logger.error("Capture failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() async {
        do { try await capture.stop() }
        catch {
            errorMessage = error.localizedDescription
            AgentEnvironment.logger.error("Capture failed to stop: \(error.localizedDescription, privacy: .public)")
        }
        metricsTask?.cancel()
        metricsTask = nil
        try? await diagnostics.stop()
        metrics = await capture.metricsSnapshot()
        isCapturing = false
    }

    func openPrivacySettings(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")!
        NSWorkspace.shared.open(url)
    }

    func copyAPIConfiguration() {
        let value = "{\"baseUrl\":\"http://127.0.0.1:8765/api\",\"sessionToken\":\"\(apiCredentials.sessionToken)\",\"csrfToken\":\"\(apiCredentials.csrfToken)\"}"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }

    func openWebUI() {
        var components = URLComponents(string: "http://127.0.0.1:8765/")!
        components.fragment = "sessionToken=\(apiCredentials.sessionToken)&csrfToken=\(apiCredentials.csrfToken)"
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
