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
