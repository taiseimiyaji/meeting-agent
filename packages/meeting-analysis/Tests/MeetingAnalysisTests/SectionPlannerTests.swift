import Foundation
import MeetingCore
import Testing
@testable import MeetingAnalysis

@Test func plannerUsesScreenAndSilenceBoundariesWithOverlap() {
    let meeting = Meeting(id: "m1")
    let transcript = [
        TranscriptEvent(id: "t1", meetingId: "m1", timeRange: .init(startedAtMs: 0, endedAtMs: 10_000), text: "first", source: .microphone, isFinal: true),
        TranscriptEvent(id: "t2", meetingId: "m1", timeRange: .init(startedAtMs: 40_000, endedAtMs: 50_000), text: "second", source: .system, isFinal: true),
        TranscriptEvent(id: "partial", meetingId: "m1", timeRange: .init(startedAtMs: 45_000, endedAtMs: 48_000), text: "volatile", source: .system),
    ]
    let screens = [ScreenEvent(id: "s1", meetingId: "m1", timeRange: .init(startedAtMs: 20_000, endedAtMs: 50_000), imagePath: "s1.webp")]
    let timeline = Timeline(meeting: meeting, transcripts: transcript, screens: screens)
    let sections = SectionPlanner(maximumDurationMs: 600_000, silenceBoundaryMs: 15_000, overlapMs: 5_000)
        .plan(transcript: timeline.transcripts, screens: timeline.screens)
    #expect(sections.count == 3)
    #expect(sections.allSatisfy { !$0.transcriptEventIDs.contains("partial") })
    #expect(sections.contains { $0.screenEventIDs.contains("s1") })
}
