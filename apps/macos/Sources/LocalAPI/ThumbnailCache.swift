import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Preview-only cache. OCR, Codex and enlarged views still use the source image.
final class ThumbnailCache: @unchecked Sendable {
    private let cache = NSCache<NSString, NSData>()
    private let lock = NSLock()
    init() { cache.totalCostLimit = 8 * 1024 * 1024; cache.countLimit = 128 }
    func cached(key: String) -> APIImage? {
        cache.object(forKey: key as NSString).map { .init(data: $0 as Data, contentType: "image/png") }
    }
    func preview(_ original: APIImage, key: String) throws -> APIImage {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache.object(forKey: key as NSString) { return .init(data: hit as Data, contentType: "image/png") }
        guard let source = CGImageSourceCreateWithData(original.data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        cache.setObject(data, forKey: key as NSString, cost: data.length)
        return .init(data: data as Data, contentType: "image/png")
    }
}
