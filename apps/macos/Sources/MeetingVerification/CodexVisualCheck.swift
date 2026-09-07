import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import MeetingCore
import MeetingPipeline

/// Synthetic visual contract check, deliberately not a real-meeting accuracy claim.
func verifyCodexVisualSummary(helper: URL) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-visual-fixture-\(UUID().uuidString)")
    let meeting = Meeting(id: "synthetic-meeting", endedAt: Date(), status: .completed)
    let folder = root.appendingPathComponent(meeting.id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var screens: [ScreenEvent] = []
    for (index, ms) in [1000, 2000, 10000, 11000].enumerated() {
        let file = folder.appendingPathComponent("screen-\(index).jpg")
        try drawMeetingFixture(file, speaking: index < 2)
        screens.append(.init(id: "image-\(index)", meetingId: meeting.id, timeRange: .init(startedAtMs: Int64(ms)), imagePath: file.path))
    }
    let speech = [
        MeetingCore.TranscriptEvent(id: "speech-1", meetingId: meeting.id, timeRange: .init(startedAtMs: 1000, endedAtMs: 2000), text: "公開日は9月14日に決定します。", source: .system, isFinal: true),
        MeetingCore.TranscriptEvent(id: "speech-2", meetingId: meeting.id, timeRange: .init(startedAtMs: 10000, endedAtMs: 11000), text: "予算は次回相談しましょう。", source: .system, isFinal: true)
    ]
    let (summary, model) = try await CodexCompanion.generate(timeline: .init(meeting: meeting, transcripts: speech, screens: screens), evidenceRoot: root, includeScreens: true, helper: helper)
    try check(summary.decisions.contains { $0.evidenceIds.contains("speech-1") }, "live Codex decision cites the actual utterance")
    try check(summary.openQuestions.contains { $0.evidenceIds.contains("speech-2") }, "live Codex preserves unresolved budget")
    try check(summary.speakerAttributions?.contains { $0.transcriptId == "speech-1" && $0.name.contains("田中") } == true, "live Codex reads the active speaker's Japanese name from two screenshots")
    try check(summary.speakerAttributions?.contains { $0.transcriptId == "speech-2" } == false, "gallery without a speaking indicator stays unknown")
    let store = try MeetingStore(path: root.appendingPathComponent("fixture.sqlite").path)
    try store.save(meeting)
    try store.saveSummary(.init(meetingId: meeting.id, provider: "codex_chatgpt", model: model, value: summary))
    try check(try store.activeSummary(meetingId: meeting.id) == summary, "complete Codex result survives SQLite persistence")
}

private func drawMeetingFixture(_ url: URL, speaking: Bool) throws {
    let context = CGContext(data: nil, width: 1200, height: 700, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
    func label(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W6" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
    }
    label("Synthetic meeting — not a real recording", x: 35, y: 645, size: 24)
    for (i, name) in ["田中", "鈴木"].enumerated() {
        let x = CGFloat(35 + i * 590)
        let tile = CGRect(x: x, y: 140, width: 540, height: 430)
        context.setFillColor(CGColor(red: 0.17, green: 0.19, blue: 0.22, alpha: 1)); context.fill(tile)
        context.setStrokeColor(speaking && i == 0 ? CGColor(red: 0.1, green: 0.95, blue: 0.4, alpha: 1) : CGColor(gray: 0.3, alpha: 1)); context.setLineWidth(8); context.stroke(tile)
        label(name, x: x + 35, y: 185, size: 42)
        label(i == 0 ? "T" : "S", x: x + 230, y: 340, size: 72)
        if speaking && i == 0 { label("発話中 / Speaking  ▂▅▇▅", x: x + 25, y: 515, size: 27) }
    }
    label(speaking ? "Active speaker: 田中" : "参加者一覧 / No active speaker indicated", x: 35, y: 65, size: 28)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw VerificationError(message: "fixture image failed") }
}
