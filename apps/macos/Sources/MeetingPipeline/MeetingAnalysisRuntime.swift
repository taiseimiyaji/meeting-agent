@preconcurrency import AVFoundation
import Foundation
import MeetingAnalysis
import CodexSupport
import MeetingCapture
import MeetingCore

public enum MeetingAnalysisRuntimeError: LocalizedError {
    case meetingNotFound(String)
    case unsafeMeetingID(String)
    case audioArchiveMissing(String)
    case transcriptionEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) was not found."
        case .unsafeMeetingID(let id): "Meeting ID is unsafe for export: \(id)"
        case .audioArchiveMissing(let id): "No saved audio is available for meeting \(id)."
        case .transcriptionEmpty: "音声から文字を認識できませんでした。保存音声を確認し、認識モデルを変更するか再実行してください。"
        }
    }
}

/// Registers the always-available local analysis jobs and owns their persistent
/// polling worker for the application lifetime.
public final class MeetingAnalysisRuntime: @unchecked Sendable {
    private let worker: PersistentAnalysisWorker
    private let store: MeetingStore
    private let evidenceRoot: URL
    private let settings: AgentSettingsStore
    private let fileTranscriber: (any FileTranscriber)?
    private let whisper: WhisperFileTranscriber
    private var scheduler: Task<Void, Never>?

