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

@Test func hierarchicalSummaryHandlesSixtyMinutesAndDeduplicatesOverlap() {
    let meetingID = "long-meeting"
    let meeting = Meeting(id: meetingID)
    var transcript: [TranscriptEvent] = []
    for minute in 0..<60 {
        let start = Int64(minute * 60_000)
        transcript.append(.init(
            id: "t-\(minute)", meetingId: meetingID,
            timeRange: .init(startedAtMs: start, endedAtMs: start + 20_000),
            speaker: minute.isMultiple(of: 2) ? .self : .remote,
            text: minute == 42 ? "担当者がリリース手順を確認すると決定しました" : "議題 \(minute)",
            source: minute.isMultiple(of: 2) ? .microphone : .system, isFinal: true
        ))
    }
    let screens = stride(from: 0, to: 60, by: 10).map { minute in
        ScreenEvent(id: "s-\(minute)", meetingId: meetingID,
                    timeRange: .init(startedAtMs: Int64(minute * 60_000), endedAtMs: Int64((minute + 10) * 60_000)),
                    imagePath: "s-\(minute).jpg", ocr: "Topic \(minute)")
    }
    let timeline = Timeline(meeting: meeting, transcripts: transcript, screens: screens)
    let planner = SectionPlanner(maximumDurationMs: 600_000, silenceBoundaryMs: 120_000, overlapMs: 30_000)
    let sections = planner.plan(transcript: transcript, screens: screens)
    let summary = HierarchicalHeuristicSummarizer(planner: planner).summarize(timeline)

    #expect(sections.count >= 6)
    #expect(summary.decisions.count == 1)
    #expect(summary.decisions.first?.evidenceIds == ["t-42"])
    #expect(!summary.topics.isEmpty)
}
