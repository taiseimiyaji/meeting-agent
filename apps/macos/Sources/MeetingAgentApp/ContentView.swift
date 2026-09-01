import MeetingCapture
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AgentViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Meeting Agent").font(.largeTitle.bold())
                    Text(model.isCapturing ? "Capture is active" : "Ready to capture a Google Meet window")
                        .foregroundStyle(model.isCapturing ? .red : .secondary)
                }
                Spacer()
                Circle().fill(model.isCapturing ? .red : .secondary).frame(width: 14, height: 14)
            }

            GroupBox("Permissions") {
                VStack(spacing: 10) {
                    permissionRow("Screen Recording", state: model.permissions.screenRecording) {
                        Task { await model.requestScreenPermission() }
                    } settings: { model.openPrivacySettings("ScreenCapture") }
                    permissionRow("Microphone", state: model.permissions.microphone) {
                        Task { await model.requestMicrophonePermission() }
                    } settings: { model.openPrivacySettings("Microphone") }
                    permissionRow("Speech Recognition", state: model.permissions.speechRecognition) {
                        Task { await model.requestSpeechPermission() }
                    } settings: { model.openPrivacySettings("SpeechRecognition") }
                }.padding(6)
            }

            GroupBox("Capture target") {
                Picker("Window (Chrome prioritized)", selection: $model.selectedWindowID) {
                    Text("Select a window").tag(nil as UInt32?)
                    ForEach(model.targets) { target in
                        Text("\(target.applicationName.localizedCaseInsensitiveContains("chrome") ? "★ " : "")\(target.applicationName) — \(target.windowTitle)").tag(target.id as UInt32?)
                    }
                }
                .disabled(model.isCapturing)
                .padding(6)
                Text("Meet以外でも、画面上に表示されている任意のアプリウィンドウを収録できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
            }

            GroupBox("Local API") {
                HStack {
                    Text("http://127.0.0.1:8765/api").textSelection(.enabled)
                    Spacer()
                    Text("token …\(model.apiCredentials.sessionToken.suffix(6))").foregroundStyle(.secondary)
                    Button("Open Web UI") { model.openWebUI() }
                    Button("Copy configuration") { model.copyAPIConfiguration() }
                }.padding(6)
            }

            GroupBox("Live metrics") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    metricRow("Screen frames", model.metrics.screenFrames)
                    metricRow("System audio buffers", model.metrics.systemAudioBuffers)
                    metricRow("Microphone buffers", model.metrics.microphoneBuffers)
                    metricRow("System audio RMS", model.metrics.systemAudioRMSDB)
                    metricRow("Microphone RMS", model.metrics.microphoneRMSDB)
                    metricRow("Dropped screen frames", model.metrics.droppedScreenFrames)
                    metricRow("Capture errors", model.metrics.errors)
                    metricRow("Process CPU", model.metrics.processCPUPercent, suffix: "%")
                    metricRow("Resident memory", model.metrics.residentMemoryBytes.map { Double($0) / 1_048_576 }, suffix: "MB")
                }.padding(6)
            }

            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                Button("Refresh") { Task { await model.refresh() } }.disabled(model.isCapturing)
                Spacer()
                Button(model.isCapturing ? "Stop Capture" : "Start Capture") {
                    Task { model.isCapturing ? await model.stop() : await model.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isCapturing ? .red : .accentColor)
                .disabled(!model.isCapturing && (model.permissions.screenRecording != .granted || model.permissions.microphone != .granted || model.selectedWindowID == nil))
            }
        }
        .padding(24)
    }

    private func permissionRow(
        _ title: String,
        state: PermissionState,
        request: @escaping () -> Void,
        settings: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(state == .granted ? .green : .orange)
            Text(title)
            Spacer()
            Text(state.rawValue).foregroundStyle(.secondary)
            if state == .notDetermined { Button("Request", action: request) }
            else if state != .granted { Button("Open Settings", action: settings) }
        }
    }

    private func metricRow(_ title: String, _ value: UInt64) -> some View {
        GridRow { Text(title); Text(value.formatted()).monospacedDigit() }
    }

    private func metricRow(_ title: String, _ value: Double?) -> some View {
        GridRow {
            Text(title)
            Text(value.map { String(format: "%.1f dBFS", $0) } ?? "—").monospacedDigit()
        }
    }

    private func metricRow(_ title: String, _ value: Double?, suffix: String) -> some View {
        GridRow {
            Text(title)
            Text(value.map { String(format: "%.1f %@", $0, suffix) } ?? "—").monospacedDigit()
        }
    }
}
