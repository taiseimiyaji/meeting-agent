import Testing
@testable import MeetingAnalysis

@Test func detectsChangedPixelsAndStableCandidate() async throws {
    let black = try GrayFrame(width: 8, height: 8, pixels: .init(repeating: 0, count: 64))
    let white = try GrayFrame(width: 8, height: 8, pixels: .init(repeating: 255, count: 64))
    let metrics = try FrameChangeDetector().compare(black, white)
    #expect(metrics.changedPixelRatio == 1)
    #expect(metrics.meanAbsoluteDifference == 1)

    let stable = StableScreenDetector<String>(stabilityMs: 500, duplicateHammingDistance: 0)
    let fingerprint = FrameFingerprint(bits: 42)
    #expect(await stable.observe(.init(observedAtMs: 100, fingerprint: fingerprint, value: "a")) == nil)
    #expect(await stable.observe(.init(observedAtMs: 700, fingerprint: fingerprint, value: "a"))?.value == "a")
}

@Test func boundedQueueProtectsHigherPriorityWork() async {
    let queue = BoundedAnalysisQueue<String>(capacity: 2)
    #expect(await queue.enqueue(.init(priority: .low, payload: "frame-1")) == .accepted)
    #expect(await queue.enqueue(.init(priority: .normal, payload: "ocr")) == .accepted)
    #expect(await queue.enqueue(.init(priority: .high, payload: "finalize")) == .replacedLowPriority)
    #expect(await queue.count == 2)
    #expect(await queue.dequeue()?.payload == "finalize")
}

@Test func ringBufferExpiresAndClearsEvidence() async {
    let buffer = EphemeralRingBuffer<String>(retentionMs: 100)
    await buffer.append("old", at: 0)
    await buffer.append("recent", at: 101)
    #expect(await buffer.snapshot().map(\.value) == ["recent"])
    await buffer.clear()
    #expect(await buffer.snapshot().isEmpty)
}
