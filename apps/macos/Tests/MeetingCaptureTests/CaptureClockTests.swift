import CoreMedia
import XCTest
@testable import MeetingCapture

final class CaptureClockTests: XCTestCase {
    func testNormalizesDifferentSamplesAgainstFirstPresentationTime() {
        let clock = CaptureClock()
        XCTAssertEqual(clock.timestamp(for: CMTime(seconds: 120, preferredTimescale: 1_000)).nanoseconds, 0)
        XCTAssertEqual(clock.timestamp(for: CMTime(seconds: 120.5, preferredTimescale: 1_000)).milliseconds, 500)
    }
    func testTimestampNeverBecomesNegative() {
        let clock = CaptureClock(); _ = clock.timestamp(for: CMTime(seconds: 5, preferredTimescale: 1_000))
        XCTAssertEqual(clock.timestamp(for: CMTime(seconds: 4, preferredTimescale: 1_000)).nanoseconds, 0)
    }
    func testResetEstablishesNewOrigin() {
        let clock = CaptureClock(); _ = clock.timestamp(for: CMTime(seconds: 5, preferredTimescale: 1_000)); clock.reset()
        XCTAssertEqual(clock.timestamp(for: CMTime(seconds: 20, preferredTimescale: 1_000)).nanoseconds, 0)
    }
}
