@preconcurrency import AVFoundation
import Foundation
import CoreMedia
import MeetingCapture
import MeetingCore
import MeetingPipeline
import LocalAPI

struct VerificationError: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationError(message: message) }
    print("PASS: \(message)")
}
func pcm(seconds: Double = 1, sample: Float = 0.1) throws -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(seconds * 16000))!
    buffer.frameLength = buffer.frameCapacity
    for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = sample }
    return buffer
}

actor TestCapture: MeetingCaptureAdapter {
    nonisolated let events: AsyncStream<CaptureEvent>
    nonisolated let providesStopEvent = true
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private var sink: (@Sendable (AudioEvent) -> Void)?
    init() { let pair = AsyncStream<CaptureEvent>.makeStream(); events = pair.stream; continuation = pair.continuation }
    func setAudioSink(_ sink: (@Sendable (AudioEvent) -> Void)?) -> Bool { self.sink = sink; return true }
    func start(configuration: CaptureConfiguration) async throws {}
    func stop() async throws { continuation.yield(.stopped) }
    func availableTargets() async throws -> [CaptureTarget] { [] }
    func metricsSnapshot() async -> CaptureMetricsSnapshot { .init() }
    func emit(_ buffer: AVAudioPCMBuffer, kind: CaptureOutputKind, ms: Int64) {
        sink?(.init(kind: kind, timestamp: .init(nanoseconds: UInt64(ms) * 1_000_000), presentationTime: .zero, sampleBuffer: nil, pcmBuffer: buffer))
    }
}
actor UnavailableLiveTranscriber: Transcriber {
    nonisolated let events = AsyncStream<MeetingCapture.TranscriptEvent> { _ in }
    private(set) var starts = 0
    func availability() async -> TranscriberAvailability { .init(authorization: .denied, localeSupported: false, recognizerAvailable: false, onDeviceRecognitionSupported: false) }
    func start() async throws { starts += 1; throw TranscriberError.recognizerUnavailable }
    nonisolated func consume(_ buffer: AVAudioPCMBuffer) async throws { throw TranscriberError.notRunning }
    func stop() async {}
}
actor TestFileTranscriber: FileTranscriber {
    nonisolated let provider = "verification"
    var failNegative: Bool
    private(set) var calls = 0
    init(failNegative: Bool = false) { self.failNegative = failNegative }
    func transcribe(file: URL) async throws -> OfflineTranscript {
        calls += 1
        let audio = try AVAudioFile(forReading: file)
        let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1)!
        try audio.read(into: buffer)
        if failNegative && buffer.floatChannelData![0][0] < 0 { throw VerificationError(message: "injected track failure") }
        return .init(text: "検証用の発話です", startedAtMs: 0, endedAtMs: Int64(Double(audio.length) / audio.processingFormat.sampleRate * 1000))
    }
}

