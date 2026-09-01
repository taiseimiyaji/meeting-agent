import Foundation

public struct GrayFrame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0, pixels.count == width * height else {
            throw FrameAnalysisError.invalidDimensions
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum FrameAnalysisError: Error, Equatable {
    case invalidDimensions
    case incompatibleFrames
}

public struct FrameFingerprint: Sendable, Equatable, Hashable {
    public let bits: UInt64
}

public struct FrameChangeMetrics: Sendable, Equatable {
    public let meanAbsoluteDifference: Double
    public let changedPixelRatio: Double
    public let hammingDistance: Int
}

public struct FrameChangeDetector: Sendable {
    public let pixelThreshold: UInt8

    public init(pixelThreshold: UInt8 = 20) {
        self.pixelThreshold = pixelThreshold
    }

    public func fingerprint(_ frame: GrayFrame) -> FrameFingerprint {
        let sampleWidth = 8
        let sampleHeight = 8
        var values = [UInt8]()
        values.reserveCapacity(64)
        for y in 0..<sampleHeight {
            for x in 0..<sampleWidth {
                let sourceX = min(frame.width - 1, x * frame.width / sampleWidth)
                let sourceY = min(frame.height - 1, y * frame.height / sampleHeight)
                values.append(frame.pixels[sourceY * frame.width + sourceX])
            }
        }
        let average = values.reduce(0) { $0 + Int($1) } / values.count
        let bits = values.enumerated().reduce(UInt64(0)) { result, item in
            item.element >= average ? result | (UInt64(1) << UInt64(item.offset)) : result
        }
        return FrameFingerprint(bits: bits)
    }

    public func compare(_ lhs: GrayFrame, _ rhs: GrayFrame) throws -> FrameChangeMetrics {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            throw FrameAnalysisError.incompatibleFrames
        }
        var differenceTotal = 0
        var changed = 0
        for (a, b) in zip(lhs.pixels, rhs.pixels) {
            let difference = abs(Int(a) - Int(b))
            differenceTotal += difference
            if difference >= Int(pixelThreshold) { changed += 1 }
        }
        let count = max(1, lhs.pixels.count)
        let leftHash = fingerprint(lhs).bits
        let rightHash = fingerprint(rhs).bits
        return FrameChangeMetrics(
            meanAbsoluteDifference: Double(differenceTotal) / Double(count) / 255.0,
            changedPixelRatio: Double(changed) / Double(count),
            hammingDistance: (leftHash ^ rightHash).nonzeroBitCount
        )
    }
}

public struct ScreenCandidate<Value: Sendable>: Sendable {
    public let observedAtMs: Int64
    public let fingerprint: FrameFingerprint
    public let value: Value

    public init(observedAtMs: Int64, fingerprint: FrameFingerprint, value: Value) {
        self.observedAtMs = observedAtMs
        self.fingerprint = fingerprint
        self.value = value
    }
}

public actor StableScreenDetector<Value: Sendable> {
    private let stabilityMs: Int64
    private let duplicateHammingDistance: Int
    private var pending: ScreenCandidate<Value>?
    private var currentFingerprint: FrameFingerprint?

    public init(stabilityMs: Int64 = 500, duplicateHammingDistance: Int = 3) {
        self.stabilityMs = stabilityMs
        self.duplicateHammingDistance = duplicateHammingDistance
    }

    public func observe(_ candidate: ScreenCandidate<Value>) -> ScreenCandidate<Value>? {
        if let currentFingerprint,
           (currentFingerprint.bits ^ candidate.fingerprint.bits).nonzeroBitCount <= duplicateHammingDistance {
            pending = nil
            return nil
        }
        guard let existing = pending else {
            pending = candidate
            return nil
        }
        let sameCandidate = (existing.fingerprint.bits ^ candidate.fingerprint.bits).nonzeroBitCount <= duplicateHammingDistance
        guard sameCandidate else {
            pending = candidate
            return nil
        }
        guard candidate.observedAtMs - existing.observedAtMs >= stabilityMs else { return nil }
        pending = nil
        currentFingerprint = candidate.fingerprint
        return candidate
    }

    public func reset() {
        pending = nil
        currentFingerprint = nil
    }
}
