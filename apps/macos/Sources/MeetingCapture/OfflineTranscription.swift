@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import MeetingCore

public struct OfflineTranscript: Sendable, Equatable {
    public let text: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64

    public init(text: String, startedAtMs: Int64, endedAtMs: Int64) {
        self.text = text; self.startedAtMs = startedAtMs; self.endedAtMs = endedAtMs
    }
}

public final class AppleSpeechFileTranscriber: FileTranscriber, @unchecked Sendable {
    public let provider = "apple_speech"
    private let locale: Locale
    private let requiresOnDeviceRecognition: Bool

    public init(locale: Locale = Locale(identifier: "ja-JP"), requiresOnDeviceRecognition: Bool = true) {
        self.locale = locale; self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
    }

    public func transcribe(file: URL) async throws -> OfflineTranscript {
        let audio = try AVAudioFile(forReading: file)
        let chunkFrames = AVAudioFramePosition(audio.processingFormat.sampleRate * 50)
        guard audio.length > chunkFrames else { return try await transcribeSingle(file: file) }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-agent-stt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try TemporaryWorkspace.mark(temporary)
        var results: [OfflineTranscript] = []
        var offsetFrames: AVAudioFramePosition = 0
        while offsetFrames < audio.length {
            let count = AVAudioFrameCount(min(chunkFrames, audio.length - offsetFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count) else {
                throw TranscriberError.recognizerUnavailable
            }
            try audio.read(into: buffer, frameCount: count)
            let chunkURL = temporary.appendingPathComponent("\(results.count).caf")
            do {
                let output = try AVAudioFile(forWriting: chunkURL, settings: audio.processingFormat.settings)
                try output.write(from: buffer)
            }
            try Task.checkCancellation()
            let result = try await transcribeSingle(file: chunkURL)
            let offsetMs = Int64(Double(offsetFrames) / audio.processingFormat.sampleRate * 1_000)
            results.append(.init(text: result.text, startedAtMs: offsetMs + result.startedAtMs,
                                 endedAtMs: offsetMs + result.endedAtMs))
            offsetFrames += AVAudioFramePosition(count)
        }
        return .init(text: results.map(\.text).joined(separator: "\n"),
                     startedAtMs: results.first?.startedAtMs ?? 0,
                     endedAtMs: results.last?.endedAtMs ?? 0)
    }

    private func transcribeSingle(file: URL) async throws -> OfflineTranscript {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriberError.speechRecognitionPermissionDenied
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        if requiresOnDeviceRecognition && !recognizer.supportsOnDeviceRecognition {
            throw TranscriberError.recognizerUnavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        return try await withTranscriptionDeadline {
            let gate = RecognitionContinuationGate()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    let task = recognizer.recognitionTask(with: request) { result, error in
                        if let result, result.isFinal {
                            let segments = result.bestTranscription.segments
                            let start = Int64((segments.first?.timestamp ?? 0) * 1000)
                            let end = Int64(segments.last.map { ($0.timestamp + $0.duration) * 1000 } ?? 0)
                            gate.succeed(.init(text: result.bestTranscription.formattedString,
                                              startedAtMs: start, endedAtMs: max(start, end)))
                        } else if let error { gate.fail(error) }
                    }
                    gate.retain(task, recognizer: recognizer)
                }
            } onCancel: { gate.fail(CancellationError()) }
        }
    }
}

private final class RecognitionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OfflineTranscript, Error>?
    private var result: Result<OfflineTranscript, Error>?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    func install(_ value: CheckedContinuation<OfflineTranscript, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func retain(_ value: SFSpeechRecognitionTask, recognizer: SFSpeechRecognizer) {
        lock.lock()
        if result != nil { lock.unlock(); value.cancel() }
        else { task = value; self.recognizer = recognizer; lock.unlock() }
    }
    func succeed(_ value: OfflineTranscript) { resume(.success(value)) }
    func fail(_ error: Error) { resume(.failure(error)) }
    private func resume(_ value: Result<OfflineTranscript, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let current = continuation; continuation = nil
        let running = task; task = nil; recognizer = nil
        lock.unlock()
        running?.cancel()
        current?.resume(with: value)
    }
}