@main struct Verification {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "summary-readiness" { try await verifySummaryReadiness(); return }
        let models = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MeetingAgentVerification/Models")
        if args.first == "prepare-whisper" {
            try await WhisperFileTranscriber(directory: models).prepareModel(); print("WhisperKit model ready"); return
        }
        if args.first == "prepare-analyzer" {
            if #available(macOS 26.0, *) { try await AnalyzerFileTranscriber.prepareModel(); print("SpeechAnalyzer model ready") }
            return
        }
        if args.first == "transcribe", args.count >= 3 {
            let provider: any FileTranscriber
            switch args[1] {
            case "whisperkit": provider = WhisperFileTranscriber(directory: models)
            case "speech_analyzer":
                guard #available(macOS 26.0, *) else { throw VerificationError(message: "requires macOS 26") }
                provider = AnalyzerFileTranscriber()
            default: provider = AppleSpeechFileTranscriber()
            }
            let repetitions = min(100, max(1, args.count > 3 ? Int(args[3]) ?? 1 : 1))
            let metrics = CaptureMetrics()
            for iteration in 0..<repetitions {
            let start = Date()
            do {
                let result = try await withTranscriptionDeadline(seconds: 120) { try await provider.transcribe(file: URL(fileURLWithPath: args[2])) }
                let snapshot = await metrics.snapshot()
                let json: [String: Any] = ["provider": provider.provider, "text": result.text, "iteration": iteration, "residentMemoryBytes": snapshot.residentMemoryBytes ?? 0,
                    "startedAtMs": result.startedAtMs, "endedAtMs": result.endedAtMs, "elapsedSeconds": Date().timeIntervalSince(start)]
                print(String(data: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), encoding: .utf8)!)
            } catch {
                print("Provider error: \(error.localizedDescription)"); throw error
            }
            }
            return
        }
        try await verifySummaryReadiness()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingVerification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(path: root.appendingPathComponent("db.sqlite").path)
        let evidence = root.appendingPathComponent("Meetings")
        let capture = TestCapture(), live = UnavailableLiveTranscriber()
        let meeting = Meeting()
        let pipeline = try MeetingPipeline(capture: capture, store: store,
            configuration: .init(keyFrameDirectory: evidence.appendingPathComponent(meeting.id).appendingPathComponent("KeyFrames")),
            systemTranscriber: live, microphoneTranscriber: live)
        try await pipeline.start(meeting: meeting, captureConfiguration: .init())
        let positive = try pcm(sample: 0.1), negative = try pcm(sample: -0.1)
        for i in 0..<3 {
            await capture.emit(positive, kind: .microphone, ms: Int64(7000 + i * 1000))
            await capture.emit(negative, kind: .systemAudio, ms: Int64(9000 + i * 1000))
        }
        try await pipeline.stop()
        try check(await live.starts == 0, "recording succeeds without starting unavailable live STT")
        let directory = evidence.appendingPathComponent(meeting.id).appendingPathComponent("Audio")
        let chunks = try AudioArchiveWriter.chunks(in: directory)
        try check(chunks.count == 2 && chunks.allSatisfy(\.closed), "stop closes and publishes both final audio units")
        for chunk in chunks {
            let audio = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.fileName))
            try check(audio.length == 48000, "all final audio samples are durable")
        }
        let failing = TestFileTranscriber(failNegative: true)
        let runtime = try MeetingAnalysisRuntime(store: store, evidenceRoot: evidence, fileTranscriber: failing)
        _ = try await runtime.processNext()
        try check(try store.transcripts(meetingId: meeting.id).count == 1, "one failing track does not discard the successful track")
        let retained = try store.transcripts(meetingId: meeting.id)[0]
        try check(retained.timeRange.startedAtMs == 7000, "audio unit retains its meeting clock offset")
        let recovered = TestFileTranscriber()
        let restart = try MeetingAnalysisRuntime(store: store, evidenceRoot: evidence, fileTranscriber: recovered)
        _ = try await restart.processNext(now: Date().addingTimeInterval(120))
        try check(try store.transcripts(meetingId: meeting.id).count == 2, "restart recovers the failed unit")
        try check(await recovered.calls == 1, "restart skips already completed units")
        try check(try store.transcript(id: retained.id)?.text == retained.text, "recovery preserves earlier evidence IDs")
        let repository = try LocalMeetingRepository(store: store, evidenceRoot: evidence)
        let progress = try repository.transcriptionProgress(meetingId: meeting.id)
        try check(progress.completedChunks == 2 && progress.failedChunks == 0 && progress.provider == "verification", "API reports actual unit progress and provider")
        var settings = AgentSettings(); settings.sttProvider = "speech_analyzer"
        try repository.saveSettings(settings)
        try check(try repository.settings() == settings, "settings persist to the backend")
        do {
            _ = try await withTranscriptionDeadline(seconds: 0.02) { try await Task.sleep(for: .seconds(10)); return true }
            throw VerificationError(message: "timeout failed")
        } catch FileTranscriptionError.timedOut { print("PASS: stalled provider has a bounded deadline") }
        // Silent audio is a successful empty unit, not an endless retry.
        let silentMeeting = Meeting(status: .completed)
        try store.save(silentMeeting)
        let silenceFolder = evidence.appendingPathComponent(silentMeeting.id).appendingPathComponent("Audio")
        let silenceWriter = try AudioArchiveWriter(directory: silenceFolder)
        try silenceWriter.write(try pcm(sample: 0), kind: .microphone, timestampMs: 4000)
        silenceWriter.finish()
        let silenceProvider = TestFileTranscriber()
        let silenceRuntime = try MeetingAnalysisRuntime(store: store, evidenceRoot: evidence, fileTranscriber: silenceProvider)
        try store.enqueue(.init(meetingId: silentMeeting.id, kind: "transcribe", priority: 10))
        _ = try await silenceRuntime.processNext(now: Date().addingTimeInterval(240))
        try check(await silenceProvider.calls == 0, "digital silence is checkpointed without sending it to ASR")
        try check(try repository.transcriptionProgress(meetingId: silentMeeting.id).completedChunks == 1, "silent units count as completed despite having no transcript")

        // A timestamp discontinuity must not squeeze two distant utterances together.
        let gapFolder = root.appendingPathComponent("gap-audio")
        let gapWriter = try AudioArchiveWriter(directory: gapFolder)
        try gapWriter.write(positive, kind: .microphone, timestampMs: 0)
        try gapWriter.write(positive, kind: .microphone, timestampMs: 10000)
        gapWriter.finish()
        let gapChunks = try AudioArchiveWriter.chunks(in: gapFolder)
        try check(gapChunks.count == 2 && gapChunks[1].startedAtMs == 10000, "audio gaps preserve wall-clock offsets")

        // Recover a writer interrupted before publishing its closed sidecar.
        let interruptedFolder = root.appendingPathComponent("interrupted-audio")
        var interruptedWriter: AudioArchiveWriter? = try AudioArchiveWriter(directory: interruptedFolder)
        try interruptedWriter?.write(positive, kind: .microphone, timestampMs: 12000)
        interruptedWriter = nil
        let interrupted = try AudioArchiveWriter.chunks(in: interruptedFolder, recoverOpen: true)
        try check(interrupted.count == 1 && interrupted[0].endedAtMs == 13000, "restart reconstructs the final open unit from actual CAF frames")

        let credentials = APICredentials(sessionToken: "verification-session", csrfToken: "verification-csrf")
        let controller = LocalCaptureController(adapter: TestCapture(), store: store, evidenceRoot: evidence)
        let router = APIRouter(repository: repository, capture: controller,
            security: APISecurityPolicy(credentials: credentials, allowedHosts: ["127.0.0.1:8765"], allowedOrigins: []))
        let activeMeeting = Meeting(status: .capturing)
        try store.save(activeMeeting)
        let rejection = await router.route(.init(method: .POST, target: "/api/meetings/\(activeMeeting.id)/transcribe",
            headers: ["Host": "127.0.0.1:8765", "Authorization": credentials.sessionToken, "X-CSRF-Token": credentials.csrfToken]))
        try check(rejection.status == 409, "manual transcription cannot race active capture")
        let settingsResponse = await router.route(.init(method: .GET, target: "/api/settings",
            headers: ["Host": "127.0.0.1:8765", "Authorization": credentials.sessionToken]))
        try check(settingsResponse.status == 200, "settings are available through the authenticated API")

        let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
        let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 4800)!
        stereo.frameLength = 4800
        for i in 0..<9600 { stereo.floatChannelData![0][i] = i % 2 == 0 ? 0.2 : -0.3 }
        let stereoFolder = root.appendingPathComponent("stereo")
        let stereoWriter = try AudioArchiveWriter(directory: stereoFolder)
        try stereoWriter.write(stereo, kind: .systemAudio, timestampMs: 8000)
        stereoWriter.finish()
        let stereoChunk = try AudioArchiveWriter.chunks(in: stereoFolder)[0]
        let stereoFile = try AVAudioFile(forReading: stereoFolder.appendingPathComponent(stereoChunk.fileName))
        let stereoRead = AVAudioPCMBuffer(pcmFormat: stereoFile.processingFormat, frameCapacity: 4800)!
        try stereoFile.read(into: stereoRead)
        try check(stereoFile.length == 4800 && stereoRead.floatChannelData![0][0] == 0.2 && stereoRead.floatChannelData![1][0] == -0.3, "interleaved system audio preserves both channels")

        let corruptID = UUID().uuidString
        try Data("broken".utf8).write(to: stereoFolder.appendingPathComponent("\(corruptID).json"))
        try check(try AudioArchiveWriter.chunks(in: stereoFolder).count == 1, "corrupt sidecar does not hide another valid audio unit")
        try check(try AudioArchiveWriter.corruptUnits(in: stereoFolder).count == 1, "corrupt sidecars are reported instead of treated as completed")

        // A 30-minute replay exercises the real writer without waiting 30 minutes.
        let longDirectory = root.appendingPathComponent("long-audio")
        let writer = try AudioArchiveWriter(directory: longDirectory)
        for i in 0..<1800 {
            try writer.write(positive, kind: .microphone, timestampMs: Int64(i * 1000))
            try writer.write(negative, kind: .systemAudio, timestampMs: Int64(i * 1000))
        }
        writer.finish()
        let longChunks = try AudioArchiveWriter.chunks(in: longDirectory)
        let frameCount = try longChunks.reduce(Int64(0)) { sum, chunk in
            sum + (try AVAudioFile(forReading: longDirectory.appendingPathComponent(chunk.fileName))).length
        }
        let overlapFrames = longChunks.reduce(Int64(0)) { $0 + ($1.overlapMs ?? 0) * 16 }
        try check(frameCount - overlapFrames == 57_600_000, "30-minute dual-track PCM replay has zero missing samples after accounting for overlap")
        for kind in ["microphone", "systemAudio"] {
            let track = longChunks.filter { $0.kind == kind }.sorted { $0.startedAtMs < $1.startedAtMs }
            try check(track.first?.startedAtMs == 0 && track.last?.endedAtMs == 1_800_000, "long replay preserves both ends of the meeting clock")
            try check(zip(track, track.dropFirst()).allSatisfy { $0.endedAtMs >= $1.startedAtMs }, "overlapped units cover the timeline without gaps")
        }
        try check(longChunks.map(\.id).count == Set(longChunks.map(\.id)).count, "audio unit IDs remain unique")
        print("All deterministic integration checks passed. Real ASR accuracy and wall-clock capture require separate evaluation.")
    }
}

