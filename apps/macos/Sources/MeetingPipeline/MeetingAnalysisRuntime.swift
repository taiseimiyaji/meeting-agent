import Foundation
import MeetingAnalysis
import MeetingCore

public enum MeetingAnalysisRuntimeError: LocalizedError {
    case meetingNotFound(String)
    case unsafeMeetingID(String)

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id): "Meeting \(id) was not found."
        case .unsafeMeetingID(let id): "Meeting ID is unsafe for export: \(id)"
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
        try await worker.start()
    }

    private func configureHandlers() async {
        let store = store
        await worker.register(kind: "summarize") { job in
            guard let timeline = try store.timeline(meetingId: job.meetingId) else {
                throw MeetingAnalysisRuntimeError.meetingNotFound(job.meetingId)
            }
            let summary = HeuristicMeetingSummarizer().summarize(timeline)
            try store.saveSummary(.init(
                meetingId: job.meetingId,
                provider: "local-heuristic",
                model: "v1",
                promptVersion: "heuristic-v1",
                value: summary
            ))
        }
        let evidenceRoot = evidenceRoot
        await worker.register(kind: "export") { job in
            try Self.export(meetingID: job.meetingId, store: store, evidenceRoot: evidenceRoot)
        }
    }

    public func stop() async { await worker.stop() }

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
