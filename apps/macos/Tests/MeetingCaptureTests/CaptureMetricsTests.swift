import Foundation
import XCTest
@testable import MeetingCapture

final class CaptureMetricsTests: XCTestCase {
    func testTracksEachIndependentOutput() async {
        let metrics = CaptureMetrics(); await metrics.reset(startedAt: Date(timeIntervalSince1970: 1))
        await metrics.record(.screen, timestamp: .init(nanoseconds: 10_000_000))
        await metrics.record(.systemAudio, timestamp: .init(nanoseconds: 20_000_000), rmsDB: -12.5)
        await metrics.record(.microphone, timestamp: .init(nanoseconds: 30_000_000), rmsDB: -8.25)
        await metrics.recordDroppedScreenFrame(); await metrics.recordError()
        let value = await metrics.snapshot()
        XCTAssertEqual(value.screenFrames, 1); XCTAssertEqual(value.systemAudioBuffers, 1)
        XCTAssertEqual(value.microphoneBuffers, 1); XCTAssertEqual(value.droppedScreenFrames, 1)
        XCTAssertEqual(value.errors, 1); XCTAssertEqual(value.systemAudioRMSDB, -12.5)
        XCTAssertEqual(value.microphoneRMSDB, -8.25)
    }
}
