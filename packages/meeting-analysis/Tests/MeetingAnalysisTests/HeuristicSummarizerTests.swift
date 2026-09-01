import MeetingCore
import Testing
@testable import MeetingAnalysis

@Test func heuristicSummaryKeepsEvidenceReferences() {
    let meeting = Meeting(id: "m")
    let transcript = [
        TranscriptEvent(id: "decision", meetingId: "m", timeRange: .init(startedAtMs: 0, endedAtMs: 10), speaker: .remote, text: "Swiftで進めると決定しました", source: .system, isFinal: true),
        TranscriptEvent(id: "action", meetingId: "m", timeRange: .init(startedAtMs: 20, endedAtMs: 30), speaker: .self, text: "私がCaptureを実装します", source: .microphone, isFinal: true),
        TranscriptEvent(id: "question", meetingId: "m", timeRange: .init(startedAtMs: 40, endedAtMs: 50), speaker: .remote, text: "期限はいつですか？", source: .system, isFinal: true),
    ]
    let summary = HeuristicMeetingSummarizer().summarize(.init(meeting: meeting, transcripts: transcript, screens: []))
    #expect(summary.decisions.first?.evidenceIds == ["decision"])
    #expect(summary.actionItems.first?.assignee == "self")
    #expect(summary.openQuestions.first?.evidenceIds == ["question"])
}
