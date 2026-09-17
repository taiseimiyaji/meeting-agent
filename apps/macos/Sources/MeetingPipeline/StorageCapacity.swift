import Foundation

public struct StorageCapacityError: LocalizedError, Sendable {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum StorageCapacity {
    public static let reserveBytes: Int64 = 512 * 1024 * 1024
    public static func available(at directory: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let size = attributes[.systemFreeSize] as? NSNumber else {
            throw StorageCapacityError("ディスクの空き容量を確認できません。保存先を確認してください。")
        }
        return size.int64Value
    }
    public static func require(at directory: URL, extraBytes: Int64 = 0) throws {
        guard extraBytes >= 0, extraBytes <= Int64.max - reserveBytes,
              try available(at: directory) >= reserveBytes + extraBytes else {
            throw StorageCapacityError("ディスクの空き容量が不足しています。保存済みの音声を保護するため録音・変換を停止しました。空き容量を確保してください。")
        }
    }
}
