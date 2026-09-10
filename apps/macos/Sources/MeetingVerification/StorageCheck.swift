@preconcurrency import AVFoundation
import Foundation
@preconcurrency import CoreVideo
import ImageIO
import MeetingCore
import MeetingPipeline
import MeetingAnalysis
import LocalAPI

func verifyLosslessStorage() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("storage-fixture-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let store = try MeetingStore(path: root.appendingPathComponent("store.sqlite").path)
    let meeting = Meeting(id: UUID().uuidString, endedAt: Date(), status: .completed)
    try store.save(meeting)
    let folder = root.appendingPathComponent(meeting.id).appendingPathComponent("Audio")
    let writer = try AudioArchiveWriter(directory: folder)
    // Include negative zero, infinities and NaN payloads; this is file packing,
    // so floating point conversion must never occur.
    let buffer = try pcm(seconds: 2)
    let bits: [UInt32] = [0, 0x80000000, 0x7fc01234, 0x7f800000, 0xff800000, 0x3eaaaaab]
    for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(bitPattern: bits[i % bits.count]) }
    try writer.enqueue(buffer, kind: .microphone, timestampMs: 0)
    writer.finish()
    try check(writer.archivedFrames == Int64(buffer.frameLength), "queued PCM is fully drained on stop")
    let chunk = try AudioArchiveWriter.chunks(in: folder).first!
    let raw = folder.appendingPathComponent(chunk.fileName)
    let original = try Data(contentsOf: raw)
    try check(try LosslessAudio.compact(raw), "repetitive CAF is packed losslessly")
    let restored = try LosslessAudio.materialize(raw)
    try check(try Data(contentsOf: restored.url) == original, "CAF headers and every float bit survive packing, including NaN and negative zero")
    restored.cleanup()
    try check(!fm.fileExists(atPath: restored.url.path), "restored working audio is removed after use")
    try AudioInventory.ensure(folder: folder, meetingId: meeting.id, store: store)
    try check(try store.audioStatistics(folder: folder.path).bytes < Int64(original.count), "audio index accounts for packed disk bytes")
    try check(try AudioInventory.pending(folder: folder, meetingId: meeting.id, store: store, recoverOpen: true, limit: 1).map(\.id) == [chunk.id], "pending work rebuilds from canonical sidecars")
    try Data("{\"provider\":\"fixture\"}".utf8).write(to: folder.appendingPathComponent("\(chunk.id).done"))
    try AudioInventory.record(chunk, folder: folder, meetingId: meeting.id, store: store)
    try check(try store.audioStatistics(folder: folder.path).completed == 1, "completion updates the index without rescanning history")
    let packed = raw.appendingPathExtension("lzfse")
    let goodPacked = try Data(contentsOf: packed)
    try Data(goodPacked.prefix(12)).write(to: packed)
    var rejected = false
    do { let bad = try LosslessAudio.materialize(raw); bad.cleanup() } catch { rejected = true }
    try check(rejected, "truncated packed audio is rejected before transcription")
    try goodPacked.write(to: packed)
    let reopened = try MeetingStore(path: root.appendingPathComponent("store.sqlite").path)
    try AudioInventory.ensure(folder: folder, meetingId: meeting.id, store: reopened)
    try check(try reopened.audioStatistics(folder: folder.path).completed == 1, "completion and packed size recover after reopening the database")

    let blocked = try AudioArchiveWriter(directory: root.appendingPathComponent("blocked"), checkSpace: { throw StorageCapacityError("fixture full") })
    try blocked.enqueue(try pcm(), kind: .microphone, timestampMs: 0)
    blocked.finish()
    try check(blocked.lastError == "fixture full" && blocked.archivedFrames == 0, "capacity failure becomes an explicit recording error")
    for _ in 0..<100 { blocked.recordFailure("fixture full") }
    let errors = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("blocked/errors.json")))
    try check(errors == ["fixture full"], "repeated disk failures do not amplify error log writes")
    var overflowRejected = false
    do { try StorageCapacity.require(at: root, extraBytes: .max) } catch { overflowRejected = true }
    try check(overflowRejected, "invalid restoration size cannot overflow capacity checks")

    let legacyFolder = root.appendingPathComponent("legacy")
    let legacyWriter = try AudioArchiveWriter(directory: legacyFolder)
    try legacyWriter.write(try pcm(), kind: .microphone, timestampMs: 0); legacyWriter.finish()
    let parts = try AudioArchiveWriter.chunks(in: legacyFolder)
    let legacy = root.appendingPathComponent("microphone.caf")
    try fm.copyItem(at: legacyFolder.appendingPathComponent(parts[0].fileName), to: legacy)
    try check(try LegacyAudioVerifier.retire(legacy, chunks: parts, folder: legacyFolder), "legacy original is retired only after full PCM coverage proof")
    do { let different = try AVAudioFile(forWriting: legacy, settings: buffer.format.settings); try different.write(from: pcm(sample: 0.2)) }
    try check(try !LegacyAudioVerifier.retire(legacy, chunks: parts, folder: legacyFolder) && fm.fileExists(atPath: legacy.path), "different legacy PCM is retained")

    let imageFolder = root.appendingPathComponent(meeting.id).appendingPathComponent("KeyFrames")
    let images = try KeyFrameWriter(directory: imageFolder)
    let (one, two) = try await images.fixtureIdenticalImages()
    try check(one == two, "identical screenshots share bytes without removing screen events")
    try store.save(ScreenEvent(id: "screen1", meetingId: meeting.id, timeRange: .init(startedAtMs: 1), imagePath: one.path))
    try store.save(ScreenEvent(id: "screen2", meetingId: meeting.id, timeRange: .init(startedAtMs: 2), imagePath: two.path))
    let repo = try LocalMeetingRepository(store: store, evidenceRoot: root)
    let preview = try repo.screenImage(id: "screen1", thumbnail: true)!
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(preview.data as CFData, nil)!, 0, nil)!
    try check(image.width == 640 && image.height == 360, "list previews are bounded to 640 pixels")
    try check(try repo.screenImage(id: "screen1", thumbnail: false)?.data == Data(contentsOf: one), "expanded screenshot retains exact source JPEG")
    try check(try store.screens(meetingId: meeting.id).count == 2, "shared images retain distinct event times")
    let speech = TranscriptEvent(id: "a", meetingId: meeting.id, timeRange: .init(startedAtMs: 0, endedAtMs: 2000), text: "変更しない発話", source: .system, isFinal: true)
    try store.save(speech)
    try check(try store.previousOverlappingTranscript(meetingId: meeting.id, source: .system, before: 1000, excluding: "b")?.id == "a", "indexed overlap query retains previous speech")
    try check(try store.previousOverlappingTranscript(meetingId: meeting.id, source: .microphone, before: 1000, excluding: "b") == nil, "overlap query never mixes audio sources")
    try store.saveSummary(.init(meetingId: meeting.id, provider: "fixture", value: .init(summary: String(repeating: "議事録の全文を保存。", count: 1000))))
    let current = MeetingCore.MeetingSummary(summary: "現在の議事録")
    try store.saveSummary(.init(meetingId: meeting.id, provider: "fixture", value: current))
    try store.maintainDatabase()
    try check(try store.activeSummary(meetingId: meeting.id) == current, "maintenance preserves the active minutes")
    func sql(_ statement: String) throws -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = [root.appendingPathComponent("store.sqlite").path, statement]
        task.standardOutput = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw VerificationError(message: "fixture SQL failed") }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try check(try sql("SELECT json_extract(payload_json,'$.storageCodec') FROM summaries WHERE is_active=0") == "lzfse", "inactive minutes are actually compressed")
    _ = try sql("UPDATE summaries SET is_active=1-is_active")
    try check(try store.activeSummary(meetingId: meeting.id)?.summary == String(repeating: "議事録の全文を保存。", count: 1000), "older minutes restore with exact text when activated")
    let boundedWriter = try AudioArchiveWriter(directory: root.appendingPathComponent("bounded"))
    defer { boundedWriter.finish() }
    let oversized = try pcm(seconds: 140)
    var bounded = false
    do { try boundedWriter.enqueue(oversized, kind: .microphone, timestampMs: 3000) } catch { bounded = true }
    try check(bounded, "audio queue refuses more than 8 MiB with an explicit error")
    let tempRoot = root.appendingPathComponent("temporary")
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let stale = tempRoot.appendingPathComponent("meeting-agent-codex-stale")
    let live = tempRoot.appendingPathComponent("meeting-agent-stt-live")
    let unknown = tempRoot.appendingPathComponent("meeting-agent-codex-unknown")
    for path in [stale, live, unknown] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
    try Data("{\"pid\":2147483647}".utf8).write(to: stale.appendingPathComponent("owner.lease"))
    try TemporaryWorkspace.mark(live)
    for path in [stale, live, unknown] { try fm.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: path.path) }
    try TemporaryWorkspace.clean(in: tempRoot)
    try check(!fm.fileExists(atPath: stale.path) && fm.fileExists(atPath: live.path) && fm.fileExists(atPath: unknown.path), "orphan cleanup retains active and unknown owners")
    let oldSettings = try JSONDecoder().decode(AgentSettings.self, from: Data("{\"sttProvider\":\"speech_analyzer\",\"summaryProvider\":\"codex_chatgpt\",\"retentionDays\":0,\"recoveryMode\":true}".utf8))
    try check((oldSettings.audioRetentionDays ?? 0) == 0, "existing settings never enable audio deletion implicitly")
    try StorageMaintenance.run(meetingId: meeting.id, root: root, store: store)
    print("Storage fixtures passed: byte-exact audio, guarded capacity, indexed recovery, legacy preservation and original screenshots.")
}

private extension KeyFrameWriter {
    func fixtureIdenticalImages() throws -> (URL, URL) {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        guard let pixel else { throw VerificationError(message: "pixel fixture") }
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), 180, CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return (try write(pixel, id: "first"), try write(pixel, id: "second"))
    }
}
