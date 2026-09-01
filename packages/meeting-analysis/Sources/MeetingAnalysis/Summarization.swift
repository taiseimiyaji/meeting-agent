import Foundation
import MeetingCore

public struct SummaryItem: Codable, Sendable, Equatable {
    public let text: String
    public let evidenceIds: [String]
    public let assignee: String?
    public let dueAt: Date?

    public init(text: String, evidenceIds: [String], assignee: String? = nil, dueAt: Date? = nil) {
        self.text = text
        self.evidenceIds = evidenceIds
        self.assignee = assignee
        self.dueAt = dueAt
    }
}

public struct MeetingSummary: Codable, Sendable, Equatable {
    public let summary: String
    public let decisions: [SummaryItem]
    public let actionItems: [SummaryItem]
    public let openQuestions: [SummaryItem]
    public let topics: [String]
}

public struct SummarySection: Sendable, Equatable {
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let transcriptEventIDs: [String]
    public let screenEventIDs: [String]
}

public struct SectionPlanner: Sendable {
    public let maximumDurationMs: Int64
    public let silenceBoundaryMs: Int64
    public let overlapMs: Int64

    public init(maximumDurationMs: Int64 = 600_000, silenceBoundaryMs: Int64 = 15_000, overlapMs: Int64 = 30_000) {
        self.maximumDurationMs = maximumDurationMs
        self.silenceBoundaryMs = silenceBoundaryMs
        self.overlapMs = overlapMs
    }

    public func plan(transcript: [TranscriptEvent], screens: [ScreenEvent]) -> [SummarySection] {
        let finalTranscript = transcript.filter(\.isFinal).sorted { $0.timeRange.startedAtMs < $1.timeRange.startedAtMs }
        guard let first = finalTranscript.first, let last = finalTranscript.last else { return [] }
        let meetingStart = first.timeRange.startedAtMs
        let meetingEnd = last.timeRange.endedAtMs ?? last.timeRange.startedAtMs
        var boundaries = Set<Int64>([meetingStart, meetingEnd])
        for pair in zip(finalTranscript, finalTranscript.dropFirst()) {
            let previousEnd = pair.0.timeRange.endedAtMs ?? pair.0.timeRange.startedAtMs
            if pair.1.timeRange.startedAtMs - previousEnd >= silenceBoundaryMs {
                boundaries.insert(pair.1.timeRange.startedAtMs)
            }
        }
        for screen in screens { boundaries.insert(screen.timeRange.startedAtMs) }
        var cursor = meetingStart
        while cursor + maximumDurationMs < meetingEnd {
            cursor += maximumDurationMs
            boundaries.insert(cursor)
        }
        let ordered = boundaries.sorted()
        return zip(ordered, ordered.dropFirst()).map { start, end in
            let expandedStart = max(meetingStart, start - overlapMs)
            let expandedEnd = min(meetingEnd, end + overlapMs)
            return SummarySection(
                startedAtMs: expandedStart,
                endedAtMs: expandedEnd,
                transcriptEventIDs: finalTranscript.filter {
                    ($0.timeRange.endedAtMs ?? $0.timeRange.startedAtMs) >= expandedStart && $0.timeRange.startedAtMs <= expandedEnd
                }.map(\.id),
                screenEventIDs: screens.filter {
                    ($0.timeRange.endedAtMs ?? $0.timeRange.startedAtMs) >= expandedStart && $0.timeRange.startedAtMs <= expandedEnd
                }.map(\.id)
            )
        }
    }
}

public protocol MeetingSummarizer: Sendable {
    var provider: String { get }
    var model: String { get }
    var promptVersion: String { get }
    func summarize(timeline: Timeline, sections: [SummarySection]) async throws -> MeetingSummary
}
