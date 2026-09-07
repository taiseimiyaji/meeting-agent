import Foundation
import MeetingAnalysis
import MeetingCapture
import MeetingCore

public enum MeetingPipelineError: LocalizedError {
    case alreadyRunning
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The meeting pipeline is already running."
        case .notRunning: "The meeting pipeline is not running."
        }
    }
}

public struct MeetingPipelineConfiguration: Sendable {
    public var keyFrameDirectory: URL
    public var minimumFrameIntervalMs: Int64
    public var changedPixelRatioThreshold: Double
    public var meanDifferenceThreshold: Double
    public var stabilityMs: Int64
    public var transcriptionFinalizationGraceMs: Int64
    public var liveTranscriptionEnabled: Bool = false

    public init(
        keyFrameDirectory: URL,
        minimumFrameIntervalMs: Int64 = 200,
        changedPixelRatioThreshold: Double = 0.08,
        meanDifferenceThreshold: Double = 0.035,
        stabilityMs: Int64 = 500,
        transcriptionFinalizationGraceMs: Int64 = 1_000
    ) {
        self.keyFrameDirectory = keyFrameDirectory
        self.minimumFrameIntervalMs = minimumFrameIntervalMs
        self.changedPixelRatioThreshold = changedPixelRatioThreshold
        self.meanDifferenceThreshold = meanDifferenceThreshold
        self.stabilityMs = stabilityMs
        self.transcriptionFinalizationGraceMs = max(0, transcriptionFinalizationGraceMs)
    }
}

