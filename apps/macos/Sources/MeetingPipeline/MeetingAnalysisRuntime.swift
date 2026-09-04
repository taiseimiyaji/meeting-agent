import Foundation
import MeetingAnalysis
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
        case .transcriptionEmpty(let id): "Speech Recognition returned no text for meeting \(id)."
        }
    }
}

/// Registers the always-available local analysis jobs and owns their persistent
/// polling worker for the application lifetime.
public final class MeetingAnalysisRuntime: @unchecked Sendable {
    private let worker: PersistentAnalysisWorker
    private let store: MeetingStore
    private let evidenceRoot: URL

    public init(store: MeetingStore, evidenceRoot: URL, pollInterval: Duration = .milliseconds(250)) throws {
        self.store = store
        self.evidenceRoot = evidenceRoot.standardizedFileURL
        try FileManager.default.createDirectory(at: self.evidenceRoot, withIntermediateDirectories: true)
        worker = PersistentAnalysisWorker(store: store, pollInterval: pollInterval)
    }

    public func start() async throws {
        await configureHandlers()
        try enqueueMissingTranscriptions()
        try enqueueMissingSummaries()
        try await worker.start()
    }

    /// Repairs meetings created by older builds that completed without a
    /// summarize job. Safe to call repeatedly because active jobs are deduped.
    @discardableResult public func enqueueMissingSummaries() throws -> Int {
        var count = 0
        for meeting in try store.meetings(limit: 10_000) {
            guard [.completed, .partiallyCompleted, .interrupted].contains(meeting.status),
                  try store.activeSummary(meetingId: meeting.id) == nil else { continue }
            if try store.transcripts(meetingId: meeting.id).isEmpty,
               Self.hasAudio(meetingID: meeting.id, evidenceRoot: evidenceRoot) { continue }
            if try store.enqueueIfNeeded(.init(meetingId: meeting.id, kind: "summarize", priority: 2)) { count += 1 }
        }
        return count
    }

    @discardableResult public func enqueueMissingTranscriptions() throws -> Int {
        var count = 0
        for meeting in try store.meetings(limit: 10_000) {
            guard [.completed, .partiallyCompleted, .interrupted].contains(meeting.status),
                  try store.transcripts(meetingId: meeting.id).isEmpty,
                  Self.hasAudio(meetingID: meeting.id, evidenceRoot: evidenceRoot) else { continue }
            if try store.enqueueIfNeeded(.init(meetingId: meeting.id, kind: "transcribe", priority: 3)) { count += 1 }
        }
        return count
    }

    private func configureHandlers() async {
        let store = store
        let evidenceRoot = evidenceRoot
        await worker.register(kind: "transcribe") { job in
            try await Self.transcribe(meetingID: job.meetingId, store: store, evidenceRoot: evidenceRoot)
            _ = try store.enqueueIfNeeded(.init(meetingId: job.meetingId, kind: "summarize", priority: 2))
        }
        await worker.register(kind: "summarize") { job in
            guard let timeline = try store.timeline(meetingId: job.meetingId) else {
                throw MeetingAnalysisRuntimeError.meetingNotFound(job.meetingId)
            }
            let summary = HierarchicalHeuristicSummarizer().summarize(timeline)
            try store.saveSummary(.init(
                meetingId: job.meetingId,
                provider: "local-heuristic",
                model: "hierarchical-v1",
                promptVersion: "heuristic-sections-v1",
                value: summary
            ))
        }
        await worker.register(kind: "export") { job in
            try Self.export(meetingID: job.meetingId, store: store, evidenceRoot: evidenceRoot)
        }
    }

    public func stop() async { await worker.stop() }

    private static func hasAudio(meetingID: String, evidenceRoot: URL) -> Bool {
        let directory = evidenceRoot.appendingPathComponent(meetingID).appendingPathComponent("Audio")
        return ["system.caf", "microphone.caf"].contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private static func transcribe(meetingID: String, store: MeetingStore, evidenceRoot: URL) async throws {
        let directory = evidenceRoot.appendingPathComponent(meetingID).appendingPathComponent("Audio")
        let inputs: [(String, Speaker, AudioSource)] = [
            ("system.caf", .remote, .system), ("microphone.caf", .self, .microphone)
        ]
        let available = inputs.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.0).path) }
        guard !available.isEmpty else { throw MeetingAnalysisRuntimeError.audioArchiveMissing(meetingID) }

        let transcriber = AppleSpeechFileTranscriber()
        var events: [MeetingCore.TranscriptEvent] = []
        for (name, speaker, source) in available {
            let result = try await transcriber.transcribe(file: directory.appendingPathComponent(name))
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            events.append(.init(meetingId: meetingID,
                                timeRange: .init(startedAtMs: result.startedAtMs, endedAtMs: result.endedAtMs),
                                speaker: speaker, text: result.text, source: source, isFinal: true))
        }
        guard !events.isEmpty else { throw MeetingAnalysisRuntimeError.transcriptionEmpty(meetingID) }
        try store.replaceTranscripts(meetingId: meetingID, with: events)
        for event in events { _ = try? store.associateVisibleScreens(transcriptId: event.id) }
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
            .filter(\.isFinal)
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
        return ["# Summary\n\n\(summary.summary)", section("Decisions", summary.decisions),
                section("Action Items", summary.actionItems), section("Open Questions", summary.openQuestions)]
            .joined(separator: "\n\n") + "\n"
    }
}
