import Foundation
import XCTest
@testable import MeetingCore

final class MeetingCoreTests: XCTestCase {
    func testTranscriptJSONUsesCanonicalFlatTimeRange() throws {
        let event = TranscriptEvent(id: "t1", meetingId: "m1", revision: 2, timeRange: .init(startedAtMs: 100, endedAtMs: 250), speaker: .self, text: "hello", source: .microphone, isFinal: true)
        let data = try JSONEncoder().encode(event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["startedAtMs"] as? Int, 100)
        XCTAssertEqual(object["type"] as? String, "speech")
        XCTAssertNil(object["timeRange"])
        XCTAssertEqual(try JSONDecoder().decode(TranscriptEvent.self, from: data), event)
    }

    func testAssociatesAllOverlappingScreens() {
        let transcript = TranscriptEvent(id: "t", meetingId: "m", timeRange: .init(startedAtMs: 100, endedAtMs: 300), text: "x", source: .system)
        let screens = [
            ScreenEvent(id: "a", meetingId: "m", timeRange: .init(startedAtMs: 0, endedAtMs: 150), imagePath: "a.webp"),
            ScreenEvent(id: "b", meetingId: "m", timeRange: .init(startedAtMs: 150, endedAtMs: 400), imagePath: "b.webp"),
            ScreenEvent(id: "c", meetingId: "m", timeRange: .init(startedAtMs: 500), imagePath: "c.webp")
        ]
        let refs = ScreenAssociator.visibleScreens(for: transcript, screens: screens)
        XCTAssertEqual(refs.map(\.screenId), ["b", "a"])
        XCTAssertEqual(refs.map(\.overlapMs), [150, 50])
    }

    func testSQLiteRoundTripRevisionAssociationAndRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore(path: directory.appendingPathComponent("test.sqlite").path)
        XCTAssertEqual(store.schemaVersion, 2)
        var meeting = Meeting(id: "m", title: "Demo", status: .capturing)
        try store.save(meeting)
        try store.save(ScreenEvent(id: "s1", meetingId: "m", timeRange: .init(startedAtMs: 0, endedAtMs: 200), imagePath: "s1.webp"))
        try store.save(ScreenEvent(id: "s2", meetingId: "m", timeRange: .init(startedAtMs: 200, endedAtMs: 500), imagePath: "s2.webp"))
        var transcript = TranscriptEvent(id: "t", meetingId: "m", revision: 1, timeRange: .init(startedAtMs: 150, endedAtMs: 300), speaker: .remote, text: "part", source: .system)
        try store.save(transcript)
        transcript.revision = 2; transcript.text = "final"; transcript.isFinal = true
        try store.save(transcript)
        XCTAssertEqual(Set(try store.associateVisibleScreens(transcriptId: "t").map(\.screenId)), Set(["s1", "s2"]))
        let timeline = try XCTUnwrap(store.timeline(meetingId: "m"))
        XCTAssertEqual(timeline.transcripts.first?.revision, 2)
        XCTAssertEqual(timeline.transcripts.first?.screenRefs.count, 2)
        XCTAssertThrowsError(try store.save(TranscriptEvent(id: "t", meetingId: "m", revision: 1, timeRange: .init(startedAtMs: 0), text: "late", source: .system)))
        try store.enqueue(AnalysisJob(id: "j", meetingId: "m", kind: "ocr", status: .processing))
        XCTAssertEqual(try store.recoverInterruptedWork(), RecoveryReport(interruptedMeetingIds: ["m"], recoveredJobCount: 1))
        meeting = try XCTUnwrap(store.meeting(id: "m"))
        XCTAssertEqual(meeting.status, .interrupted)
    }

    func testForeignKeysRejectOrphanEvidence() throws {
        let store = try MeetingStore(path: ":memory:")
        try store.save(Meeting(id: "m"))
        try store.save(ScreenEvent(id: "s", meetingId: "m", timeRange: .init(startedAtMs: 0), imagePath: "s.webp"))
        XCTAssertThrowsError(try store.save(ScreenEvent(id: "orphan", meetingId: "missing", timeRange: .init(startedAtMs: 0), imagePath: "x")))
    }

    func testAnalysisJobDeduplicatesOnlyActiveWork() throws {
        let store = try MeetingStore(path: ":memory:")
        try store.save(Meeting(id: "m"))
        XCTAssertTrue(try store.enqueueIfNeeded(AnalysisJob(id: "first", meetingId: "m", kind: "summarize")))
        XCTAssertEqual(try store.latestAnalysisJob(meetingId: "m", kind: "summarize")?.id, "first")
        XCTAssertFalse(try store.enqueueIfNeeded(AnalysisJob(id: "duplicate", meetingId: "m", kind: "summarize")))
        _ = try store.claimNextAnalysisJob()
        try store.completeAnalysisJob(id: "first")
        XCTAssertTrue(try store.enqueueIfNeeded(AnalysisJob(id: "rerun", meetingId: "m", kind: "summarize")))
    }

    func testFinalizesLatestPartialTranscriptAtMeetingEnd() throws {
        let store = try MeetingStore(path: ":memory:")
        try store.save(Meeting(id: "m"))
        try store.save(TranscriptEvent(id: "partial", meetingId: "m", revision: 3,
                                       timeRange: .init(startedAtMs: 10, endedAtMs: 20),
                                       text: "latest partial", source: .microphone, isFinal: false))
        XCTAssertEqual(try store.finalizePartialTranscripts(meetingId: "m"), 1)
        XCTAssertEqual(try store.transcript(id: "partial")?.revision, 3)
        XCTAssertEqual(try store.transcript(id: "partial")?.isFinal, true)
    }

    func testReplacesTranscriptsAtomicallyForRecovery() throws {
        let store = try MeetingStore(path: ":memory:")
        try store.save(Meeting(id: "m"))
        try store.save(TranscriptEvent(id: "old", meetingId: "m", timeRange: .init(startedAtMs: 0),
                                       text: "old", source: .system, isFinal: true))
        let recovered = TranscriptEvent(id: "new", meetingId: "m", timeRange: .init(startedAtMs: 10),
                                        text: "recovered", source: .microphone, isFinal: true)
        try store.replaceTranscripts(meetingId: "m", with: [recovered])
        XCTAssertNil(try store.transcript(id: "old"))
        XCTAssertEqual(try store.transcripts(meetingId: "m"), [recovered])
    }
}
