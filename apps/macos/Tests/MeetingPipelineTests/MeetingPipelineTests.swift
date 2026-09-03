import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MeetingCapture
import MeetingCore
@testable import MeetingPipeline
import Testing

@Suite("Capture evidence pipeline")
struct MeetingPipelineTests {
    @Test("separate transcriber tracks upsert partial and final evidence")
    func transcriptPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore(path: directory.appendingPathComponent("meeting.sqlite").path)
        let capture = FakeCapture()
        let system = FakeTranscriber()
        let microphone = FakeTranscriber()
        let pipeline = try MeetingPipeline(
            capture: capture,
            store: store,
            configuration: .init(keyFrameDirectory: directory.appendingPathComponent("frames"), transcriptionFinalizationGraceMs: 0),
            systemTranscriber: system,
            microphoneTranscriber: microphone
        )
        let meeting = Meeting(status: .capturing)
        try await pipeline.start(meeting: meeting, captureConfiguration: .init())

        let id = UUID()
        await microphone.emit(.init(utteranceID: id, revision: 1, track: .localMicrophone,
                                    text: "途中", startedAtMs: 10, endedAtMs: 30, isFinal: false))
        await microphone.emit(.init(utteranceID: id, revision: 2, track: .localMicrophone,
                                    text: "確定", startedAtMs: 10, endedAtMs: 50, isFinal: true))
        let partialID = UUID()
        await system.emit(.init(utteranceID: partialID, revision: 1, track: .remoteSystemAudio,
                                text: "終了時の部分結果", startedAtMs: 20, endedAtMs: 60, isFinal: false))
        await waitUntil { (try? store.transcript(id: id.uuidString)?.revision) == 2 }
        await waitUntil { (try? store.transcript(id: partialID.uuidString)?.revision) == 1 }
        try await pipeline.stop()

