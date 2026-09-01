import Foundation

public enum AnalysisPriority: Int, Codable, Sendable, Comparable {
    case low = 0
    case normal = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AnalysisJob<Payload: Sendable>: Sendable {
    public let id: UUID
    public let priority: AnalysisPriority
    public let payload: Payload
    public let attempt: Int

    public init(id: UUID = UUID(), priority: AnalysisPriority, payload: Payload, attempt: Int = 0) {
        self.id = id
        self.priority = priority
        self.payload = payload
        self.attempt = attempt
    }
}

public enum EnqueueResult: Sendable, Equatable {
    case accepted
    case replacedLowPriority
    case rejected
}

public actor BoundedAnalysisQueue<Payload: Sendable> {
    private let capacity: Int
    private var jobs: [AnalysisJob<Payload>] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { jobs.count }

    @discardableResult
    public func enqueue(_ job: AnalysisJob<Payload>) -> EnqueueResult {
        if jobs.count < capacity {
            jobs.append(job)
            return .accepted
        }
        guard let lowestIndex = jobs.indices.min(by: { jobs[$0].priority < jobs[$1].priority }),
              jobs[lowestIndex].priority < job.priority else {
            return .rejected
        }
        jobs.remove(at: lowestIndex)
        jobs.append(job)
        return .replacedLowPriority
    }

    public func dequeue() -> AnalysisJob<Payload>? {
        guard let index = jobs.indices.max(by: {
            if jobs[$0].priority == jobs[$1].priority { return $0 > $1 }
            return jobs[$0].priority < jobs[$1].priority
        }) else { return nil }
        return jobs.remove(at: index)
    }
}

public struct RetryPolicy: Sendable {
    public let maximumAttempts: Int
    public let initialDelay: Duration
    public let multiplier: Double

    public init(maximumAttempts: Int = 3, initialDelay: Duration = .seconds(1), multiplier: Double = 2) {
        self.maximumAttempts = maximumAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
    }

    public func delay(afterAttempt attempt: Int) -> Duration {
        let seconds = pow(multiplier, Double(max(0, attempt - 1)))
        return initialDelay * seconds
    }
}
