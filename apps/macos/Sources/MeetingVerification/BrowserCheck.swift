@preconcurrency import AVFoundation
import Foundation
import MeetingCapture
import MeetingCore
import LocalAPI
import MeetingPipeline

func browserServer(root: URL) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try MeetingStore(path: root.appendingPathComponent("fixture.sqlite").path)
    let evidence = root.appendingPathComponent("Meetings")
    let repository = try LocalMeetingRepository(store: store, evidenceRoot: evidence)
    let controller = LocalCaptureController(adapter: TestCapture(), store: store, evidenceRoot: evidence)
    let server = LocalAPIServer(repository: repository, capture: controller, port: 8766,
        credentials: .init(sessionToken: "tab-test-token", csrfToken: "tab-test-csrf"))
    try server.start()
    print("Synthetic browser fixture API: 127.0.0.1:8766")
    while !Task.isCancelled { try await Task.sleep(for: .seconds(1)); _ = server }
}

func verifyBrowserCapture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try MeetingStore(path: root.appendingPathComponent("test.sqlite").path)
    let evidence = root.appendingPathComponent("Meetings")
    let controller = LocalCaptureController(adapter: TestCapture(), store: store, evidenceRoot: evidence)
    try await controller.start(targetID: "browser-tab")
    let id = await controller.snapshot().meetingId!
    let samples: [Float] = (0..<4800).map { Float($0 % 77) / 100 }
    let data = samples.withUnsafeBytes { Data($0) }
    try await controller.browserPacket(meetingID: id, kind: "systemAudio", sequence: 0, timestamp: 0, rate: 48000, channels: 2, data: data)
    var rejected = false
    do { try await controller.browserPacket(meetingID: "other", kind: "systemAudio", sequence: 1, timestamp: 50, rate: 48000, channels: 2, data: data) } catch { rejected = true }
    try check(rejected, "browser packets cannot enter another meeting")
    rejected = false
    do { try await controller.browserPacket(meetingID: id, kind: "systemAudio", sequence: 0, timestamp: 0, rate: 48000, channels: 2, data: data) } catch { rejected = true }
    try check(rejected, "duplicate tab audio packets are rejected")
    try await controller.stopBrowser(meetingID: id, error: nil)
    let chunks = try AudioArchiveWriter.chunks(in: evidence.appendingPathComponent(id).appendingPathComponent("Audio"))
    try check(chunks.count == 1 && chunks[0].endedAtMs == 50, "browser PCM reaches the durable audio archive with its channel count and clock")
    let audio = try AVAudioFile(forReading: evidence.appendingPathComponent(id).appendingPathComponent("Audio").appendingPathComponent(chunks[0].fileName), commonFormat: .pcmFormatFloat32, interleaved: true)
    let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: UInt32(audio.length))!
    try audio.read(into: buffer)
    let restored = Data(bytes: buffer.audioBufferList.pointee.mBuffers.mData!, count: Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
    try check(restored == data, "browser stereo PCM survives HTTP-to-archive conversion byte for byte")
    try check(try store.meeting(id: id)?.status == .completed, "tab stop finalizes existing transcription pipeline")
    try await controller.start(targetID: "browser-tab")
    let next = await controller.snapshot().meetingId!
    rejected = false
    do { try await controller.stopBrowser(meetingID: id, error: nil) } catch { rejected = true }
    try check(rejected && next != id, "late browser stop cannot stop a newer meeting")
    try await controller.stopBrowser(meetingID: next, error: "fixture disconnect")
    try check(try store.meeting(id: next)?.status == .partiallyCompleted, "browser disconnect preserves a partial meeting rather than claiming complete recording")
}
