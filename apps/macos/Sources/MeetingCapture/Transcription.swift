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

    public init(
        authorization: PermissionState,
        localeSupported: Bool,
        recognizerAvailable: Bool,
        onDeviceRecognitionSupported: Bool
    ) {
        self.authorization = authorization
        self.localeSupported = localeSupported
        self.recognizerAvailable = recognizerAvailable
        self.onDeviceRecognitionSupported = onDeviceRecognitionSupported
    }

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
    private var running = false
    private var audioSeconds: Double = 0
    private var originMs: Int64 = 0
    private var retryAt = Date.distantPast
    private var failures = 0

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
            guard !running else { throw TranscriberError.alreadyRunning }
            running = true; audioSeconds = 0; failures = 0; retryAt = .distantPast
            try beginRequest()

        }
    }

    public func consume(_ buffer: AVAudioPCMBuffer) async throws {
        try lock.withLock {
            guard running else { throw TranscriberError.notRunning }
            defer { audioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate }
            if request == nil {
                guard failures < 3, Date() >= retryAt else { throw TranscriberError.recognizerUnavailable }
                try beginRequest()
            }
            request?.append(buffer)
        }
    }

    public func stop() async {
        let current: (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) = lock.withLock {
            running = false
            let current = (request, task)
            request = nil
            task = nil
            recognizer = nil
            return current
        }
        current.0?.endAudio()
        current.1?.finish()
    }

    private func beginRequest() throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        utteranceID = UUID(); revision = 0; originMs = Int64(audioSeconds * 1000)
        let id = utteranceID
        self.recognizer = recognizer; self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.receive(result: result, error: error, id: id)
        }
    }

    private func receive(result: SFSpeechRecognitionResult?, error: Error?, id: UUID) {
        let event: TranscriptEvent? = lock.withLock {
            guard id == utteranceID else { return nil }
            if error != nil || result?.isFinal == true {
                request = nil; task = nil; recognizer = nil
                if error != nil { failures += 1; retryAt = Date().addingTimeInterval(Double(failures)) }
                else { failures = 0; retryAt = .distantPast }
            }
            guard let result else { return nil }
            let transcription = result.bestTranscription
            let segments = transcription.segments
            revision += 1
            return .init(utteranceID: id, revision: revision, track: track,
                         text: transcription.formattedString,
                         startedAtMs: originMs + Int64((segments.first?.timestamp ?? 0) * 1000),
                         endedAtMs: originMs + Int64((segments.last.map { $0.timestamp + $0.duration } ?? 0) * 1000),
                         isFinal: result.isFinal)
        }
        if let event { continuation.yield(event) }
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
