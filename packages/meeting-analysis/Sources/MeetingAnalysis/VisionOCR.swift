#if canImport(Vision) && canImport(ImageIO)
import Foundation
import ImageIO
import Vision

public enum OCRError: Error, Equatable {
    case unreadableImage
    case noCGImage
}

public struct OCRResult: Sendable, Equatable {
    public let text: String
    public let recognizedLines: [String]
    public let duration: Duration
}

public actor VisionTextRecognizer {
    private let languages: [String]

    public init(languages: [String] = ["ja-JP", "en-US"]) {
        self.languages = languages
    }

    public func recognize(imageAt url: URL) async throws -> OCRResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw OCRError.unreadableImage }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw OCRError.noCGImage }
        let clock = ContinuousClock()
        let start = clock.now
        let lines: [String] = try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation])?.compactMap {
                    $0.topCandidates(1).first?.string
                } ?? []
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
        return OCRResult(text: lines.joined(separator: "\n"), recognizedLines: lines, duration: start.duration(to: clock.now))
    }
}
#endif