    public init(store: MeetingStore, evidenceRoot: URL, pollInterval: Duration = .milliseconds(250), fileTranscriber: (any FileTranscriber)? = nil) throws {
        whisper = WhisperFileTranscriber(directory: evidenceRoot.deletingLastPathComponent().appendingPathComponent("Models"))
        self.fileTranscriber = fileTranscriber
        self.settings = AgentSettingsStore(url: evidenceRoot.deletingLastPathComponent().appendingPathComponent("settings.json"))
        self.store = store
        self.evidenceRoot = evidenceRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: self.evidenceRoot, withIntermediateDirectories: true)
        worker = PersistentAnalysisWorker(store: store, pollInterval: pollInterval)
    }

    public func start() async throws {
        guard scheduler == nil else { return }
        await configureHandlers()
        try enqueueMissingTranscriptions()
        try enqueueMissingSummaries()
        try await worker.start()
        scheduler = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    _ = try self?.enqueueMissingTranscriptions()
                    _ = try self?.enqueueMissingSummaries()
                    try self?.applyRetention()
                    try await Task.sleep(for: .seconds(2))
                } catch { do { try await Task.sleep(for: .seconds(2)) } catch { break } }
            }
        }
    }

    /// Repairs meetings created by older builds that completed without a
    /// summarize job. Safe to call repeatedly because active jobs are deduped.
    @discardableResult public func enqueueMissingSummaries() throws -> Int {
        var count = 0
        for meeting in try store.meetings(limit: 10_000) {
            guard [.completed, .partiallyCompleted, .interrupted].contains(meeting.status),
                  try store.activeSummary(meetingId: meeting.id) == nil else { continue }
            if (try? Self.hasPendingAudio(meeting: meeting, evidenceRoot: evidenceRoot)) ?? true,
               try store.latestAnalysisJob(meetingId: meeting.id, kind: "transcribe")?.status != .failed { continue }
            if try store.latestAnalysisJob(meetingId: meeting.id, kind: "summarize")?.status == .failed { continue }
            if try store.enqueueIfNeeded(.init(meetingId: meeting.id, kind: "summarize", priority: 2)) { count += 1 }
        }
        return count
    }

    @discardableResult public func enqueueMissingTranscriptions() throws -> Int {
        var count = 0
        for meeting in try store.meetings(limit: 10_000) {
            guard [.capturing, .completed, .partiallyCompleted, .interrupted, .failed].contains(meeting.status),
                  (try? Self.hasPendingAudio(meeting: meeting, evidenceRoot: evidenceRoot)) ?? true else { continue }
            if let job = try store.latestAnalysisJob(meetingId: meeting.id, kind: "transcribe"), job.status == .failed {
                let directory = evidenceRoot.appendingPathComponent(meeting.id).appendingPathComponent("Audio")
                let fresh = try ([directory] + ["legacy-systemAudio", "legacy-microphone"].map { directory.appendingPathComponent($0) }).contains { folder in
                    try AudioArchiveWriter.chunks(in: folder).contains { chunk in
                        !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(chunk.id).done").path) &&
                        !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(chunk.id).attempt").path)
                    }
                }
                if !fresh { continue }
            }
            if try store.enqueueIfNeeded(.init(meetingId: meeting.id, kind: "transcribe", priority: 3)) { count += 1 }
        }
        return count
    }

    private func configureHandlers() async {
        let store = store
        let evidenceRoot = evidenceRoot
        let settings = settings
        let injected = fileTranscriber
        let whisper = whisper
        await worker.register(kind: "transcribe") { job in
            let provider: any FileTranscriber
            if let injected { provider = injected }
            else {
                switch try settings.load().sttProvider {
                case "speech_analyzer":
                    if #available(macOS 26.0, *) { provider = AnalyzerFileTranscriber() }
                    else { throw FileTranscriptionError.unsupportedProvider("speech_analyzer requires macOS 26") }
                case "apple_speech": provider = AppleSpeechFileTranscriber()
                case "whisperkit": provider = whisper
                default: throw FileTranscriptionError.unsupportedProvider("unknown")
                }
            }
            try await Self.transcribe(meetingID: job.meetingId, store: store, evidenceRoot: evidenceRoot, provider: provider)
            if let meeting = try store.meeting(id: job.meetingId),
               ![.capturing, .finalizing].contains(meeting.status),
               try !Self.hasPendingAudio(meeting: meeting, evidenceRoot: evidenceRoot) {
                _ = try store.enqueueIfNeeded(.init(meetingId: job.meetingId, kind: "summarize", priority: 2))
            }
        }
        await worker.register(kind: "summarize") { job in
            guard var timeline = try store.timeline(meetingId: job.meetingId) else {
                throw MeetingAnalysisRuntimeError.meetingNotFound(job.meetingId)
            }
            guard let meeting = try store.meeting(id: job.meetingId) else { throw MeetingAnalysisRuntimeError.meetingNotFound(job.meetingId) }
            guard ![.capturing, .finalizing].contains(meeting.status) else {
                throw AnalysisDeferred("録音の終了を待っています。")
            }
            let pending = try Self.hasPendingAudio(meeting: meeting, evidenceRoot: evidenceRoot)
            let transcription = try store.latestAnalysisJob(meetingId: job.meetingId, kind: "transcribe")
            if pending && transcription?.status != .failed {
                throw AnalysisDeferred("文字起こしの完了を待っています。")
            }
            guard timeline.transcripts.contains(where: { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw AnalysisRejected("要約できる確定済みの文字起こしがありません。音声の文字起こしを復旧してから再実行してください。")
            }
            timeline.transcripts.removeAll { $0.possibleEchoOf != nil }
            var summary = HierarchicalHeuristicSummarizer().summarize(timeline)
            let preferences = try settings.load()
            let selected = preferences.summaryProvider
            var model = selected == "local_heuristic" ? "hierarchical-v1" : "system-language-model"
            if selected == "codex_chatgpt" {
                do {
                    (summary, model) = try await CodexCompanion.generate(timeline: timeline, evidenceRoot: evidenceRoot, includeScreens: preferences.codexIncludeScreens ?? true)
                } catch is CancellationError { throw CancellationError() }
                catch { throw AnalysisRejected(error.localizedDescription) }
            }
            if selected == "apple_foundation_models" {
                summary.summary = try await FoundationSummary.generate(timeline: timeline)
            }
            if pending {
                summary.summary = "【一部の音声が未文字起こし】確定済みの発話だけから作成した要約です。\n\n" + summary.summary
            }
            try store.saveSummary(.init(
                meetingId: job.meetingId,
                provider: selected,
                model: model,
                promptVersion: selected == "codex_chatgpt" ? "codex-minutes-v2" : "heuristic-sections-v1",
                value: summary
            ))
        }
        await worker.register(kind: "export") { job in
            try Self.export(meetingID: job.meetingId, store: store, evidenceRoot: evidenceRoot)
        }
    }

    public func stop() async { scheduler?.cancel(); scheduler = nil; await worker.stop() }

    private static func hasPendingAudio(meeting: Meeting, evidenceRoot: URL) throws -> Bool {
        let directory = evidenceRoot.appendingPathComponent(meeting.id).appendingPathComponent("Audio")
        let closed = ![.capturing, .finalizing].contains(meeting.status)
        for folder in [directory] + ["legacy-systemAudio", "legacy-microphone"].map({ directory.appendingPathComponent($0) }) {
            let chunks = try AudioArchiveWriter.chunks(in: folder, recoverOpen: closed)
            if try !AudioArchiveWriter.corruptUnits(in: folder).isEmpty { return true }
            if chunks.contains(where: { !FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.id).done").path) }) { return true }
        }
        return closed && ["system.caf", "microphone.caf"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) &&
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent("\($0).imported").path)
        }
    }

    private static func importLegacy(in directory: URL, only: String) throws {
        for (name, kind) in [("system.caf", CaptureOutputKind.systemAudio), ("microphone.caf", .microphone)] where name == only {
            let file = directory.appendingPathComponent(name)
            let marker = directory.appendingPathComponent("\(name).imported")
            guard FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: marker.path) else { continue }
            // Stage each track before publishing its chunks. Rename makes restart
            // safe; a track already imported is never imported twice.
            let staging = directory.appendingPathComponent("import-\(kind.rawValue)")
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            let writer = try AudioArchiveWriter(directory: staging)
            let audio = try AVAudioFile(forReading: file)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { throw CocoaError(.fileReadCorruptFile) }
            var frames: Int64 = 0
            while audio.framePosition < audio.length {
                try audio.read(into: buffer)
                try writer.write(buffer, kind: kind, timestampMs: Int64(Double(frames) / audio.processingFormat.sampleRate * 1000))
                frames += Int64(buffer.frameLength)
            }
            writer.finish()
            if let error = writer.lastError { throw NSError(domain: "AudioArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            // Publish the directory atomically; readers include these directories.
            let published = directory.appendingPathComponent("legacy-\(kind.rawValue)")
            if !FileManager.default.fileExists(atPath: published.path) { try FileManager.default.moveItem(at: staging, to: published) }
            else { try FileManager.default.removeItem(at: staging) }
            try Data().write(to: marker, options: .atomic)
        }
    }

    private static func transcribe(meetingID: String, store: MeetingStore, evidenceRoot: URL, provider: any FileTranscriber) async throws {
        guard let meeting = try store.meeting(id: meetingID) else { throw MeetingAnalysisRuntimeError.meetingNotFound(meetingID) }
        let directory = evidenceRoot.appendingPathComponent(meetingID).appendingPathComponent("Audio")
        let closed = ![.capturing, .finalizing].contains(meeting.status)
        var failures: [String] = []
        if closed {
            for name in ["system.caf", "microphone.caf"] {
                do { try importLegacy(in: directory, only: name) } catch { failures.append(error.localizedDescription) }
            }
        }
        let directories = [directory] + ["legacy-systemAudio", "legacy-microphone"].map { directory.appendingPathComponent($0) }
        var processed = 0
        var totalChunks = 0
        for folder in directories {
            let chunks: [AudioChunk]
            do { chunks = try AudioArchiveWriter.chunks(in: folder, recoverOpen: closed) }
            catch { failures.append(error.localizedDescription); continue }
            failures.append(contentsOf: try AudioArchiveWriter.corruptUnits(in: folder))
            totalChunks += chunks.count
            for chunk in chunks {
                try Task.checkCancellation()
                let receipt = folder.appendingPathComponent("\(chunk.id).done")
                guard !FileManager.default.fileExists(atPath: receipt.path) else { continue }
                let attemptFile = folder.appendingPathComponent("\(chunk.id).attempt")
                let attempts = (try? String(contentsOf: attemptFile, encoding: .utf8)).flatMap(Int.init) ?? 0
                if attempts >= 3 { failures.append("\(chunk.id): 再試行上限。手動復旧してください。"); continue }
                guard processed < 4 else { continue }
                processed += 1
                do {
                    try Data(String(attempts + 1).utf8).write(to: attemptFile, options: .atomic)
                    let file = folder.appendingPathComponent(chunk.fileName)
                    let silent = try isSilent(file)
                    let result = silent ? OfflineTranscript(text: "", startedAtMs: 0, endedAtMs: 0) :
                        try await withTranscriptionDeadline { try await provider.transcribe(file: file) }
                    // An empty result for non-silent input remains retryable.
                    if !silent && result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw MeetingAnalysisRuntimeError.transcriptionEmpty(meetingID)
                    }
                    var text = result.text
                    let source: AudioSource = chunk.kind == CaptureOutputKind.microphone.rawValue ? .microphone : .system
                    var start = min(chunk.endedAtMs, chunk.startedAtMs + max(0, result.startedAtMs))
                    if (chunk.overlapMs ?? 0) > 0,
                       let previous = try store.transcripts(meetingId: meetingID).last(where: {
                           $0.id != chunk.id && $0.source == source && $0.timeRange.startedAtMs < start &&
                           ($0.timeRange.endedAtMs ?? 0) > start
                       }) {
                        let limit = min(Int(Double(chunk.overlapMs ?? 0) / 1000 * 12), min(previous.text.count, text.count))
                        if limit >= 4 {
                            for length in stride(from: limit, through: 4, by: -1) where previous.text.suffix(length) == text.prefix(length) {
                                text = String(text.dropFirst(length))
                                start = max(start, previous.timeRange.endedAtMs ?? start)
                                break
                            }
                        }
                    }
                    let event = MeetingCore.TranscriptEvent(id: chunk.id, meetingId: meetingID,
                        timeRange: .init(startedAtMs: start, endedAtMs: max(start, min(chunk.endedAtMs, chunk.startedAtMs + result.endedAtMs))),
                        speaker: source == .microphone ? .self : .remote, text: text, source: source, isFinal: true)
                    try store.saveRecoveredTranscript(event)
                    if !silent { _ = try store.associateVisibleScreens(transcriptId: event.id) }
                    try JSONEncoder().encode(["provider": provider.provider, "status": silent ? "silence" : "completed"])
                        .write(to: receipt, options: .atomic)
                    try? FileManager.default.removeItem(at: folder.appendingPathComponent("\(chunk.id).error"))
                } catch {
                    if error is CancellationError { try? Data(String(attempts).utf8).write(to: attemptFile, options: .atomic); throw error }
                    failures.append("\(chunk.kind) @\(chunk.startedAtMs): \(error.localizedDescription)")
                    try? Data(error.localizedDescription.utf8).write(to: folder.appendingPathComponent("\(chunk.id).error"), options: .atomic)
                }
            }
        }
        if closed {
            for (folderName, source) in [("legacy-systemAudio", AudioSource.system), ("legacy-microphone", .microphone)] {
                let folder = directory.appendingPathComponent(folderName)
                let marker = folder.appendingPathComponent("retired-legacy")
                guard !FileManager.default.fileExists(atPath: marker.path) else { continue }
                let chunks = try AudioArchiveWriter.chunks(in: folder)
                if !chunks.isEmpty && chunks.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent("\($0.id).done").path) }) {
                    try store.retireLegacyTranscripts(meetingId: meetingID, source: source, keeping: chunks.map(\.id))
                    try Data().write(to: marker, options: .atomic)
                }
            }
        }
        if closed && totalChunks == 0 && failures.isEmpty { throw MeetingAnalysisRuntimeError.audioArchiveMissing(meetingID) }
        if !failures.isEmpty { throw NSError(domain: "Transcription", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]) }
    }

    private static func isSilent(_ url: URL) throws -> Bool {
        let audio = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096) else { return false }
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard let channels = buffer.floatChannelData else { return false }
            for c in 0..<Int(buffer.format.channelCount) {
                for f in 0..<Int(buffer.frameLength) where abs(channels[c][f]) > 0.000_01 { return false }
            }
        }
        return true
    }

    private func applyRetention() throws {
        let days = try settings.load().retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for meeting in try store.meetings(limit: 10_000) {
            guard let ended = meeting.endedAt, ended < cutoff,
                  [.completed, .partiallyCompleted, .interrupted, .failed].contains(meeting.status),
                  UUID(uuidString: meeting.id) != nil else { continue }
            let busy = try ["transcribe", "summarize", "export"].contains { kind in
                guard let job = try store.latestAnalysisJob(meetingId: meeting.id, kind: kind) else { return false }
                return [.pending, .processing].contains(job.status)
            }
            if busy { continue }
            let directory = evidenceRoot.appendingPathComponent(meeting.id)
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            try store.deleteMeeting(id: meeting.id)
        }
    }

    /// Deterministic hook used by tests and one-shot clients.
    @discardableResult public func processNext(now: Date = Date()) async throws -> Bool {
        await configureHandlers()
        return try await worker.runOnce(now: now)
    }

    private static func export(meetingID: String, store: MeetingStore, evidenceRoot: URL) throws {
        let safe = meetingID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, safe == meetingID else { throw MeetingAnalysisRuntimeError.unsafeMeetingID(meetingID) }
        guard let timeline = try store.timeline(meetingId: meetingID) else {
            throw MeetingAnalysisRuntimeError.meetingNotFound(meetingID)
        }
        let directory = evidenceRoot.appendingPathComponent(safe, isDirectory: true).appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let transcript = timeline.transcripts
            .filter { $0.isFinal && $0.possibleEchoOf == nil }
            .sorted { $0.timeRange.startedAtMs < $1.timeRange.startedAtMs }
            .map { event in
                let seconds = event.timeRange.startedAtMs / 1_000
                return "[\(String(format: "%02d:%02d", seconds / 60, seconds % 60))] \(event.speaker.rawValue): \(event.text)"
            }
            .joined(separator: "\n\n")
        try Data(transcript.utf8).write(to: directory.appendingPathComponent("transcript.md"), options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(timeline).write(to: directory.appendingPathComponent("timeline.json"), options: .atomic)

        let value = try store.activeSummary(meetingId: meetingID)
        let summary = value.map(summaryMarkdown) ?? "# Summary\n\nSummary has not been generated.\n"
        try Data(summary.utf8).write(to: directory.appendingPathComponent("summary.md"), options: .atomic)
    }

    private static func summaryMarkdown(_ summary: MeetingCore.MeetingSummary) -> String {
        func section(_ title: String, _ items: [MeetingCore.SummaryItem]) -> String {
            "## \(title)\n\n" + (items.isEmpty ? "- None" : items.map { "- \($0.text)" }.joined(separator: "\n"))
        }
        let discussions = (summary.discussions ?? []).map { "## \($0.title)\n\n\($0.summary)\n\n根拠: \($0.evidenceIds.joined(separator: ", "))" }
        return (["# 議事録\n\n\(summary.summary)"] + discussions + [section("Decisions", summary.decisions),
                section("Action Items", summary.actionItems), section("Open Questions", summary.openQuestions)])
            .joined(separator: "\n\n") + "\n"
    }
}
