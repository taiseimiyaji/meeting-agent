@preconcurrency import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MeetingCore
import MeetingAnalysis
import CodexSupport

public enum CodexCompanion {
    public static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MeetingCodexHelper.app")
    }

    private static func temporaryRequest() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-agent-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try TemporaryWorkspace.mark(directory)
        try Data().write(to: directory.appendingPathComponent("request.meetingcodex"))
        return directory
    }

    public static func checkLogin(helper: URL? = nil) async throws {
        let directory = try temporaryRequest()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await launch(mode: "status", directory: directory, helper: helper ?? bundledHelper, timeout: 50)
    }

    public static func generate(timeline: Timeline, evidenceRoot: URL, includeScreens: Bool, helper: URL? = nil) async throws -> (MeetingCore.MeetingSummary, String) {
        let directory = try temporaryRequest()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = evidenceRoot.appendingPathComponent(timeline.meeting.id).resolvingSymlinksInPath()
        guard root.path.hasPrefix(evidenceRoot.resolvingSymlinksInPath().path + "/") else { throw CodexFailure("会議の保存先が不正です。") }
        var screenInputs: [CodexMeetingInput.Screen] = []
        let sorted = includeScreens ? timeline.screens.sorted { $0.timeRange.startedAtMs < $1.timeRange.startedAtMs } : []
        // Bound image use explicitly. Omitted snapshots are disclosed in the input;
        // they can never support a name assignment.
        let selected = sorted.count <= 32 ? sorted : (0..<32).map { sorted[$0 * (sorted.count - 1) / 31] }
        for screen in selected {
            let source = URL(fileURLWithPath: screen.imagePath).resolvingSymlinksInPath()
            guard source.path.hasPrefix(root.path + "/") else { throw CodexFailure("会議外の画像は送信できません。") }
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let name = "screen-\(screenInputs.count).jpg"
            try copyThumbnail(source: source, destination: directory.appendingPathComponent(name))
            screenInputs.append(.init(id: screen.id, timestampMs: screen.timeRange.startedAtMs, fileName: name))
        }
        let transcripts = timeline.transcripts.filter { $0.isFinal && $0.possibleEchoOf == nil && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let input = CodexMeetingInput(transcripts: transcripts, screens: screenInputs, omittedScreenCount: sorted.count - screenInputs.count)
        try input.validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(input).write(to: directory.appendingPathComponent("input.json"), options: .atomic)
        let kinds: Set<ExternalDataKind> = screenInputs.isEmpty ? [.transcript] : [.transcript, .keyFrame]
        let auditDirectory = root.appendingPathComponent("CodexAudit/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: auditDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let consent = ExternalProcessingConsent(meetingID: timeline.meeting.id, provider: "codex_chatgpt", allowedData: kinds)
        try encoder.encode(consent).write(to: auditDirectory.appendingPathComponent("consent.json"), options: .atomic)
        defer {
            // Persist the transmission record even when inference fails or is cancelled.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("submitted").path) {
                let audit = ExternalProcessingAudit(meetingID: timeline.meeting.id, provider: "codex_chatgpt", model: "codex-default", sentData: kinds)
                try? encoder.encode(audit).write(to: auditDirectory.appendingPathComponent("sent.json"), options: .atomic)
            }
            for name in ["receipt.json", "error.json", "allowance.json"] {
                if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) {
                    try? data.write(to: auditDirectory.appendingPathComponent(name), options: .atomic)
                }
            }
        }
        try await launch(mode: "summarize", directory: directory, helper: helper ?? bundledHelper, timeout: 300)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(MeetingCore.MeetingSummary.self, from: Data(contentsOf: directory.appendingPathComponent("result.json")))
        try input.validate(summary) // Verify again against the caller's original evidence.
        let receipt = try decoder.decode(CodexReceipt.self, from: Data(contentsOf: directory.appendingPathComponent("receipt.json")))
        guard receipt.authentication == "chatgpt" else { throw CodexFailure("ChatGPT認証以外の結果は利用できません。") }
        return (summary, receipt.model)
    }

    private static func copyThumbnail(source: URL, destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CodexFailure("会議の画像を読み取れませんでした。")
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CodexFailure("送信用の画像を準備できませんでした。") }
    }

    @MainActor private static func launch(mode: String, directory: URL, helper: URL, timeout: TimeInterval) async throws {
        guard FileManager.default.fileExists(atPath: helper.path) else {
            throw CodexFailure("Codex連携ヘルパーが含まれていません。最新版のMeeting Agentアプリをインストールしてください。")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false; configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        let request = directory.appendingPathComponent("request.meetingcodex")
        try Data(mode.utf8).write(to: request, options: .atomic)
        // Sandboxed callers cannot pass launch arguments. Opening the request
        // document delivers its URL through LaunchServices and grants file access.
        let application = try await NSWorkspace.shared.open([request], withApplicationAt: helper, configuration: configuration)
        // Removing the request on cancellation lets the helper stop Codex itself.
        // Killing the helper first could orphan its child process.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: directory.appendingPathComponent("error.json")) {
                throw try JSONDecoder().decode(CodexFailure.self, from: data)
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path) { return }
            if application.isTerminated { throw CodexFailure("Codex連携ヘルパーが終了しました。アプリを再起動して再試行してください。") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CodexFailure("Codexが制限時間内に応答しませんでした。再生成してください。")
    }
}
