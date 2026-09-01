import CoreVideo
import Foundation
import MeetingAnalysis
import MeetingCapture

public struct PersistedKeyFrame: Sendable, Equatable {
    public let id: String
    public let timestampMs: Int64
    public let url: URL
}

public actor KeyFrameProcessor {
    private let sampler = PixelBufferFrameSampler()
    private let detector = FrameChangeDetector()
    private let stableDetector: StableScreenDetector<PixelBufferBox>
    private let writer: KeyFrameWriter
    private let minimumFrameIntervalMs: Int64
    private let changedPixelRatioThreshold: Double
    private let meanDifferenceThreshold: Double
    private var lastSampledAtMs: Int64?
    private var baseline: GrayFrame?

    public init(configuration: MeetingPipelineConfiguration) throws {
        minimumFrameIntervalMs = configuration.minimumFrameIntervalMs
        changedPixelRatioThreshold = configuration.changedPixelRatioThreshold
        meanDifferenceThreshold = configuration.meanDifferenceThreshold
        stableDetector = StableScreenDetector(stabilityMs: configuration.stabilityMs)
        writer = try KeyFrameWriter(directory: configuration.keyFrameDirectory)
    }

    public func consume(_ frame: VideoFrameEvent) async throws -> PersistedKeyFrame? {
        let timestamp = frame.timestamp.milliseconds
        if let lastSampledAtMs, timestamp - lastSampledAtMs < minimumFrameIntervalMs { return nil }
        lastSampledAtMs = timestamp
        let sampled = try sampler.sample(frame.pixelBuffer)
        let changed: Bool
        if let baseline {
            let metrics = try detector.compare(baseline, sampled)
            changed = metrics.changedPixelRatio >= changedPixelRatioThreshold || metrics.meanAbsoluteDifference >= meanDifferenceThreshold
        } else {
            changed = true
        }
        guard changed else { return nil }

        let candidate = ScreenCandidate(
            observedAtMs: timestamp,
            fingerprint: detector.fingerprint(sampled),
            value: PixelBufferBox(frame.pixelBuffer)
        )
        guard let stable = await stableDetector.observe(candidate) else { return nil }
        baseline = sampled
        let id = UUID().uuidString
        let url = try await writer.write(stable.value.value, id: id)
        return PersistedKeyFrame(id: id, timestampMs: stable.observedAtMs, url: url)
    }

    public func reset() async {
        lastSampledAtMs = nil
        baseline = nil
        await stableDetector.reset()
    }
}

/// CoreVideo buffers are reference-counted and retained by this immutable box
/// until the stability window has elapsed.
private struct PixelBufferBox: @unchecked Sendable {
    let value: CVPixelBuffer
    init(_ value: CVPixelBuffer) { self.value = value }
}
