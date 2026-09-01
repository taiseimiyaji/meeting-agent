import Foundation
import MeetingCore

/// Always-available local fallback. It is deliberately conservative: extracted
/// items keep evidence IDs and ambiguous statements stay in the overview.
public struct HeuristicMeetingSummarizer: Sendable {
    public init() {}

    public func summarize(_ timeline: Timeline) -> MeetingCore.MeetingSummary {
        let events = timeline.transcripts.filter(\.isFinal).sorted { $0.timeRange.startedAtMs < $1.timeRange.startedAtMs }
        let sentences = events.map { ($0, $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.1.isEmpty }
        let decisions = sentences.filter { containsAny($0.1, ["決定", "採用", "とする", "で進め", "合意"]) }
            .map { MeetingCore.SummaryItem(text: $0.1, evidenceIds: [$0.0.id]) }
        let actions = sentences.filter { containsAny($0.1, ["対応する", "実装する", "確認する", "調査する", "TODO", "やります", "します"]) }
            .map { MeetingCore.SummaryItem(text: $0.1, evidenceIds: [$0.0.id], assignee: $0.0.speaker == .self ? "self" : nil) }
        let questions = sentences.filter { $0.1.hasSuffix("?") || $0.1.hasSuffix("？") || containsAny($0.1, ["未決", "要確認"]) }
            .map { MeetingCore.SummaryItem(text: $0.1, evidenceIds: [$0.0.id]) }
        let overview = sentences.prefix(8).map(\.1).joined(separator: " ")
        let topics = Array(Set(timeline.screens.compactMap(\.ocr).flatMap { topicCandidates($0) })).sorted().prefix(12)
        return MeetingCore.MeetingSummary(
            summary: overview.isEmpty ? "確定した文字起こしはありません。" : overview,
            decisions: unique(decisions),
            actionItems: unique(actions),
            openQuestions: unique(questions),
            topics: Array(topics)
        )
    }

    private func containsAny(_ text: String, _ candidates: [String]) -> Bool {
        candidates.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private func unique(_ items: [MeetingCore.SummaryItem]) -> [MeetingCore.SummaryItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.text).inserted }
    }

    private func topicCandidates(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || ",、/|".contains($0) })
            .map(String.init)
            .filter { (2...40).contains($0.count) }
    }
}

/// Bounded local map/reduce summarizer for long meetings. Each section is
/// summarized independently, then reduced while preserving evidence IDs.
public struct HierarchicalHeuristicSummarizer: Sendable {
    public let planner: SectionPlanner

    public init(planner: SectionPlanner = .init()) { self.planner = planner }

    public func summarize(_ timeline: Timeline) -> MeetingCore.MeetingSummary {
        let sections = planner.plan(transcript: timeline.transcripts, screens: timeline.screens)
        guard !sections.isEmpty else { return HeuristicMeetingSummarizer().summarize(timeline) }
        let partials = sections.map { section -> MeetingCore.MeetingSummary in
            let transcriptIDs = Set(section.transcriptEventIDs)
            let screenIDs = Set(section.screenEventIDs)
            return HeuristicMeetingSummarizer().summarize(.init(
                meeting: timeline.meeting,
                transcripts: timeline.transcripts.filter { transcriptIDs.contains($0.id) },
                screens: timeline.screens.filter { screenIDs.contains($0.id) }
            ))
        }
        return .init(
            summary: uniqueStrings(partials.map(\.summary).filter { $0 != "確定した文字起こしはありません。" }).joined(separator: " "),
            decisions: uniqueItems(partials.flatMap(\.decisions)),
            actionItems: uniqueItems(partials.flatMap(\.actionItems)),
            openQuestions: uniqueItems(partials.flatMap(\.openQuestions)),
            topics: uniqueStrings(partials.flatMap(\.topics))
        )
    }

    private func uniqueItems(_ values: [MeetingCore.SummaryItem]) -> [MeetingCore.SummaryItem] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.text + "\u{0}" + $0.evidenceIds.joined(separator: ",")).inserted }
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
