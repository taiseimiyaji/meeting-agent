@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

public enum SpeakerTrack: String, Sendable, Equatable {
    case localMicrophone
    case remoteSystemAudio
}

public struct TranscriptEvent: Sendable, Equatable {
    public let utteranceID: UUID
    public let revision: Int
    public let track: SpeakerTrack
    public let text: String
    public let startedAtMs: Int64
    public let endedAtMs: Int64
    public let isFinal: Bool

    public init(
        utteranceID: UUID,
        revision: Int,
        track: SpeakerTrack,
        text: String,
        startedAtMs: Int64,
        endedAtMs: Int64,
        isFinal: Bool
    ) {
        self.utteranceID = utteranceID
        self.revision = revision
        self.track = track
        self.text = text
        self.startedAtMs = startedAtMs
        self.endedAtMs = endedAtMs
        self.isFinal = isFinal
    }
}

public struct TranscriberAvailability: Sendable, Equatable {
    public let authorization: PermissionState
    public let localeSupported: Bool
    public let recognizerAvailable: Bool
    public let onDeviceRecognitionSupported: Bool

    public var canTranscribe: Bool {
        authorization == .granted && localeSupported && recognizerAvailable
    }
}

public protocol Transcriber: Sendable {
    var events: AsyncStream<TranscriptEvent> { get }
    func availability() async -> TranscriberAvailability
    func start() async throws
    func consume(_ buffer: AVAudioPCMBuffer) async throws
    func stop() async
}

public enum TranscriberError: LocalizedError {
    case speechRecognitionPermissionDenied
    case localeUnavailable(String)
    case recognizerUnavailable
    case alreadyRunning
    case notRunning

    public var errorDescription: String? {
        switch self {
        case .speechRecognitionPermissionDenied: "Speech Recognition permission is required."
        case .localeUnavailable(let locale): "Speech recognition is unavailable for \(locale)."
        case .recognizerUnavailable: "The speech recognizer is currently unavailable."
        case .alreadyRunning: "The transcriber is already running."
        case .notRunning: "The transcriber is not running."
        }
    }
}

/// Streaming Apple Speech provider. Create one instance per independent audio track.
public final class AppleSpeechTranscriber: Transcriber, @unchecked Sendable {
    public let events: AsyncStream<TranscriptEvent>

    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let track: SpeakerTrack
    private let locale: Locale
    private let requiresOnDeviceRecognition: Bool
    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var utteranceID = UUID()
    private var revision = 0

    public init(
        track: SpeakerTrack,
        locale: Locale = Locale(identifier: "ja-JP"),
        requiresOnDeviceRecognition: Bool = true
    ) {
        self.track = track
        self.locale = locale
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        let pair = AsyncStream<TranscriptEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = pair.stream
        continuation = pair.continuation
    }

    deinit { continuation.finish() }

    public static func requestAuthorization() async -> PermissionState {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: Self.mapAuthorization(status))
            }
        }
    }

    public func availability() async -> TranscriberAvailability {
        let recognizer = SFSpeechRecognizer(locale: locale)
        return .init(
            authorization: Self.mapAuthorization(SFSpeechRecognizer.authorizationStatus()),
            localeSupported: SFSpeechRecognizer.supportedLocales().contains(where: { $0.identifier == locale.identifier }),
            recognizerAvailable: recognizer?.isAvailable == true,
            onDeviceRecognitionSupported: recognizer?.supportsOnDeviceRecognition == true
        )
    }

    public func start() async throws {
        let status = await availability()
        guard status.authorization == .granted else { throw TranscriberError.speechRecognitionPermissionDenied }
        guard status.localeSupported else { throw TranscriberError.localeUnavailable(locale.identifier) }
        guard status.recognizerAvailable else { throw TranscriberError.recognizerUnavailable }
        if requiresOnDeviceRecognition, !status.onDeviceRecognitionSupported { throw TranscriberError.recognizerUnavailable }

        try lock.withLock {
            guard task == nil else { throw TranscriberError.alreadyRunning }
            guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriberError.recognizerUnavailable }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
            utteranceID = UUID()
            revision = 0
            self.recognizer = recognizer
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                self?.receive(result: result, error: error)
            }
        }
    }

    public func consume(_ buffer: AVAudioPCMBuffer) async throws {
        try lock.withLock {
            guard let request else { throw TranscriberError.notRunning }
            request.append(buffer)
        }
    }

    public func stop() async {
        let current: (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) = lock.withLock {
            let current = (request, task)
            request = nil
            task = nil
            recognizer = nil
            return current
        }
        current.0?.endAudio()
        current.1?.finish()
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?) {
        guard error == nil, let result else { return }
        let transcription = result.bestTranscription
        let segments = transcription.segments
        let (start, end): (Int64, Int64) = if let first = segments.first, let last = segments.last {
            (Int64(first.timestamp * 1_000), Int64((last.timestamp + last.duration) * 1_000))
        } else { (0, 0) }

        let event: TranscriptEvent = lock.withLock {
            revision += 1
            return .init(
                utteranceID: utteranceID,
                revision: revision,
                track: track,
                text: transcription.formattedString,
                startedAtMs: start,
                endedAtMs: end,
                isFinal: result.isFinal
            )
        }
        continuation.yield(event)
    }

    private static func mapAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