func verifySummaryReadiness() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try MeetingStore(path: root.appendingPathComponent("test.sqlite").path)
    let evidence = root.appendingPathComponent("Meetings")
    let repository = try LocalMeetingRepository(store: store, evidenceRoot: evidence)
    var settings = AgentSettings(); settings.summaryProvider = "local_heuristic"
    try repository.saveSettings(settings)
    let runtime = try MeetingAnalysisRuntime(store: store, evidenceRoot: evidence)
    let meeting = Meeting(id: "waiting", endedAt: Date(), status: .completed)
    try store.save(meeting)
    let writer = try AudioArchiveWriter(directory: evidence.appendingPathComponent(meeting.id).appendingPathComponent("Audio"))
    try writer.write(try pcm(), kind: .microphone, timestampMs: 0); writer.finish()
    let text = "保存済みの発話からこの方針を採用することに決定しました。"
    try store.save(MeetingCore.TranscriptEvent(meetingId: meeting.id, timeRange: .init(startedAtMs: 0, endedAtMs: 1000), speaker: .self, text: text, source: .microphone, isFinal: true))
    try store.enqueue(AnalysisJob(id: "summary-waiting", meetingId: meeting.id, kind: "summarize"))
    let start = Date().addingTimeInterval(1)
    for i in 0..<6 { _ = try await runtime.processNext(now: start.addingTimeInterval(Double(i * 11))) }
    let waiting = try store.analysisJob(id: "summary-waiting")
    try check(waiting?.status == .pending && waiting?.retryCount == 0, "summary dependency waiting never consumes retry attempts")
    try check(waiting?.error == "文字起こしの完了を待っています。", "waiting has an actionable Japanese status instead of transcriptionEmpty")
    try check(try store.activeSummary(meetingId: meeting.id) == nil, "pending transcription is not summarized prematurely")
    try store.enqueue(AnalysisJob(meetingId: meeting.id, kind: "transcribe", status: .failed, error: "Some units failed"))
    _ = try await runtime.processNext(now: start.addingTimeInterval(80))
    let partial = try store.activeSummary(meetingId: meeting.id)
    try check(partial?.summary.contains("一部の音声が未文字起こし") == true && partial?.summary.contains(text) == true, "terminal ASR failure produces a clearly marked partial summary from available speech")
    try check(try store.analysisJob(id: "summary-waiting")?.status == .completed, "partial summary completes instead of failing transcriptionEmpty")
    let empty = Meeting(id: "empty", endedAt: Date(), status: .completed)
    try store.save(empty)
    try store.enqueue(AnalysisJob(id: "summary-empty", meetingId: empty.id, kind: "summarize"))
    _ = try await runtime.processNext(now: start.addingTimeInterval(90))
    let failed = try store.analysisJob(id: "summary-empty")
    try check(failed?.status == .failed && failed?.error?.contains("確定済みの文字起こしがありません") == true, "truly empty transcript reports the correct recovery action")
    try check(try store.activeSummary(meetingId: empty.id) == nil, "empty transcript cannot produce a fabricated summary")
    let recording = Meeting(id: "recording", status: .capturing)
    try store.save(recording)
    try store.enqueue(AnalysisJob(id: "summary-recording", meetingId: recording.id, kind: "summarize"))
    _ = try await runtime.processNext(now: start.addingTimeInterval(100))
    try check(try store.analysisJob(id: "summary-recording")?.error == "録音の終了を待っています。", "recording in progress is distinct from an empty transcript")
}
