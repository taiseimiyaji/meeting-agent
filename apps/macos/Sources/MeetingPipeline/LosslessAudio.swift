import Foundation
import Compression
import CryptoKit

/// Byte-exact CAF packing, including headers and floating point samples.
/// A raw CAF always wins during an interrupted two-phase replacement.
public enum LosslessAudio {
    private struct Receipt: Codable { let bytes: Int64; let sha256: String }
    public struct Readable {
        public let url: URL
        private let temporary: Bool
        init(url: URL, temporary: Bool) { self.url = url; self.temporary = temporary }
        public func cleanup() { if temporary { try? FileManager.default.removeItem(at: url) } }
    }
    public static func storedSize(_ url: URL) -> Int64 {
        let file = FileManager.default.fileExists(atPath: url.path) ? url : url.appendingPathExtension("lzfse")
        return Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    private static func digest(_ url: URL) throws -> Receipt {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(), count: Int64 = 0
        while let data = try file.read(upToCount: 65536), !data.isEmpty { hash.update(data: data); count += Int64(data.count) }
        return Receipt(bytes: count, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func transform(_ input: URL, to output: URL, operation: FilterOperation, maximumBytes: Int64 = .max) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let source = try FileHandle(forReadingFrom: input), destination = try FileHandle(forWritingTo: output)
        defer { try? source.close(); try? destination.close() }
        var count: Int64 = 0
        let filter = try OutputFilter(operation, using: .lzfse) { data in
            guard let data else { return }
            count += Int64(data.count)
            guard count <= maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
            try destination.write(contentsOf: data)
        }
        while let data = try source.read(upToCount: 65536), !data.isEmpty { try Task.checkCancellation(); try filter.write(data) }
        try filter.finalize()
        try destination.synchronize()
    }
    @discardableResult public static func compact(_ url: URL) throws -> Bool {
        guard url.pathExtension == "caf", FileManager.default.fileExists(atPath: url.path) else { return false }
        let receipt = try digest(url)
        guard receipt.bytes <= Int64.max / 2 else { throw CocoaError(.fileReadTooLarge) }
        try StorageCapacity.require(at: url.deletingLastPathComponent(), extraBytes: receipt.bytes * 2)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".packing-\(UUID().uuidString)")
        let check = staged.appendingPathExtension("check")
        defer { try? FileManager.default.removeItem(at: staged); try? FileManager.default.removeItem(at: check) }
        try transform(url, to: staged, operation: .compress)
        guard storedSize(staged) + 256 < receipt.bytes else { return false }
        try transform(staged, to: check, operation: .decompress, maximumBytes: receipt.bytes)
        let restored = try digest(check)
        guard restored.bytes == receipt.bytes, restored.sha256 == receipt.sha256 else { throw CocoaError(.fileReadCorruptFile) }
        let packed = url.appendingPathExtension("lzfse")
        // Derived leftovers can be replaced while the verified original remains.
        if FileManager.default.fileExists(atPath: packed.path) { try FileManager.default.removeItem(at: packed) }
        try FileManager.default.moveItem(at: staged, to: packed)
        try JSONEncoder().encode(receipt).write(to: packed.appendingPathExtension("receipt"), options: .atomic)
        try FileManager.default.removeItem(at: url)
        return true
    }
    public static func materialize(_ url: URL) throws -> Readable {
        if FileManager.default.fileExists(atPath: url.path) { return Readable(url: url, temporary: false) }
        let packed = url.appendingPathExtension("lzfse")
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: packed.appendingPathExtension("receipt")))
        guard receipt.bytes >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        try StorageCapacity.require(at: url.deletingLastPathComponent(), extraBytes: receipt.bytes)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".inflate-\(UUID().uuidString).caf")
        do {
            try transform(packed, to: temp, operation: .decompress, maximumBytes: receipt.bytes)
            let restored = try digest(temp)
            guard restored.bytes == receipt.bytes, restored.sha256 == receipt.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            return Readable(url: temp, temporary: true)
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }
}
