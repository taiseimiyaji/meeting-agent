import Foundation

public protocol MeetingCaptureAdapter: Sendable {
    var providesStopEvent: Bool { get }
    func setAudioSink(_ sink: (@Sendable (AudioEvent) -> Void)?) async -> Bool
    var events: AsyncStream<CaptureEvent> { get }
    func availableTargets() async throws -> [CaptureTarget]
    func start(configuration: CaptureConfiguration) async throws
    func stop() async throws
    func metricsSnapshot() async -> CaptureMetricsSnapshot
}

public extension MeetingCaptureAdapter {
    var providesStopEvent: Bool { false }
    func setAudioSink(_ sink: (@Sendable (AudioEvent) -> Void)?) async -> Bool { false }
}