/// Owns the durable capture path. Capture consumption never waits for OCR: a key
/// frame is persisted first and its analysis runs in an independent task.
public actor MeetingPipeline {
    private let capture: any MeetingCaptureAdapter
    private let store: MeetingStore
    private let systemTranscriber: any Transcriber
    private let microphoneTranscriber: any Transcriber
    private let frameProcessor: KeyFrameProcessor
    private let ocr: VisionTextRecognizer
    private let audioArchive: AudioArchiveWriter
    private let transcriptionFinalizationGraceMs: Int64

    private var meeting: Meeting?
    private var directAudio = false
    private var captureFailure: String?
    private let liveTranscriptionEnabled: Bool
    private var videoTask: Task<Void, Never>?
    private var videoContinuation: AsyncStream<VideoFrameEvent>.Continuation?
    private var eventTask: Task<Void, Never>?
    private var transcriptTasks: [Task<Void, Never>] = []
    private var ocrTasks: [Task<Void, Never>] = []
    private var activeScreen: ScreenEvent?
    private var systemAudioOriginMs: Int64?
    private var microphoneAudioOriginMs: Int64?

    public init(
        capture: any MeetingCaptureAdapter,
        store: MeetingStore,
        configuration: MeetingPipelineConfiguration,
        systemTranscriber: any Transcriber = AppleSpeechTranscriber(track: .remoteSystemAudio),
        microphoneTranscriber: any Transcriber = AppleSpeechTranscriber(track: .localMicrophone)
    ) throws {
        liveTranscriptionEnabled = configuration.liveTranscriptionEnabled
        self.capture = capture
        self.store = store
        self.systemTranscriber = systemTranscriber
        self.microphoneTranscriber = microphoneTranscriber
        frameProcessor = try KeyFrameProcessor(configuration: configuration)
        ocr = VisionTextRecognizer()
        audioArchive = try AudioArchiveWriter(
            directory: configuration.keyFrameDirectory.deletingLastPathComponent().appendingPathComponent("Audio", isDirectory: true)
        )
        transcriptionFinalizationGraceMs = configuration.transcriptionFinalizationGraceMs
    }

    public var meetingID: String? { meeting?.id }

    /// Starts evidence consumers before capture so no early sample is lost.
    public func start(meeting initialMeeting: Meeting, captureConfiguration: CaptureConfiguration) async throws {
        guard meeting == nil else { throw MeetingPipelineError.alreadyRunning }
        var value = initialMeeting
        value.status = .capturing
        try store.save(value)
        meeting = value

        do {
            if !liveTranscriptionEnabled {
            directAudio = await capture.setAudioSink { [audioArchive] audio in
                guard let buffer = audio.pcmBuffer else {
                    audioArchive.recordFailure("Audio PCM conversion failed"); return
                }
                do { try audioArchive.write(buffer, kind: audio.kind, timestampMs: audio.timestamp.milliseconds) }
                catch { audioArchive.recordFailure(error.localizedDescription) }
            }
            }
            if liveTranscriptionEnabled {
                if captureConfiguration.capturesSystemAudio {
                    do { try await systemTranscriber.start() } catch { audioArchive.recordFailure("Live STT: \(error.localizedDescription)") }
                }
                if captureConfiguration.capturesMicrophone {
                    do { try await microphoneTranscriber.start() } catch { audioArchive.recordFailure("Live STT: \(error.localizedDescription)") }
                }
            }
            startConsumers(meetingID: value.id)
            try await capture.start(configuration: captureConfiguration)
        } catch {
            _ = await capture.setAudioSink(nil)
            audioArchive.finish()
            await cleanupConsumers()
            await systemTranscriber.stop()
            await microphoneTranscriber.stop()
            meeting = nil
            var failed = value
            failed.status = .failed
            failed.endedAt = Date()
            try? store.save(failed)
            throw error
        }
    }

    /// Stops producers, drains final STT/OCR work, closes the last screen segment,
    /// then makes the meeting completed. This ordering prevents completed meetings
    /// from receiving late evidence writes.
    public func stop() async throws {
        guard var value = meeting else { throw MeetingPipelineError.notRunning }
        value.status = .finalizing
        try store.save(value)

        var stopError: Error?
        do { try await capture.stop() } catch { stopError = error }
        if capture.providesStopEvent { _ = await eventTask?.result }
        else { eventTask?.cancel(); _ = await eventTask?.result }
        eventTask = nil
        _ = await capture.setAudioSink(nil)
        videoContinuation?.finish()
        _ = await videoTask?.result
        videoTask = nil
        await systemTranscriber.stop()
        await microphoneTranscriber.stop()
        audioArchive.finish()
        await drainConsumers()
        _ = try store.finalizePartialTranscripts(meetingId: value.id)

        if var screen = activeScreen {
            screen.timeRange.endedAtMs = max(screen.timeRange.startedAtMs, elapsedMs(for: value))
            try store.save(screen)
            activeScreen = nil
        }
        await drainOCR()

        value.endedAt = Date()
        value.status = stopError == nil && captureFailure == nil && audioArchive.lastError == nil ? .completed : .partiallyCompleted
        try store.save(value)
        if try audioArchive.archivedFrames > 0 || store.transcripts(meetingId: value.id).isEmpty {
            _ = try store.enqueueIfNeeded(AnalysisJob(meetingId: value.id, kind: "transcribe", priority: 3))
        } else {
            _ = try store.enqueueIfNeeded(AnalysisJob(meetingId: value.id, kind: "summarize", priority: 2))
        }
        meeting = nil
        await frameProcessor.reset()
        systemAudioOriginMs = nil
        microphoneAudioOriginMs = nil
        if let stopError { throw stopError }
    }

    public var captureEndedUnexpectedly: Bool { captureFailure != nil }
    public var failure: String? { captureFailure ?? audioArchive.lastError }

    private func startConsumers(meetingID: String) {
        let frames = AsyncStream<VideoFrameEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        videoContinuation = frames.continuation
        videoTask = Task {
            for await frame in frames.stream { await self.consume(.video(frame), meetingID: meetingID) }
        }
        eventTask = Task { [capture] in
            for await event in capture.events {
                guard !Task.isCancelled else { break }
                switch event {
                case .stopped: return
                case .video(let frame): self.videoContinuation?.yield(frame)
                default: await self.consume(event, meetingID: meetingID)
                }
            }
        }
        transcriptTasks = [
            Task { [systemTranscriber] in
                for await event in systemTranscriber.events {
                    guard !Task.isCancelled else { break }
                    self.persist(event, meetingID: meetingID)
                }
            },
            Task { [microphoneTranscriber] in
                for await event in microphoneTranscriber.events {
                    guard !Task.isCancelled else { break }
                    self.persist(event, meetingID: meetingID)
                }
            }
        ]
    }

    private func consume(_ event: CaptureEvent, meetingID: String) async {
        switch event {
        case .stopped: break
        case .failure(let message): captureFailure = message; audioArchive.recordFailure(message)
        case .audio(let audio):
            guard let buffer = audio.pcmBuffer else { return }
            if !directAudio {
                do { try audioArchive.write(buffer, kind: audio.kind, timestampMs: audio.timestamp.milliseconds) }
                catch { audioArchive.recordFailure(error.localizedDescription) }
            }
            guard liveTranscriptionEnabled else { return }
            do {
                switch audio.kind {
                case .systemAudio:
                    if systemAudioOriginMs == nil { systemAudioOriginMs = audio.timestamp.milliseconds }
                    try await systemTranscriber.consume(buffer)
                case .microphone:
                    if microphoneAudioOriginMs == nil { microphoneAudioOriginMs = audio.timestamp.milliseconds }
                    try await microphoneTranscriber.consume(buffer)
                case .screen: break
                }
            } catch { audioArchive.recordFailure("Live STT: \(error.localizedDescription)") }
        case .video(let frame):
            do {
                guard let keyFrame = try await frameProcessor.consume(frame) else { return }
                if var previous = activeScreen {
                    previous.timeRange.endedAtMs = max(previous.timeRange.startedAtMs, keyFrame.timestampMs)
                    try store.save(previous)
                }
                let screen = ScreenEvent(
                    id: keyFrame.id,
                    meetingId: meetingID,
                    timeRange: TimeRange(startedAtMs: keyFrame.timestampMs),
                    imagePath: keyFrame.url.path,
                    analysisStatus: .pending
                )
                try store.save(screen)
                activeScreen = screen
                var processing = screen
                processing.analysisStatus = .processing
                try store.save(processing)
                let task = Task { [store, ocr] in
                    let result: Result<String, Error>
                    do {
                        result = .success(try await ocr.recognize(imageAt: keyFrame.url).text)
                    } catch {
                        result = .failure(error)
                    }
                    // Reload to preserve an endedAtMs written while OCR was running.
                    guard var analyzed = try? store.screens(meetingId: meetingID).first(where: { $0.id == screen.id }) else { return }
                    switch result {
                    case .success(let text):
                        analyzed.ocr = text
                        analyzed.analysisStatus = .completed
                    case .failure:
                        analyzed.analysisStatus = .failed
                    }
                    try? store.save(analyzed)
                }
                ocrTasks.append(task)
            } catch { /* A malformed frame must not stop audio or later frames. */ }
        }
    }

    private func persist(_ event: MeetingCapture.TranscriptEvent, meetingID: String) {
        let source: AudioSource = event.track == .localMicrophone ? .microphone : .system
        let speaker: Speaker = event.track == .localMicrophone ? .self : .remote
        let origin = event.track == .localMicrophone ? microphoneAudioOriginMs : systemAudioOriginMs
        let startedAt = max(0, (origin ?? 0) + event.startedAtMs)
        let endedAt = max(startedAt, (origin ?? 0) + event.endedAtMs)
        let evidence = MeetingCore.TranscriptEvent(
            id: event.utteranceID.uuidString,
            meetingId: meetingID,
            revision: event.revision,
            timeRange: TimeRange(startedAtMs: startedAt, endedAtMs: endedAt),
            speaker: speaker,
            text: event.text,
            source: source,
            isFinal: event.isFinal
        )
        do {
            try store.save(evidence)
            if event.isFinal { _ = try? store.associateVisibleScreens(transcriptId: evidence.id) }
        } catch { /* Stale asynchronous revisions are intentionally ignored. */ }
    }

    private func drainConsumers() async {
        eventTask?.cancel()
        _ = await eventTask?.result
        eventTask = nil
        // Speech emits its final result asynchronously after endAudio(). Keep
        // readers alive briefly; otherwise short captures commonly lose it.
        if liveTranscriptionEnabled && transcriptionFinalizationGraceMs > 0 {
            try? await Task.sleep(for: .milliseconds(transcriptionFinalizationGraceMs))
        } else { await Task.yield() }
        transcriptTasks.forEach { $0.cancel() }
        for task in transcriptTasks { _ = await task.result }
        transcriptTasks.removeAll()
    }

    private func cleanupConsumers() async {
        videoContinuation?.finish()
        videoTask?.cancel()
        videoTask = nil
        eventTask?.cancel()
        transcriptTasks.forEach { $0.cancel() }
        eventTask = nil
        transcriptTasks.removeAll()
    }

    private func drainOCR() async {
        for task in ocrTasks { _ = await task.result }
        ocrTasks.removeAll()
    }

    private func elapsedMs(for meeting: Meeting) -> Int64 {
        max(0, Int64(Date().timeIntervalSince(meeting.captureClockOrigin) * 1_000))
    }
}
