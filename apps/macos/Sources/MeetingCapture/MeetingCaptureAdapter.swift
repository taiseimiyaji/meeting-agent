import Foundation

public protocol MeetingCaptureAdapter: Sendable {
    var events: AsyncStream<CaptureEvent> { get }
    func availableTargets() async throws -> [CaptureTarget]
    func start(configuration: CaptureConfiguration) async throws
    func stop() async throws
    func metricsSnapshot() async -> CaptureMetricsSnapshot
}
