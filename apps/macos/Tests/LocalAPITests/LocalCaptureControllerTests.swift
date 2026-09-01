import Foundation
import MeetingCapture
import MeetingCore
import XCTest
@testable import LocalAPI

final class LocalCaptureControllerTests: XCTestCase {
    func testStartAndStopUsePipelineAndExposeConsistentSnapshot() async throws {
        let fixture = try ControllerFixture()
        try await fixture.controller.start(targetID: "42")

        let capturing = await fixture.controller.snapshot()
        XCTAssertEqual(capturing.status, .capturing)
        let meetingID = try XCTUnwrap(capturing.meetingId)
        XCTAssertEqual(fixture.pipeline.startCount, 1)
        XCTAssertEqual(fixture.pipeline.targetWindowID, 42)
        XCTAssertEqual(
            fixture.builtDirectory?.standardizedFileURL,
            fixture.evidenceRoot.appendingPathComponent(meetingID).appendingPathComponent("KeyFrames").standardizedFileURL
        )
        let adapterStarts = await fixture.adapter.startCount
        XCTAssertEqual(adapterStarts, 0, "controller must not start the adapter outside the pipeline")

        try await fixture.controller.stop()
        let stopped = await fixture.controller.snapshot()
        XCTAssertEqual(stopped.status, .idle)
        XCTAssertNil(stopped.meetingId)
        XCTAssertEqual(fixture.pipeline.stopCount, 1)
        let adapterStops = await fixture.adapter.stopCount
        XCTAssertEqual(adapterStops, 0, "controller must not stop the adapter outside the pipeline")
    }

    func testPipelineStartFailureIsReflectedInAPIAndMeetingStore() async throws {
        let fixture = try ControllerFixture(failure: .start)

        do {
            try await fixture.controller.start(targetID: nil)
            XCTFail("start should fail")
        } catch {}

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertNil(snapshot.meetingId)
        XCTAssertNotNil(snapshot.error)
        let meetings = try fixture.store.meetings()
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.status, .failed)
    }

    func testPipelineStopFailureKeepsMeetingIdentityAndFailureState() async throws {
        let fixture = try ControllerFixture(failure: .stop)
        try await fixture.controller.start(targetID: nil)
        let capturing = await fixture.controller.snapshot()
        let meetingID = capturing.meetingId

        do {
            try await fixture.controller.stop()
            XCTFail("stop should fail")
        } catch {}

        let snapshot = await fixture.controller.snapshot()
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.meetingId, meetingID)
        XCTAssertNotNil(snapshot.error)
    }
}

private final class ControllerFixture: @unchecked Sendable {
    let root: URL
    let evidenceRoot: URL
    let store: MeetingStore
    let adapter = ControllerFakeAdapter()
    let pipeline: ControllerFakePipeline
    let controller: LocalCaptureController
    private let recorder = DirectoryRecorder()
    var builtDirectory: URL? { recorder.value }

    init(failure: ControllerFakePipeline.Failure? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        evidenceRoot = root.appendingPathComponent("Meetings")
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        store = try MeetingStore(path: root.appendingPathComponent("db.sqlite").path)
        pipeline = ControllerFakePipeline(failure: failure)
        let pipeline = pipeline
        let recorder = recorder
        controller = LocalCaptureController(adapter: adapter, store: store, evidenceRoot: evidenceRoot) { directory in
            recorder.value = directory
            return pipeline
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

private final class DirectoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var value: URL? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ControllerFakePipeline: MeetingPipelineControlling, @unchecked Sendable {
    enum Failure { case start, stop }
    private let lock = NSLock()
    private let failure: Failure?
    private var _startCount = 0
    private var _stopCount = 0
    private var _targetWindowID: UInt32?
    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var targetWindowID: UInt32? { lock.withLock { _targetWindowID } }
    init(failure: Failure?) { self.failure = failure }
    func start(meeting: Meeting, captureConfiguration: CaptureConfiguration) async throws {
        lock.withLock { _startCount += 1; _targetWindowID = captureConfiguration.targetWindowID }
        if failure == .start { throw ControllerTestError.expected }
    }
    func stop() async throws {
        lock.withLock { _stopCount += 1 }
        if failure == .stop { throw ControllerTestError.expected }
    }
}

private actor ControllerFakeAdapter: MeetingCaptureAdapter {
    nonisolated let events = AsyncStream<CaptureEvent> { _ in }
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func availableTargets() async throws -> [CaptureTarget] { [] }
    func start(configuration: CaptureConfiguration) async throws { startCount += 1 }
    func stop() async throws { stopCount += 1 }
    func metricsSnapshot() async -> CaptureMetricsSnapshot { .init(screenFrames: 7) }
}

private enum ControllerTestError: Error { case expected }

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
