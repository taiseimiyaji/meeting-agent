import Foundation

public enum FileTranscriptionError: LocalizedError {
    case timedOut, modelNotInstalled, unsupportedProvider(String)
    public var errorDescription: String? {
        switch self {
        case .timedOut: "文字起こしが制限時間を超えました。保存音声から再試行できます。"
        case .modelNotInstalled: "日本語の音声認識モデルが未インストールです。設定から準備してください。"
        case .unsupportedProvider(let name): "利用できない文字起こしProvider: \(name)"
        }
    }
}

public protocol FileTranscriber: Sendable {
    var provider: String { get }
    func transcribe(file: URL) async throws -> OfflineTranscript
}

/// Unlike a throwing task group, a stalled provider cannot hold the caller past
/// the deadline. Provider cancellation handlers release their native resources.
public func withTranscriptionDeadline<T: Sendable>(seconds: Double = 60,
    operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = DeadlineGate<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            let work = Task { do { gate.resolve(.success(try await operation())) } catch { gate.resolve(.failure(error)) } }
            let timer = Task {
                do { try await Task.sleep(for: .seconds(seconds)); gate.resolve(.failure(FileTranscriptionError.timedOut)) }
                catch { }
            }
            gate.retain([work, timer])
        }
    } onCancel: { gate.resolve(.failure(CancellationError())) }
}

private final class DeadlineGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ value: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func retain(_ values: [Task<Void, Never>]) {
        lock.lock()
        if result != nil { lock.unlock(); values.forEach { $0.cancel() } }
        else { tasks = values; lock.unlock() }
    }
    func resolve(_ value: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let current = continuation; continuation = nil
        let running = tasks; tasks = []
        lock.unlock()
        running.forEach { $0.cancel() }
        current?.resume(with: value)
    }
}
