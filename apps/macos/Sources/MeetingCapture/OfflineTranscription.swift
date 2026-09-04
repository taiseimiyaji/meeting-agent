@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

public struct OfflineTranscript: Sendable, Equatable {
    public let text: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64

    public init(text: String, startedAtMs: Int64, endedAtMs: Int64) {
        self.text = text; self.startedAtMs = startedAtMs; self.endedAtMs = endedAtMs
    }
}

public final class AppleSpeechFileTranscriber: @unchecked Sendable {
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
        var results: [OfflineTranscript] = []
        var offsetFrames: AVAudioFramePosition = 0
        while offsetFrames < audio.length {
            let count = AVAudioFrameCount(min(chunkFrames, audio.length - offsetFrames))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count) else {
                throw TranscriberError.recognizerUnavailable
            }
            try audio.read(into: buffer, frameCount: count)
            let chunkURL = temporary.appendingPathComponent("\(results.count).caf")
            let output = try AVAudioFile(forWriting: chunkURL, settings: audio.processingFormat.settings)
            try output.write(from: buffer)
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
        return try await withCheckedThrowingContinuation { continuation in
            let gate = RecognitionContinuationGate(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error { gate.fail(error); return }
                guard let result, result.isFinal else { return }
                let segments = result.bestTranscription.segments
                let start = Int64((segments.first?.timestamp ?? 0) * 1_000)
                let end = Int64(segments.last.map { ($0.timestamp + $0.duration) * 1_000 } ?? 0)
                gate.succeed(.init(text: result.bestTranscription.formattedString,
                                   startedAtMs: start, endedAtMs: max(start, end)))
            }
        }
    }
}

private final class RecognitionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OfflineTranscript, Error>?
    init(_ continuation: CheckedContinuation<OfflineTranscript, Error>) { self.continuation = continuation }
    func succeed(_ value: OfflineTranscript) { resume(.success(value)) }
    func fail(_ error: Error) { resume(.failure(error)) }
    private func resume(_ result: Result<OfflineTranscript, Error>) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(with: result)
    }
}
