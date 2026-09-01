#if canImport(CoreVideo) && canImport(CoreImage)
import CoreImage
import CoreVideo
import Foundation

public enum PixelBufferFrameError: Error {
    case unsupportedPixelFormat(OSType)
    case missingBaseAddress
    case imageWriteFailed
}

public struct PixelBufferFrameSampler: Sendable {
    public let outputWidth: Int
    public let outputHeight: Int

    public init(outputWidth: Int = 64, outputHeight: Int = 64) {
        precondition(outputWidth > 0 && outputHeight > 0)
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    public func sample(_ pixelBuffer: CVPixelBuffer) throws -> GrayFrame {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_32BGRA else { throw PixelBufferFrameError.unsupportedPixelFormat(format) }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw PixelBufferFrameError.missingBaseAddress }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var output = [UInt8]()
        output.reserveCapacity(outputWidth * outputHeight)
        for y in 0..<outputHeight {
            let sourceY = min(height - 1, y * height / outputHeight)
            for x in 0..<outputWidth {
                let sourceX = min(width - 1, x * width / outputWidth)
                let offset = sourceY * bytesPerRow + sourceX * 4
                let blue = Int(bytes[offset])
                let green = Int(bytes[offset + 1])
                let red = Int(bytes[offset + 2])
                output.append(UInt8(clamping: (red * 77 + green * 150 + blue * 29) >> 8))
            }
        }
        return try GrayFrame(width: outputWidth, height: outputHeight, pixels: output)
    }
}

public actor KeyFrameWriter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func write(_ pixelBuffer: CVPixelBuffer, id: String) throws -> URL {
        let safeID = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safeID.isEmpty else { throw PixelBufferFrameError.imageWriteFailed }
        let url = directory.appendingPathComponent(safeID).appendingPathExtension("jpg")
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: colorSpace, options: [quality: 0.82])
        return url
    }
}
#endif
