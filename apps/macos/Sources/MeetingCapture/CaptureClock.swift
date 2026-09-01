import CoreMedia
import Foundation

/// Normalizes timestamps from independent capture producers to one monotonic timeline.
public final class CaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: CMTime?

    public init() {}

    public func reset() {
        lock.withLock { origin = nil }
    }

    public func timestamp(for presentationTime: CMTime) -> CaptureTimestamp {
        lock.withLock {
            guard presentationTime.isValid, presentationTime.isNumeric else {
                return CaptureTimestamp(nanoseconds: 0)
            }
            if origin == nil { origin = presentationTime }
            let delta = CMTimeSubtract(presentationTime, origin!)
            let seconds = max(0, CMTimeGetSeconds(delta))
            return CaptureTimestamp(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