        let storedTranscript = try store.transcript(id: id.uuidString)
        let transcript = try #require(storedTranscript)
        #expect(transcript.text == "確定")
        #expect(transcript.source == .microphone)
        #expect(transcript.speaker == .self)
        #expect(transcript.isFinal)
        #expect(try store.transcript(id: partialID.uuidString)?.isFinal == true)
        #expect(try store.meeting(id: meeting.id)?.status == .completed)
        #expect(try store.pendingAnalysisJobCount() == 1)
        #expect(await system.consumedCount == 0)
    }

    @Test("start failure records failed meeting and releases transcribers")
    func startFailureCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore(path: directory.appendingPathComponent("meeting.sqlite").path)
        let capture = FakeCapture(failsStart: true)
        let system = FakeTranscriber()
        let microphone = FakeTranscriber()
        let pipeline = try MeetingPipeline(capture: capture, store: store,
            configuration: .init(keyFrameDirectory: directory.appendingPathComponent("frames"), transcriptionFinalizationGraceMs: 0),
            systemTranscriber: system, microphoneTranscriber: microphone)
        let meeting = Meeting()

        await #expect(throws: FakeError.failed) {
            try await pipeline.start(meeting: meeting, captureConfiguration: .init())
        }
        #expect(try store.meeting(id: meeting.id)?.status == .failed)
        #expect(await system.stopCount == 1)
        #expect(await microphone.stopCount == 1)
    }

    @Test("stable frames are sampled and persisted once")
    func stableKeyFramePersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let processor = try KeyFrameProcessor(configuration: .init(
            keyFrameDirectory: directory,
            minimumFrameIntervalMs: 0,
            stabilityMs: 500
        ))
        let buffer = try makePixelBuffer(gray: 180)
        let first = VideoFrameEvent(timestamp: .init(nanoseconds: 0), presentationTime: .zero, pixelBuffer: buffer)
        let stable = VideoFrameEvent(timestamp: .init(nanoseconds: 500_000_000), presentationTime: CMTime(value: 1, timescale: 2), pixelBuffer: buffer)

        let initialResult = try await processor.consume(first)
        #expect(initialResult == nil)
        let stableResult = try await processor.consume(stable)
        let result = try #require(stableResult)
        #expect(result.timestampMs == 500)
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        let duplicateResult = try await processor.consume(stable)
        #expect(duplicateResult == nil)
    }

    @Test("persistent summarize and export handlers produce local artifacts")
    func analysisRuntimeHandlers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(path: root.appendingPathComponent("db.sqlite").path)
        let meeting = Meeting(status: .completed)
        try store.save(meeting)
        try store.save(MeetingCore.TranscriptEvent(
            meetingId: meeting.id,
            timeRange: .init(startedAtMs: 1_000, endedAtMs: 2_000),
            speaker: .self,
            text: "この方針で進めると決定します",
            source: .microphone,
            isFinal: true
        ))
        let runtime = try MeetingAnalysisRuntime(store: store, evidenceRoot: root.appendingPathComponent("Meetings"))

        try store.enqueue(MeetingCore.AnalysisJob(meetingId: meeting.id, kind: "summarize"))
        let summarized = try await runtime.processNext()
        #expect(summarized)
        let activeSummary = try store.activeSummary(meetingId: meeting.id)
        let summary = try #require(activeSummary)
        #expect(summary.decisions.count == 1)

        try store.enqueue(MeetingCore.AnalysisJob(meetingId: meeting.id, kind: "export"))
        let exported = try await runtime.processNext()
        #expect(exported)
        let export = root.appendingPathComponent("Meetings").appendingPathComponent(meeting.id).appendingPathComponent("Export")
        #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent("transcript.md").path))
        #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent("timeline.json").path))
        #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent("summary.md").path))
    }

    @Test("startup backfills summaries for meetings created by older builds")
    func summaryBackfill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(path: root.appendingPathComponent("db.sqlite").path)
        try store.save(Meeting(id: "old-completed", status: .completed))
        try store.save(Meeting(id: "old-partial", status: .partiallyCompleted))
        try store.save(Meeting(id: "still-capturing", status: .capturing))
        let runtime = try MeetingAnalysisRuntime(store: store, evidenceRoot: root.appendingPathComponent("Meetings"))

        #expect(try runtime.enqueueMissingSummaries() == 2)
        #expect(try runtime.enqueueMissingSummaries() == 0)
        #expect(try store.pendingAnalysisJobCount() == 2)
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makePixelBuffer(gray: UInt8) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &value)
        guard status == kCVReturnSuccess, let value else { throw FakeError.failed }
        CVPixelBufferLockBaseAddress(value, [])
        if let base = CVPixelBufferGetBaseAddress(value) {
            memset(base, Int32(gray), CVPixelBufferGetDataSize(value))
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 3, to: CVPixelBufferGetDataSize(value), by: 4) { bytes[offset] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
}

private enum FakeError: Error { case failed }

private actor FakeCapture: MeetingCaptureAdapter {
    nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let failsStart: Bool

    init(failsStart: Bool = false) {
        self.failsStart = failsStart
        let pair = AsyncStream<CaptureEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func availableTargets() async throws -> [CaptureTarget] { [] }
    func start(configuration: CaptureConfiguration) async throws { if failsStart { throw FakeError.failed } }
    func stop() async throws {}
    func metricsSnapshot() async -> CaptureMetricsSnapshot { .init() }
}

private actor FakeTranscriber: @preconcurrency Transcriber {
    nonisolated let events: AsyncStream<MeetingCapture.TranscriptEvent>
    private let continuation: AsyncStream<MeetingCapture.TranscriptEvent>.Continuation
    private(set) var consumedCount = 0
    private(set) var stopCount = 0
    init() {
        let pair = AsyncStream<MeetingCapture.TranscriptEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }
    func availability() async -> TranscriberAvailability {
        .init(authorization: .granted, localeSupported: true, recognizerAvailable: true, onDeviceRecognitionSupported: true)
    }
    func start() async throws {}
    func consume(_ buffer: AVAudioPCMBuffer) async throws { consumedCount += 1 }
    func stop() async { stopCount += 1 }
    func emit(_ event: MeetingCapture.TranscriptEvent) { continuation.yield(event) }
}
