import Foundation
import MeetingCore

public typealias PersistentAnalysisHandler = @Sendable (MeetingCore.AnalysisJob) async throws -> Void

public enum PersistentAnalysisWorkerError: Error, Equatable {
    case noHandler(String)
}

/// Executes durable jobs claimed from MeetingStore. Capture producers only write
/// a small WAL transaction; expensive provider work always runs asynchronously.
public actor PersistentAnalysisWorker {
    private let store: MeetingStore
    private let retryPolicy: RetryPolicy
    private let pollInterval: Duration
    private var handlers: [String: PersistentAnalysisHandler] = [:]
    private var loop: Task<Void, Never>?

    public init(store: MeetingStore, retryPolicy: RetryPolicy = .init(), pollInterval: Duration = .milliseconds(250)) {
        self.store = store; self.retryPolicy = retryPolicy; self.pollInterval = pollInterval
    }

    public func register(kind: String, handler: @escaping PersistentAnalysisHandler) {
        handlers[kind] = handler
    }

    /// Returns a Task immediately so capture code never waits for provider work.
    nonisolated public func enqueueInBackground(_ job: MeetingCore.AnalysisJob) -> Task<Void, Error> {
        let store = self.store
        return Task.detached(priority: .utility) { try store.enqueue(job) }
    }

    /// Processes at most one job and is deterministic enough for lifecycle hooks
    /// and tests. Returns false when no ready work exists.
    @discardableResult public func runOnce(now: Date = Date()) async throws -> Bool {
        guard let job = try store.claimNextAnalysisJob(now: now) else { return false }
        do {
            guard let handler = handlers[job.kind] else { throw PersistentAnalysisWorkerError.noHandler(job.kind) }
            try await handler(job)
            try store.completeAnalysisJob(id: job.id, now: now)
        } catch {
            let nextAttempt = job.retryCount + 1
            if nextAttempt >= retryPolicy.maximumAttempts || error is PersistentAnalysisWorkerError {
                try store.failAnalysisJob(id: job.id, error: String(describing: error), now: now)
            } else {
                let delay = retryPolicy.delay(afterAttempt: nextAttempt)
                try store.retryAnalysisJob(id: job.id, error: String(describing: error), availableAt: now.addingTimeInterval(delay.timeInterval), now: now)
            }
        }
        return true
    }

    /// Resets jobs left processing by a prior process, then starts polling.
    public func start() throws {
        guard loop == nil else { return }
        _ = try store.recoverInterruptedWork()
        let interval = pollInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let worked = try await self?.runOnce() ?? false
                    if !worked { try await Task.sleep(for: interval) }
                } catch {
                    // A transient database failure must not terminate the worker.
                    try? await Task.sleep(for: interval)
                }
            }
        }
    }

    public func stop() async {
        let task = loop; loop = nil
        task?.cancel()
        await task?.value
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
