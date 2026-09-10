import Foundation
import MeetingCore

func verifyResourceBounds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(path: root.appendingPathComponent("resource.sqlite").path)
    for index in 0..<120 {
        let meeting = Meeting(id: "history-\(index)", endedAt: Date(), status: .completed)
        try store.save(meeting)
        if index > 0 { try store.saveSummary(.init(meetingId: meeting.id, provider: "local_heuristic", value: .init(summary: "完了"))) }
    }
    try check(try store.maintenanceMeetings().map(\.id) == ["history-0"], "maintenance excludes settled history and finds work beyond 100 UI rows")
    let meetingID = "history-0"
    try store.enqueue(.init(id: "failed-summary", meetingId: meetingID, kind: "summarize", status: .failed))
    try check(try store.maintenanceMeetings().isEmpty, "terminal failure is not retried by maintenance")
    try store.enqueue(.init(id: "retried-summary", meetingId: meetingID, kind: "summarize", status: .completed))
    try check(try store.maintenanceMeetings().map(\.id) == [meetingID], "historical failures do not hide work after a successful retry")
    for index in 0..<200 {
        try store.save(ScreenEvent(id: "screen-\(index)", meetingId: meetingID, timeRange: .init(startedAtMs: Int64(index)), imagePath: "/fixture.jpg", analysisStatus: .pending))
    }
    for index in 0..<200 {
        var screen = try store.nextPendingScreen(meetingId: meetingID)!
        guard screen.id == "screen-\(index)" else { throw VerificationError(message: "OCR order changed") }
        screen.analysisStatus = .completed
        try store.save(screen)
    }
    try check(try store.nextPendingScreen(meetingId: meetingID) == nil, "OCR queue drains without retaining completed tasks")
    let speech = TranscriptEvent(id: "remote", meetingId: meetingID, timeRange: .init(startedAtMs: 0, endedAtMs: 1000), text: "来週のリリースに向けて設計を決定しました。", source: .system, isFinal: true)
    try store.save(speech)
    _ = try store.timeline(meetingId: meetingID)
    var mic = speech; mic.id = "mic"; mic.source = .microphone
    try store.save(mic)
    try check(try store.timeline(meetingId: meetingID)?.transcripts.first(where: { $0.id == "mic" })?.possibleEchoOf == "remote", "timeline cache invalidates for late-arriving cross-track evidence")
    var screen = try store.screen(id: "screen-0")!; screen.ocr = "更新された画面"
    try store.save(screen)
    try check(try store.timeline(meetingId: meetingID)?.screens.first?.ocr == screen.ocr, "timeline cache invalidates for OCR changes")
    var events: [TranscriptEvent] = []
    for index in 0..<720 {
        var remote = speech; remote.id = "r\(index)"; remote.timeRange = .init(startedAtMs: Int64(index * 10000), endedAtMs: Int64(index * 10000 + 9000))
        var microphone = remote; microphone.id = "m\(index)"; microphone.source = .microphone
        events += [remote, microphone]
    }
    let start = Date()
    let marked = TranscriptEchoDetector.annotate(events.reversed())
    try check(marked.filter { $0.possibleEchoOf != nil }.count == 720, "two-hour synthetic transcript preserves all 720 duplicate annotations")
    print("Resource fixture: 1440 utterances / two-hour timestamps, echo processing \(Date().timeIntervalSince(start)) seconds")
}
