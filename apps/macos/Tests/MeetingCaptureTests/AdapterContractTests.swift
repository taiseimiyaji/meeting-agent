import XCTest
@testable import MeetingCapture

final class AdapterContractTests: XCTestCase {
    func testMockAdapterHonorsStartStopContract() async throws {
        let adapter = MockCaptureAdapter(); try await adapter.start(configuration: .init(targetWindowID: 42))
        let started = await adapter.currentState(); XCTAssertEqual(started, .capturing)
        do { try await adapter.start(configuration: .init()); XCTFail("Expected alreadyRunning") }
        catch { XCTAssertEqual(error as? CaptureError, .alreadyRunning) }
        try await adapter.stop(); let stopped = await adapter.currentState(); XCTAssertEqual(stopped, .idle)
    }
}

private actor MockCaptureAdapter: MeetingCaptureAdapter {
    nonisolated let events: AsyncStream<CaptureEvent> = AsyncStream { _ in }
    private var state: CaptureState = .idle
    func availableTargets() async throws -> [CaptureTarget] { [.init(id: 42, applicationName: "Google Chrome", windowTitle: "Meet")] }
    func start(configuration: CaptureConfiguration) async throws { guard state == .idle else { throw CaptureError.alreadyRunning }; state = .capturing }
    func stop() async throws { guard state == .capturing else { throw CaptureError.notRunning }; state = .idle }
    func metricsSnapshot() async -> CaptureMetricsSnapshot { .init() }
    func currentState() -> CaptureState { state }
}
